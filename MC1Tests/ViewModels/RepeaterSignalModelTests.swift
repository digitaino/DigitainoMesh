import Foundation
@testable import MC1
@testable import MC1Services
@testable import MeshCore
import Testing

/// The narrow slice of a radio the signal-bars engine talks to, stubbed so the façade can be
/// driven by a real engine without a device. Viewer mode is used throughout: it lets a test
/// hand the engine a device table verbatim instead of simulating RF.
private actor StubSignalBarsSession: SignalBarsSessionOps, SessionEventStreaming {
  var blob = Data()

  func setBlob(_ blob: Data) {
    self.blob = blob
  }

  func getSync(_: SyncID) async throws -> Data {
    blob
  }

  func setSync(_: SyncID, payload _: Data) async throws {}

  func sendTrace(tag _: UInt32?, authCode _: UInt32?, flags _: UInt8, path _: Data?) async throws -> MessageSentInfo {
    MessageSentInfo(route: 0, expectedAck: Data(), suggestedTimeoutMs: 5000)
  }

  func sendNodeDiscoverRequest(filter _: UInt8, prefixOnly _: Bool, tag: UInt32?, since _: Date?) async throws -> UInt32 {
    tag ?? 1
  }

  nonisolated var connectionState: AsyncStream<ConnectionState> {
    AsyncStream { $0.finish() }
  }

  func events() async -> AsyncStream<MeshEvent> {
    AsyncStream { $0.finish() }
  }

  func events(filter _: EventFilter) async -> AsyncStream<MeshEvent> {
    AsyncStream { $0.finish() }
  }

  func waitForEvent(filter _: EventFilter, timeout _: TimeInterval?) async -> MeshEvent? {
    nil
  }
}

@Suite("RepeaterSignalModel")
@MainActor
struct RepeaterSignalModelTests {
  // MARK: - Fixtures

  private static func blob(_ entries: [SignalBarsBlob.Entry]) -> Data {
    SignalBarsBlob(version: 2, entries: entries).encode()
  }

  private static func entry(
    hash: [UInt8],
    rxSnrX4: Int8 = 24,
    isBest: Bool = false,
    ageSeconds: UInt16 = 0
  ) -> SignalBarsBlob.Entry {
    SignalBarsBlob.Entry(
      id: hash[0],
      idHash: hash,
      rxSnrX4: rxSnrX4,
      txSnrX4: 0,
      hasRx: true,
      hasTx: false,
      txFailed: false,
      isBest: isBest,
      ageSeconds: ageSeconds,
      rttMs: 0
    )
  }

  /// An engine in viewer mode holding the given device table, with its own loops never
  /// started — the tests step it by hand so nothing races.
  private func makeEngine(
    table: [SignalBarsBlob.Entry] = []
  ) async -> (SignalBarsEngine, StubSignalBarsSession) {
    let session = StubSignalBarsSession()
    await session.setBlob(Self.blob(table))
    let engine = SignalBarsEngine(
      session: session,
      configuration: .init(mode: .viewer),
      sleep: { _ in }
    )
    await engine.pollDeviceTable()
    return (engine, session)
  }

  private func id(_ hex: String) throws -> NodeHexID {
    try #require(NodeHexID(hex))
  }

  // MARK: - Binding

  @Test
  func `an unattached model holds the empty table`() {
    let model = RepeaterSignalModel()
    #expect(model.isAttached == false)
    #expect(model.displayRepeaters.isEmpty)
    #expect(model.best == nil)
  }

  @Test
  func `attaching seeds the engine's current state`() async throws {
    let (engine, _) = await makeEngine(table: [Self.entry(hash: [0x0C], isBest: true)])
    let model = RepeaterSignalModel()

    await model.attach(to: engine)

    #expect(model.isAttached)
    #expect(model.mode == .viewer)
    #expect(model.displayRepeaters.count == 1)
    #expect(try model.best?.id == id("0C"))
  }

  @Test
  func `a snapshot published after attaching reaches the model`() async throws {
    let (engine, session) = await makeEngine(table: [Self.entry(hash: [0x0C])])
    let model = RepeaterSignalModel()
    await model.attach(to: engine)

    await session.setBlob(Self.blob([Self.entry(hash: [0x0C]), Self.entry(hash: [0x7F])]))
    await engine.pollDeviceTable()

    try await waitUntilModel("the second repeater should arrive") {
      model.displayRepeaters.count == 2
    }
  }

  @Test
  func `detaching resets to the empty table and stops updates`() async throws {
    let (engine, session) = await makeEngine(table: [Self.entry(hash: [0x0C])])
    let model = RepeaterSignalModel()
    await model.attach(to: engine)
    #expect(model.displayRepeaters.count == 1)

    model.detach()
    #expect(model.isAttached == false)
    #expect(model.displayRepeaters.isEmpty)

    await session.setBlob(Self.blob([Self.entry(hash: [0x0C]), Self.entry(hash: [0x7F])]))
    await engine.pollDeviceTable()
    try await Task.sleep(for: .milliseconds(20))

    #expect(model.displayRepeaters.isEmpty)
  }

  @Test
  func `re-attaching does not leave a second subscription behind`() async {
    let (engine, _) = await makeEngine(table: [Self.entry(hash: [0x0C])])
    let model = RepeaterSignalModel()

    await model.attach(to: engine)
    await model.attach(to: engine)

    #expect(model.displayRepeaters.count == 1)
  }

  // MARK: - Intent forwarding

  @Test
  func `watching a repeater forwards to the engine`() async throws {
    let (engine, _) = await makeEngine(table: [Self.entry(hash: [0x0C])])
    let model = RepeaterSignalModel()
    await model.attach(to: engine)

    try await model.watchRepeater(id("0C"))

    try await waitUntilModel("the watch should be reflected") {
      model.watched?.id == (try? self.id("0C"))
    }
    #expect(try await engine.currentSnapshot().watched?.id == id("0C"))
  }

  @Test
  func `clearing the watch forwards to the engine`() async throws {
    let (engine, _) = await makeEngine(table: [Self.entry(hash: [0x0C])])
    let model = RepeaterSignalModel()
    await model.attach(to: engine)
    try await model.watchRepeater(id("0C"))

    await model.watchRepeater(nil)

    try await waitUntilModel("the watch should be cleared") { model.watched == nil }
  }

  @Test
  func `dismissing a repeater removes it from the rendered rows`() async throws {
    let (engine, _) = await makeEngine(table: [
      Self.entry(hash: [0x0C]),
      Self.entry(hash: [0x7F])
    ])
    let model = RepeaterSignalModel()
    await model.attach(to: engine)

    try await model.dismissRepeater(id("0C"))

    try await waitUntilModel("the dismissed row should be hidden") {
      model.displayRepeaters.count == 1
    }
    #expect(try model.displayRepeaters.first?.id == id("7F"))
  }

  @Test
  func `clearing stale rows hides everything past the window`() async throws {
    let (engine, _) = await makeEngine(table: [
      Self.entry(hash: [0x0C], ageSeconds: 0),
      Self.entry(hash: [0x7F], ageSeconds: 1200)
    ])
    let model = RepeaterSignalModel()
    await model.attach(to: engine)
    #expect(model.hasStaleRepeaters)

    await model.clearStaleRepeaters()

    try await waitUntilModel("the stale row should be cleared") {
      model.hasStaleRepeaters == false
    }
  }

  // MARK: - Watch matching

  @Test
  func `a watched row is matched across hash widths`() async throws {
    let (engine, _) = await makeEngine(table: [Self.entry(hash: [0x0C, 0x13])])
    let model = RepeaterSignalModel()
    await model.attach(to: engine)
    try await model.watchRepeater(id("0C"))

    try await waitUntilModel("the watch should be reflected") { model.watched != nil }
    let row = try #require(model.displayRepeaters.first)
    #expect(model.isWatched(row))
  }

  @Test
  func `an unrelated row is not reported as watched`() async throws {
    let (engine, _) = await makeEngine(table: [Self.entry(hash: [0x7F])])
    let model = RepeaterSignalModel()
    await model.attach(to: engine)
    try await model.watchRepeater(id("0C"))

    try await waitUntilModel("the watch should be reflected") { model.watched != nil }
    let row = try #require(model.displayRepeaters.first)
    #expect(model.isWatched(row) == false)
  }

  // MARK: - Helpers

  /// Snapshots reach the model through an `AsyncStream`, so assertions on a forwarded intent
  /// have to give the delivery task a turn.
  private func waitUntilModel(
    _ message: String,
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(condition(), "\(message)")
  }
}
