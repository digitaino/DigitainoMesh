import Foundation
import MapperRawLog
@testable import MC1
@testable import MC1Services
import Testing

/// Our own transmissions, and how the packet's mesh-wide identity reaches them
/// (docs/SIGNAL_MAPPER_V3.md §2, "Our own packets").
///
/// Driven through the real `MessageEventStream` and a real in-memory `PersistenceStore`,
/// because the two things worth testing here are both about the seams: which events count
/// as a transmission, and whether the hash the RX correlation stamps on a message actually
/// finds its way onto the row. A fake store would let both pass while proving neither.
@Suite("MapperSentPacketLogger")
@MainActor
struct MapperSentPacketLoggerTests {
  private let at = Date(timeIntervalSince1970: 1_753_000_000)
  private let radioID = UUID()

  // MARK: - Fixtures

  private func makeMessages() throws -> PersistenceStore {
    let container = try PersistenceStore.createContainer(inMemory: true)
    return PersistenceStore(modelContainer: container)
  }

  private func outgoingMessage(
    id: UUID,
    channelIndex: UInt8?,
    packetContentHash: String? = nil
  ) -> MessageDTO {
    MessageDTO(
      id: id,
      radioID: radioID,
      contactID: channelIndex == nil ? UUID() : nil,
      channelIndex: channelIndex,
      text: "hello",
      timestamp: 0,
      createdAt: at,
      direction: .outgoing,
      status: .sent,
      textType: .plain,
      ackCode: nil,
      pathLength: 0,
      snr: nil,
      senderKeyPrefix: nil,
      senderNodeName: nil,
      isRead: true,
      replyToID: nil,
      roundTripTime: nil,
      heardRepeats: 0,
      retryAttempt: 0,
      maxRetryAttempts: 0,
      packetContentHash: packetContentHash
    )
  }

  private func makeLogger(
    store: MapperRawLogStore,
    messages: PersistenceStore,
    fixes: any MapperFixProviding = NoMapperFixProvider()
  ) async -> (MapperSentPacketLogger, MapperRawSampleRecorder) {
    let recorder = MapperRawSampleRecorder(store: store, runID: nil)
    let logger = MapperSentPacketLogger(
      recorder: recorder,
      store: store,
      fixProvider: fixes,
      messages: messages,
      now: { [at] in at }
    )
    return (logger, recorder)
  }

  private func sentRows(_ store: MapperRawLogStore) async throws -> [MapperRawSampleDTO] {
    try await store.fetchSentSamples(
      since: at.addingTimeInterval(-60),
      until: at.addingTimeInterval(60),
      cellRaw: nil
    )
  }

  // MARK: - Sent rows

  @Test
  func `A resolved send writes one row, and the delivery that follows does not write a second`() async throws {
    let store = try MapperRawLogStore.inMemory()
    let messages = try makeMessages()
    let messageID = UUID()
    try await messages.saveMessage(outgoingMessage(id: messageID, channelIndex: nil))

    let (logger, recorder) = await makeLogger(store: store, messages: messages)
    await logger.handle(.messageStatusResolved(messageID: messageID, status: .sent))
    await logger.handle(.messageStatusResolved(messageID: messageID, status: .delivered, roundTripTime: 800))
    await recorder.flushNow()

    let rows = try await sentRows(store)
    #expect(rows.count == 1, "one transmission, two status resolutions")
    let row = try #require(rows.first)
    #expect(row.kind == .sent)
    #expect(row.messageID == messageID)
    #expect(row.payloadTypeRaw == Int(PayloadType.textMessage.rawValue))
    #expect(row.runID == nil, "a send outside a ride is still a send")
  }

  @Test
  func `A channel broadcast is recorded as a group-text transmission`() async throws {
    let store = try MapperRawLogStore.inMemory()
    let messages = try makeMessages()
    let messageID = UUID()
    try await messages.saveMessage(outgoingMessage(id: messageID, channelIndex: 0))

    let (logger, recorder) = await makeLogger(store: store, messages: messages)
    await logger.handle(.messageStatusResolved(messageID: messageID, status: .sent))
    await recorder.flushNow()

    let row = try #require(try await sentRows(store).first)
    #expect(row.payloadTypeRaw == Int(PayloadType.groupText.rawValue))
  }

  @Test
  func `A resend is a second transmission and gets its own row`() async throws {
    let store = try MapperRawLogStore.inMemory()
    let messages = try makeMessages()
    let messageID = UUID()
    try await messages.saveMessage(outgoingMessage(id: messageID, channelIndex: 0))

    let (logger, recorder) = await makeLogger(store: store, messages: messages)
    await logger.handle(.messageStatusResolved(messageID: messageID, status: .sent))
    await logger.handle(.messageResent(messageID: messageID))
    await recorder.flushNow()

    // Two packets really did go on the air, and a reach lookup for the second must not be
    // answered with the first one's time.
    #expect(try await sentRows(store).count == 2)
  }

  @Test
  func `Statuses that are not a transmission write nothing`() async throws {
    let store = try MapperRawLogStore.inMemory()
    let messages = try makeMessages()
    let messageID = UUID()
    try await messages.saveMessage(outgoingMessage(id: messageID, channelIndex: nil))

    let (logger, recorder) = await makeLogger(store: store, messages: messages)
    await logger.handle(.messageStatusResolved(messageID: messageID, status: .pending))
    await logger.handle(.messageStatusResolved(messageID: messageID, status: .sending))
    await logger.handle(.messageFailed(messageID: messageID))
    await logger.handle(.messageRetrying(messageID: messageID, attempt: 1, maxAttempts: 3))
    await recorder.flushNow()

    #expect(try await sentRows(store).isEmpty)
  }

  @Test
  func `With no fix the row is still written and says the fix was missing`() async throws {
    let store = try MapperRawLogStore.inMemory()
    let messages = try makeMessages()
    let messageID = UUID()
    try await messages.saveMessage(outgoingMessage(id: messageID, channelIndex: nil))

    let (logger, recorder) = await makeLogger(store: store, messages: messages)
    await logger.handle(.messageStatusResolved(messageID: messageID, status: .sent))
    await recorder.flushNow()

    let row = try #require(try await sentRows(store).first)
    #expect(row.cellRaw == nil)
    #expect(row.gateOutcome == .noFix)
    #expect(row.latitude == nil)
  }

  @Test
  func `With a fix the row lands in the hexagon the phone was standing in`() async throws {
    let store = try MapperRawLogStore.inMemory()
    let messages = try makeMessages()
    let messageID = UUID()
    try await messages.saveMessage(outgoingMessage(id: messageID, channelIndex: nil))

    let fix = MapperFix(
      latitude: 37.7749,
      longitude: -122.4194,
      horizontalAccuracyMeters: 8,
      timestamp: at
    )
    let (logger, recorder) = await makeLogger(
      store: store, messages: messages, fixes: StaticFixProvider(fix)
    )
    await logger.handle(.messageStatusResolved(messageID: messageID, status: .sent))
    await recorder.flushNow()

    let row = try #require(try await sentRows(store).first)
    #expect(row.cellRaw != nil)
    #expect(row.gateOutcome == .accepted)
    #expect(row.latitude == 37.7749)
  }

  // MARK: - The hash back-fill

  @Test
  func `An echo back-fills the content hash onto the transmission it echoed`() async throws {
    let store = try MapperRawLogStore.inMemory()
    let messages = try makeMessages()
    let messageID = UUID()
    let otherID = UUID()
    // Both messages already carry the hash the RX correlation stamped on them; only one
    // of them is echoed, and only that one's row may gain it.
    try await messages.saveMessage(
      outgoingMessage(id: messageID, channelIndex: 0, packetContentHash: "a1b2c3d4e5f60718")
    )
    try await messages.saveMessage(
      outgoingMessage(id: otherID, channelIndex: 0, packetContentHash: "ffffffffffffffff")
    )

    let (logger, recorder) = await makeLogger(store: store, messages: messages)
    await logger.handle(.messageStatusResolved(messageID: messageID, status: .sent))
    await logger.handle(.messageStatusResolved(messageID: otherID, status: .sent))
    await recorder.flushNow()

    // The send itself never writes a hash, even when the message row happens to have one:
    // the row records what the radio did, and the hash arrives through the echo.
    #expect(try await sentRows(store).allSatisfy { $0.contentHash == nil })

    await logger.handle(.heardRepeatRecorded(messageID: messageID, count: 1))

    let rows = try await sentRows(store)
    let hashed = try #require(rows.first { $0.messageID == messageID })
    #expect(hashed.contentHash == "a1b2c3d4e5f60718")
    let untouched = try #require(rows.first { $0.messageID == otherID })
    #expect(untouched.contentHash == nil, "the back-fill is keyed by message, not by time")
  }

  @Test
  func `An echo for a message with no hash yet leaves the row alone`() async throws {
    let store = try MapperRawLogStore.inMemory()
    let messages = try makeMessages()
    let messageID = UUID()
    try await messages.saveMessage(outgoingMessage(id: messageID, channelIndex: 0))

    let (logger, recorder) = await makeLogger(store: store, messages: messages)
    await logger.handle(.messageStatusResolved(messageID: messageID, status: .sent))
    await recorder.flushNow()
    // No `packetContentHash` on the message: the RX entry that would have supplied it was
    // pruned, or predates the column. A hash-less row is not a gap — reach matches our own
    // transmissions by key and time.
    await logger.handle(.heardRepeatRecorded(messageID: messageID, count: 1))

    #expect(try await sentRows(store).first?.contentHash == nil)
  }

  // MARK: - Adverts

  @Test
  func `An advert is one of our transmissions and gets a row of its own`() async throws {
    let store = try MapperRawLogStore.inMemory()
    let messages = try makeMessages()

    let (logger, recorder) = await makeLogger(store: store, messages: messages)
    await logger.recordAdvertSend()
    await recorder.flushNow()

    let row = try #require(try await sentRows(store).first)
    #expect(row.payloadTypeRaw == Int(PayloadType.advert.rawValue))
    #expect(row.messageID == nil, "an advert is not a message")
  }

  // MARK: - Helpers

  private struct StaticFixProvider: MapperFixProviding {
    let fix: MapperFix?

    init(_ fix: MapperFix?) {
      self.fix = fix
    }

    func latestFix() async -> MapperFix? {
      fix
    }
  }
}
