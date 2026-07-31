import Foundation
@testable import MC1Services
import MeshCore
import Testing

/// Spec source: legacy `SignalBarsService` — `start(deviceID:pathHashMode:mode:)`,
/// `pollSignalBars`/`applyBlob`, `startProbe`, `requestRefresh(targetHexID:)`,
/// `refreshAll`, `pingRepeater`, `handleTraceResponse`, the watched-repeater callback,
/// and the dismiss/clear-stale display filters.
@Suite("SignalBarsEngine")
struct SignalBarsEngineTests {
  // MARK: - Harness

  private func makeEngine(
    session: MockSignalBarsSession,
    clock: TestClock,
    mode: SignalBarsMode = .engine,
    pathHashMode: UInt8 = 0,
    directory: (any SignalBarsNodeDirectory)? = nil,
    movement: MovementHint = .stationary
  ) -> SignalBarsEngine {
    SignalBarsEngine(
      session: session,
      directory: directory,
      movementHints: FixedMovementHintProvider(movement),
      configuration: SignalBarsEngine.Configuration(mode: mode, pathHashMode: pathHashMode),
      now: clock.provider,
      sleep: { _ in }
    )
  }

  private func hexID(_ hex: String) throws -> NodeHexID {
    try #require(NodeHexID(hex))
  }

  // MARK: - Viewer mode: blob ingest

  @Test
  func `Viewer mode reads the device's table on the initial fetch`() async {
    let session = MockSignalBarsSession()
    let clock = TestClock()
    await session.setSignalBarsBlobs([SignalBarsFixtures.blob([
      SignalBarsFixtures.entry(hash: [0x0C, 0x13], rxSnrX4: 24, txSnrX4: 12, hasTx: true, isBest: true),
      SignalBarsFixtures.entry(hash: [0xAA], rxSnrX4: 4)
    ])])
    let engine = makeEngine(session: session, clock: clock, mode: .viewer)

    await engine.pollDeviceTable()

    let snapshot = await engine.currentSnapshot()
    #expect(snapshot.mode == .viewer)
    #expect(snapshot.repeaters.map(\.hexID) == ["0C13", "AA"])
    #expect(snapshot.best?.txSnr == 3)
    #expect(snapshot.best?.isDeviceBest == true)
    #expect(await session.syncReads == [.signalBars])
  }

  @Test
  func `Viewer mode applies pushed sync values without asking`() async {
    let session = MockSignalBarsSession()
    let engine = makeEngine(session: session, clock: TestClock(), mode: .viewer)

    await engine.ingest(.syncValue(.signalBars, SignalBarsFixtures.blob([
      SignalBarsFixtures.entry(hash: [0x0C])
    ])))

    #expect(await engine.currentSnapshot().repeaters.map(\.hexID) == ["0C"])
    #expect(await session.syncReads.isEmpty, "a push needs no fetch")
  }

  @Test
  func `An unchanged device table publishes nothing, so polling does not make the UI flash`() async {
    let session = MockSignalBarsSession()
    let engine = makeEngine(session: session, clock: TestClock(), mode: .viewer)
    let blob = SignalBarsFixtures.blob([SignalBarsFixtures.entry(hash: [0x0C])])

    await engine.ingest(.syncValue(.signalBars, blob))
    let first = await engine.currentSnapshot()
    await engine.ingest(.syncValue(.signalBars, blob))
    let second = await engine.currentSnapshot()

    #expect(first.rxFlashTick == 1)
    #expect(second.rxFlashTick == 1, "an identical table is not a new sighting")
    #expect(second.repeaters.count == 1)
  }

  @Test
  func `A table the radio heard again is a fresh sighting`() async {
    let session = MockSignalBarsSession()
    let clock = TestClock()
    let engine = makeEngine(session: session, clock: clock, mode: .viewer)

    await engine.ingest(.syncValue(.signalBars, SignalBarsFixtures.blob([
      SignalBarsFixtures.entry(hash: [0x0C], rxSnrX4: 8)
    ])))
    // Still age 0 five seconds later: the device is reporting a repeater it keeps hearing.
    clock.advance(5)
    await engine.ingest(.syncValue(.signalBars, SignalBarsFixtures.blob([
      SignalBarsFixtures.entry(hash: [0x0C], rxSnrX4: 24)
    ])))

    let snapshot = await engine.currentSnapshot()
    #expect(snapshot.rxFlashTick == 2)
    #expect(snapshot.repeaters.first?.rxSnr == 6)
  }

  @Test
  func `A silent repeater aging between polls is not a fresh sighting`() async throws {
    let session = MockSignalBarsSession()
    let clock = TestClock()
    let engine = makeEngine(session: session, clock: clock, mode: .viewer)
    try await engine.watchRepeater(hexID("0C"))
    await engine.ingest(.syncValue(.signalBars, SignalBarsFixtures.blob([
      SignalBarsFixtures.entry(hash: [0x0C], ageSeconds: 100)
    ])))
    let first = await engine.currentSnapshot()

    clock.advance(5)
    await engine.ingest(.syncValue(.signalBars, SignalBarsFixtures.blob([
      SignalBarsFixtures.entry(hash: [0x0C], ageSeconds: 105)
    ])))

    let second = await engine.currentSnapshot()
    #expect(second.rxFlashTick == first.rxFlashTick, "only the age advanced")
    #expect(
      second.watched?.heardCount == first.watched?.heardCount,
      "a watch tone every five seconds on a repeater nobody heard is the bug this guards"
    )
    #expect(second.watched?.lastHeardAt == clock.now.addingTimeInterval(-105))
  }

  @Test
  func `A repeater whose age dropped since the last poll was heard again`() async throws {
    let session = MockSignalBarsSession()
    let clock = TestClock()
    let engine = makeEngine(session: session, clock: clock, mode: .viewer)
    try await engine.watchRepeater(hexID("0C"))
    await engine.ingest(.syncValue(.signalBars, SignalBarsFixtures.blob([
      SignalBarsFixtures.entry(hash: [0x0C], ageSeconds: 100)
    ])))

    clock.advance(5)
    await engine.ingest(.syncValue(.signalBars, SignalBarsFixtures.blob([
      SignalBarsFixtures.entry(hash: [0x0C], ageSeconds: 2)
    ])))

    let snapshot = await engine.currentSnapshot()
    #expect(snapshot.rxFlashTick == 2)
    #expect(snapshot.watched?.heardCount == 2)
    #expect(snapshot.watched?.lastHeardAt == clock.now.addingTimeInterval(-2))
  }

  @Test
  func `A watched leg the device has no measurement for keeps the last reading`() async throws {
    let session = MockSignalBarsSession()
    let clock = TestClock()
    let engine = makeEngine(session: session, clock: clock, mode: .viewer)
    try await engine.watchRepeater(hexID("0C"))
    await engine.ingest(.syncValue(.signalBars, SignalBarsFixtures.blob([
      SignalBarsFixtures.entry(hash: [0x0C], rxSnrX4: 20, txSnrX4: 8, hasTx: true)
    ])))
    #expect(await engine.currentSnapshot().watched?.rxSnr == 5)

    clock.advance(5)
    await engine.ingest(.syncValue(.signalBars, SignalBarsFixtures.blob([
      SignalBarsFixtures.entry(hash: [0x0C], hasRx: false)
    ])))

    let watched = try #require(await engine.currentSnapshot().watched)
    #expect(watched.heardCount == 2)
    #expect(watched.rxSnr == 5, "an unmeasured RX leg preserves the last reading, as TX does")
    #expect(watched.txSnr == 2)
  }

  @Test
  func `A watched repeater with no measurement at all reads as no data, not zero`() async throws {
    let session = MockSignalBarsSession()
    let engine = makeEngine(session: session, clock: TestClock(), mode: .viewer)
    try await engine.watchRepeater(hexID("0C"))

    await engine.ingest(.syncValue(.signalBars, SignalBarsFixtures.blob([
      SignalBarsFixtures.entry(hash: [0x0C], hasRx: false)
    ])))

    let watched = try #require(await engine.currentSnapshot().watched)
    #expect(watched.heardCount == 1)
    #expect(watched.rxSnr == nil, "0.0 dB would render as a real, fair-looking reading")
    #expect(watched.rxQuality == .unknown)
  }

  @Test
  func `An undecodable blob is ignored rather than clearing the table`() async {
    let session = MockSignalBarsSession()
    let engine = makeEngine(session: session, clock: TestClock(), mode: .viewer)
    await engine.ingest(.syncValue(.signalBars, SignalBarsFixtures.blob([
      SignalBarsFixtures.entry(hash: [0x0C])
    ])))

    await engine.ingest(.syncValue(.signalBars, Data([0x02])))

    #expect(await engine.currentSnapshot().repeaters.count == 1)
  }

  @Test
  func `Viewer mode mirrors the device and ignores sightings it could derive itself`() async {
    let session = MockSignalBarsSession()
    let engine = makeEngine(session: session, clock: TestClock(), mode: .viewer)

    await engine.ingest(.discoverResponse(SignalBarsFixtures.discoverResponse(
      publicKey: SignalBarsFixtures.publicKey([0x0C])
    )))
    await engine.ingest(.rxLogData(SignalBarsFixtures.relayedPacket(path: [0xAA])))

    #expect(
      await engine.currentSnapshot().repeaters.isEmpty,
      "the device owns the table; a second source would make the app and the OLED disagree"
    )
  }

  // MARK: - Viewer mode: triggers

  @Test
  func `Refreshing one repeater writes the ping trigger and re-reads the table`() async throws {
    let session = MockSignalBarsSession()
    await session.setSignalBarsBlobs([SignalBarsFixtures.blob([
      SignalBarsFixtures.entry(hash: [0x0C, 0x13])
    ])])
    let engine = makeEngine(session: session, clock: TestClock(), mode: .viewer)

    try await engine.requestRefresh(target: hexID("0C13"))

    let writes = await session.syncWrites
    #expect(writes.count == 1)
    #expect(writes[0].id == .signalBars)
    #expect(writes[0].payload == Data([0x01, 0x0C]))
    #expect(await session.syncReads == [.signalBars], "the device's fresh measurement is read back")
  }

  @Test
  func `Refreshing everything writes the refresh-all trigger`() async {
    let session = MockSignalBarsSession()
    let engine = makeEngine(session: session, clock: TestClock(), mode: .viewer)

    await engine.refreshAll()

    #expect(await session.syncWrites.map(\.payload) == [Data([0x00, 0x00])])
    #expect(await session.traces.isEmpty, "viewer mode never transmits on its own")
  }

  @Test
  func `A viewer-mode probe asks the device to run its discovery scan`() async {
    let session = MockSignalBarsSession()
    let engine = makeEngine(session: session, clock: TestClock(), mode: .viewer)

    await engine.startProbe()

    #expect(await session.syncWrites.map(\.payload) == [Data([0x02, 0x00])])
    #expect(await session.discoverRequests.isEmpty)
    let snapshot = await engine.currentSnapshot()
    #expect(!snapshot.isRefreshing, "the refresh flag is cleared once the scan has settled")
    #expect(snapshot.txFlashTick == 1)
  }

  // MARK: - Engine mode: sightings

  @Test
  func `A discover response adds a probeable repeater with both legs measured`() async throws {
    let session = MockSignalBarsSession()
    let engine = makeEngine(session: session, clock: TestClock(), pathHashMode: 1)
    let key = SignalBarsFixtures.publicKey([0x0C, 0x13, 0xAB])

    await engine.ingest(.discoverResponse(SignalBarsFixtures.discoverResponse(
      publicKey: key,
      snr: 8,
      snrIn: 2
    )))

    let entry = try #require(await engine.currentSnapshot().repeaters.first)
    #expect(entry.hexID == "0C13", "the ID is re-derived at the device's path hash mode")
    #expect(entry.rxSnr == 8)
    #expect(entry.txSnr == 2)
    #expect(entry.txState == .measured(.good))
    #expect(entry.publicKey == key)
  }

  @Test
  func `A relayed packet refreshes the RX leg only`() async throws {
    let session = MockSignalBarsSession()
    let engine = makeEngine(session: session, clock: TestClock())

    await engine.ingest(.rxLogData(SignalBarsFixtures.relayedPacket(path: [0xAA, 0x0C], snr: 3)))

    let entry = try #require(await engine.currentSnapshot().repeaters.first)
    #expect(entry.hexID == "0C")
    #expect(entry.rxSnr == 3)
    #expect(entry.txState == .unknown)
    #expect(entry.publicKey == nil, "a passive sighting cannot make a repeater probeable")
  }

  @Test
  func `The path hash mode can change at runtime`() async {
    let session = MockSignalBarsSession()
    let engine = makeEngine(session: session, clock: TestClock(), pathHashMode: 0)
    await engine.setPathHashMode(2)

    await engine.ingest(.discoverResponse(SignalBarsFixtures.discoverResponse(
      publicKey: SignalBarsFixtures.publicKey([0x0C, 0x13, 0xAB])
    )))

    #expect(await engine.currentSnapshot().repeaters.first?.hexID == "0C13AB")
  }

  // MARK: - Engine mode: probe lifecycle

  @Test
  func `A probe cycle discovers, transmits a trace at the configured hash width, and marks TX measuring`() async {
    let session = MockSignalBarsSession()
    let clock = TestClock()
    let engine = makeEngine(session: session, clock: clock, pathHashMode: 1)
    await engine.ingest(.discoverResponse(SignalBarsFixtures.discoverResponse(
      publicKey: SignalBarsFixtures.publicKey([0x0C, 0x13, 0xAB])
    )))

    await engine.runCycle()

    #expect(await session.discoverRequests.map(\.filter) == [0x04])
    let traces = await session.traces
    #expect(traces.count == 1)
    #expect(traces[0].flags == 1, "the trace carries the device's path hash mode")
    #expect(traces[0].path == Data([0x0C, 0x13]))
    #expect(await engine.currentSnapshot().repeaters.first?.txState == .measuring)
  }

  @Test
  func `A trace reply is correlated by tag and records TX SNR and round-trip time`() async throws {
    let session = MockSignalBarsSession()
    let clock = TestClock()
    let engine = makeEngine(session: session, clock: clock)
    await engine.ingest(.discoverResponse(SignalBarsFixtures.discoverResponse(
      publicKey: SignalBarsFixtures.publicKey([0x0C]),
      snr: 8
    )))
    await engine.runCycle()
    let tag = try #require(await session.traces.last?.tag)

    clock.advance(0.4)
    await engine.ingest(.rxLogData(
      SignalBarsFixtures.traceReply(tag: tag, localSnr: 4, remoteSnrX4: 24)
    ))

    let entry = try #require(await engine.currentSnapshot().repeaters.first)
    #expect(entry.txSnr == 6)
    #expect(entry.txState == .measured(.good))
    #expect(entry.rttMs == 400)
    #expect(entry.rxSnr == 7, "the reply's local SNR is smoothed into the RX leg")
    #expect(entry.failCount == 0)
  }

  @Test
  func `A reply for an unknown tag changes nothing`() async {
    let session = MockSignalBarsSession()
    let engine = makeEngine(session: session, clock: TestClock())
    await engine.ingest(.discoverResponse(SignalBarsFixtures.discoverResponse(
      publicKey: SignalBarsFixtures.publicKey([0x0C]),
      snrIn: 5
    )))
    let before = await engine.currentSnapshot()

    await engine.ingest(.rxLogData(SignalBarsFixtures.traceReply(tag: 0xDEAD_BEEF)))

    #expect(await engine.currentSnapshot().repeaters == before.repeaters)
  }

  @Test
  func `A probe that never answers times out on the clock and counts as a failure`() async throws {
    let session = MockSignalBarsSession()
    let clock = TestClock()
    await session.setTraceResult(
      MessageSentInfo(route: 0, expectedAck: Data(), suggestedTimeoutMs: 3000)
    )
    let engine = makeEngine(session: session, clock: clock)
    await engine.ingest(.discoverResponse(SignalBarsFixtures.discoverResponse(
      publicKey: SignalBarsFixtures.publicKey([0x0C])
    )))
    await engine.runCycle()

    clock.advance(2.9)
    await engine.expireProbes(now: clock.now)
    #expect(await engine.currentSnapshot().repeaters.first?.txState == .measuring)

    clock.advance(0.2)
    await engine.expireProbes(now: clock.now)
    let entry = try #require(await engine.currentSnapshot().repeaters.first)
    #expect(entry.txState == .failed)
    #expect(entry.failCount == 1)
  }

  @Test
  func `A late reply after a timeout is ignored`() async throws {
    let session = MockSignalBarsSession()
    let clock = TestClock()
    let engine = makeEngine(session: session, clock: clock)
    await engine.ingest(.discoverResponse(SignalBarsFixtures.discoverResponse(
      publicKey: SignalBarsFixtures.publicKey([0x0C])
    )))
    await engine.runCycle()
    let tag = try #require(await session.traces.last?.tag)

    clock.advance(60)
    await engine.expireProbes(now: clock.now)
    await engine.ingest(.rxLogData(SignalBarsFixtures.traceReply(tag: tag)))

    #expect(await engine.currentSnapshot().repeaters.first?.txState == .failed)
  }

  @Test
  func `A trace the radio refuses to send fails the probe immediately`() async throws {
    struct SendFailure: Error {}
    let session = MockSignalBarsSession()
    await session.setTraceError(SendFailure())
    let engine = makeEngine(session: session, clock: TestClock())
    await engine.ingest(.discoverResponse(SignalBarsFixtures.discoverResponse(
      publicKey: SignalBarsFixtures.publicKey([0x0C])
    )))

    await engine.runCycle()

    let entry = try #require(await engine.currentSnapshot().repeaters.first)
    #expect(entry.txState == .failed)
    #expect(entry.failCount == 1)
  }

  @Test
  func `A probe timeout leaves a measurement that arrived while it was in flight alone`() async throws {
    let session = MockSignalBarsSession()
    let clock = TestClock()
    let engine = makeEngine(session: session, clock: clock)
    await engine.ingest(.discoverResponse(SignalBarsFixtures.discoverResponse(
      publicKey: SignalBarsFixtures.publicKey([0x0C]),
      snrIn: 2
    )))
    await engine.runCycle()

    // A discover response answers the TX leg while the trace is still outstanding.
    clock.advance(1)
    await engine.ingest(.discoverResponse(SignalBarsFixtures.discoverResponse(
      publicKey: SignalBarsFixtures.publicKey([0x0C]),
      snrIn: 6
    )))
    clock.advance(5)
    await engine.expireProbes(now: clock.now)

    let entry = try #require(await engine.currentSnapshot().repeaters.first)
    #expect(entry.txSnr == 6)
    #expect(entry.txState == .measured(SNRQuality(snr: 6)))
    #expect(entry.failCount == 0, "the link answered; the timeout is stale news about it")
  }

  @Test
  func `Best-link flapping cannot probe faster than the cadence allows`() async throws {
    let session = MockSignalBarsSession()
    let clock = TestClock()
    let engine = makeEngine(session: session, clock: clock)
    for byte in [UInt8(0x01), 0x02] {
      await engine.ingest(.discoverResponse(SignalBarsFixtures.discoverResponse(
        publicKey: SignalBarsFixtures.publicKey([byte])
      )))
    }
    // Measure both, so neither is the "never probed" case that outranks everything anyway.
    for _ in 0..<2 {
      await engine.runCycle()
      let tag = try #require(await session.traces.last?.tag)
      await engine.ingest(.rxLogData(SignalBarsFixtures.traceReply(tag: tag)))
      clock.advance(1)
    }
    #expect(await session.traces.count == 2)

    // Two comparably scored repeaters trading places, once a second.
    for step in 0..<10 {
      await engine.ingest(.discoverResponse(SignalBarsFixtures.discoverResponse(
        publicKey: SignalBarsFixtures.publicKey([step.isMultiple(of: 2) ? 0x01 : 0x02]),
        snr: 20,
        snrIn: 20
      )))
      clock.advance(1)
      await engine.runCycle()
    }
    #expect(
      await session.traces.count == 2,
      "a promotion re-orders the probe queue; it does not bring the probe clock forward"
    )

    clock.advance(45)
    await engine.runCycle()
    #expect(await session.traces.count == 3, "the cadence itself still comes due")
  }

  @Test
  func `A promoted best link still waits out its failure backoff`() async {
    let session = MockSignalBarsSession()
    let clock = TestClock()
    let engine = makeEngine(session: session, clock: clock)
    // One probeable repeater and one the app can only hear, so the failed link can still
    // reach the head of the table.
    await engine.ingest(.discoverResponse(SignalBarsFixtures.discoverResponse(
      publicKey: SignalBarsFixtures.publicKey([0x01]),
      snr: 2,
      snrIn: 2
    )))
    await engine.ingest(.rxLogData(SignalBarsFixtures.relayedPacket(path: [0xBB], snr: 10)))

    await engine.runCycle()
    clock.advance(6)
    await engine.expireProbes(now: clock.now)
    let failed = await engine.currentSnapshot().repeaters.first(where: { $0.hexID == "01" })
    #expect(failed?.failCount == 1)

    // Heard strongly enough to lead the table again, which promotes it.
    await engine.ingest(.rxLogData(SignalBarsFixtures.relayedPacket(path: [0x01], snr: 40)))
    #expect(await engine.currentSnapshot().best?.hexID == "01")

    await engine.runCycle()
    #expect(await session.traces.count == 1, "the 20-second backoff outranks the promotion")

    clock.advance(15)
    await engine.runCycle()
    #expect(await session.traces.count == 2, "and once the backoff is served, the probe goes out")
  }

  @Test
  func `Discover probes are re-broadcast on their own interval, not every cycle`() async {
    let session = MockSignalBarsSession()
    let clock = TestClock()
    let engine = makeEngine(session: session, clock: clock)

    await engine.runCycle()
    await engine.runCycle()
    #expect(await session.discoverRequests.count == 1)

    clock.advance(30)
    await engine.runCycle()
    #expect(await session.discoverRequests.count == 2)
  }

  @Test
  func `A manual refresh discovers, probes every keyed repeater, and writes off the silent ones`() async {
    let session = MockSignalBarsSession()
    let clock = TestClock()
    let engine = makeEngine(session: session, clock: clock)
    for byte in [UInt8(0x01), 0x02] {
      await engine.ingest(.discoverResponse(SignalBarsFixtures.discoverResponse(
        publicKey: SignalBarsFixtures.publicKey([byte])
      )))
    }
    await engine.ingest(.rxLogData(SignalBarsFixtures.relayedPacket(path: [0xEE])))

    await engine.refreshAll()

    #expect(await session.discoverRequests.count == 1)
    #expect(await session.traces.count == 2, "the keyless repeater cannot be probed")
    let snapshot = await engine.currentSnapshot()
    #expect(!snapshot.isRefreshing)
    #expect(snapshot.repeaters.filter { $0.publicKey != nil }.allSatisfy { $0.txState == .failed })
  }

  @Test
  func `Refreshing one repeater in engine mode probes just that one`() async throws {
    let session = MockSignalBarsSession()
    let engine = makeEngine(session: session, clock: TestClock())
    for byte in [UInt8(0x01), 0x02] {
      await engine.ingest(.discoverResponse(SignalBarsFixtures.discoverResponse(
        publicKey: SignalBarsFixtures.publicKey([byte])
      )))
    }

    try await engine.requestRefresh(target: hexID("02"))

    let traces = await session.traces
    #expect(traces.count == 1)
    #expect(traces[0].path == Data([0x02]))
    #expect(await session.syncWrites.isEmpty, "engine mode never writes the sync slot")
  }

  // MARK: - Watched repeater

  @Test
  func `A watch matches the same node at any hash width`() async throws {
    let session = MockSignalBarsSession()
    let clock = TestClock()
    let engine = makeEngine(session: session, clock: clock)
    try await engine.watchRepeater(hexID("0C"))

    await engine.ingest(.rxLogData(
      SignalBarsFixtures.relayedPacket(path: [0x0C, 0x13], hashSize: 2, snr: 5)
    ))

    let watched = try #require(await engine.currentSnapshot().watched)
    #expect(watched.heardCount == 1)
    #expect(watched.rxSnr == 5)
    #expect(watched.rxQuality == .good)
    #expect(watched.lastHeardAt == clock.now)
  }

  @Test
  func `Hearing another repeater leaves the watch alone`() async throws {
    let session = MockSignalBarsSession()
    let engine = makeEngine(session: session, clock: TestClock())
    try await engine.watchRepeater(hexID("0C"))

    await engine.ingest(.rxLogData(SignalBarsFixtures.relayedPacket(path: [0xAA])))

    #expect(await engine.currentSnapshot().watched?.heardCount == 0)
  }

  @Test
  func `A watch keeps working in viewer mode, where the device does the hearing`() async throws {
    let session = MockSignalBarsSession()
    let engine = makeEngine(session: session, clock: TestClock(), mode: .viewer)
    try await engine.watchRepeater(hexID("0C"))

    await engine.ingest(.syncValue(.signalBars, SignalBarsFixtures.blob([
      SignalBarsFixtures.entry(hash: [0x0C, 0x13], rxSnrX4: 20, txSnrX4: 8, hasTx: true)
    ])))

    let watched = try #require(await engine.currentSnapshot().watched)
    #expect(watched.heardCount == 1)
    #expect(watched.rxSnr == 5)
    #expect(watched.txSnr == 2)
  }

  @Test
  func `A probe reply counts as hearing the watched repeater`() async throws {
    let session = MockSignalBarsSession()
    let clock = TestClock()
    let engine = makeEngine(session: session, clock: clock)
    await engine.ingest(.discoverResponse(SignalBarsFixtures.discoverResponse(
      publicKey: SignalBarsFixtures.publicKey([0x0C])
    )))
    try await engine.watchRepeater(hexID("0C"))
    await engine.runCycle()
    let tag = try #require(await session.traces.last?.tag)

    await engine.ingest(.rxLogData(SignalBarsFixtures.traceReply(tag: tag, remoteSnrX4: 16)))

    let watched = try #require(await engine.currentSnapshot().watched)
    #expect(watched.heardCount == 1)
    #expect(watched.txSnr == 4)
  }

  @Test
  func `Clearing the watch drops its state`() async throws {
    let session = MockSignalBarsSession()
    let engine = makeEngine(session: session, clock: TestClock())
    try await engine.watchRepeater(hexID("0C"))
    await engine.watchRepeater(nil)

    #expect(await engine.currentSnapshot().watched == nil)
  }

  // MARK: - Display filtering

  @Test
  func `A dismissed repeater reappears when the radio hears it again`() async throws {
    let session = MockSignalBarsSession()
    let clock = TestClock()
    let engine = makeEngine(session: session, clock: clock)
    await engine.ingest(.rxLogData(SignalBarsFixtures.relayedPacket(path: [0x0C])))

    clock.advance(1)
    try await engine.dismissRepeater(hexID("0C"))
    var snapshot = await engine.currentSnapshot()
    #expect(snapshot.displayRepeaters.isEmpty)
    #expect(snapshot.repeaters.count == 1, "the row is hidden locally, not deleted")

    clock.advance(10)
    await engine.ingest(.rxLogData(SignalBarsFixtures.relayedPacket(path: [0x0C])))
    snapshot = await engine.currentSnapshot()
    #expect(snapshot.displayRepeaters.map(\.hexID) == ["0C"])
  }

  @Test
  func `Stale rows are hidden and can be cleared in one action`() async {
    let session = MockSignalBarsSession()
    let clock = TestClock()
    let engine = makeEngine(session: session, clock: clock, mode: .viewer)
    await engine.ingest(.syncValue(.signalBars, SignalBarsFixtures.blob([
      SignalBarsFixtures.entry(hash: [0x01], ageSeconds: 1000),
      SignalBarsFixtures.entry(hash: [0x02], ageSeconds: 5)
    ])))

    var snapshot = await engine.currentSnapshot()
    #expect(snapshot.displayRepeaters.map(\.hexID) == ["02"])
    #expect(snapshot.hasStaleRepeaters)

    await engine.clearStaleRepeaters()
    snapshot = await engine.currentSnapshot()
    #expect(!snapshot.hasStaleRepeaters)
    #expect(snapshot.repeaters.count == 2, "clearing stale rows never touches the device's table")
  }

  @Test
  func `Turning off auto-hide shows stale rows again`() async {
    let session = MockSignalBarsSession()
    let engine = makeEngine(session: session, clock: TestClock(), mode: .viewer)
    await engine.ingest(.syncValue(.signalBars, SignalBarsFixtures.blob([
      SignalBarsFixtures.entry(hash: [0x01], ageSeconds: 1000)
    ])))
    #expect(await engine.currentSnapshot().displayRepeaters.isEmpty)

    await engine.setStaleHideThreshold(nil)

    #expect(await engine.currentSnapshot().displayRepeaters.count == 1)
  }

  @Test
  func `Engine mode drops repeaters it has not heard in five minutes`() async {
    let session = MockSignalBarsSession()
    let clock = TestClock()
    let engine = makeEngine(session: session, clock: clock)
    await engine.ingest(.rxLogData(SignalBarsFixtures.relayedPacket(path: [0x0C])))

    clock.advance(301)
    await engine.runCycle()

    #expect(await engine.currentSnapshot().repeaters.isEmpty)
  }

  // MARK: - Names

  @Test
  func `Names are resolved through the identity resolver, not by matching hex strings`() async {
    let session = MockSignalBarsSession()
    let directory = StubNodeDirectory(nodes: [
      AnyResolvableNode(StubResolvableNode(
        publicKey: SignalBarsFixtures.publicKey([0x0C, 0x13]),
        resolvableName: "Hilltop Repeater"
      )),
      AnyResolvableNode(StubResolvableNode(
        publicKey: SignalBarsFixtures.publicKey([0xAA]),
        resolvableName: "Somewhere Else"
      ))
    ])
    let engine = makeEngine(
      session: session,
      clock: TestClock(),
      pathHashMode: 1,
      directory: directory
    )

    await engine.ingest(.discoverResponse(SignalBarsFixtures.discoverResponse(
      publicKey: SignalBarsFixtures.publicKey([0x0C, 0x13])
    )))

    #expect(await engine.currentSnapshot().repeaters.first?.name == "Hilltop Repeater")
  }

  @Test
  func `A row holding the full public key is named from it, not from the hash guess`() async {
    let session = MockSignalBarsSession()
    // Ridge advertised more recently, so a 1-byte hash guess for 0x0C would pick it.
    let directory = StubNodeDirectory(nodes: [
      AnyResolvableNode(StubResolvableNode(
        publicKey: SignalBarsFixtures.publicKey([0x0C, 0x99]),
        lastAdvertTimestamp: 2_000,
        resolvableName: "Ridge"
      )),
      AnyResolvableNode(StubResolvableNode(
        publicKey: SignalBarsFixtures.publicKey([0x0C, 0x13]),
        lastAdvertTimestamp: 1_000,
        resolvableName: "Hilltop"
      ))
    ])
    let engine = makeEngine(
      session: session,
      clock: TestClock(),
      pathHashMode: 0,
      directory: directory
    )

    await engine.ingest(.discoverResponse(SignalBarsFixtures.discoverResponse(
      publicKey: SignalBarsFixtures.publicKey([0x0C, 0x13])
    )))

    #expect(await engine.currentSnapshot().repeaters.first?.name == "Hilltop")
  }

  @Test
  func `A discover response corrects a wrong 1-byte hash guess`() async {
    let session = MockSignalBarsSession()
    let clock = TestClock()
    let directory = StubNodeDirectory(nodes: [
      AnyResolvableNode(StubResolvableNode(
        publicKey: SignalBarsFixtures.publicKey([0x0C, 0x99]),
        lastAdvertTimestamp: 2_000,
        resolvableName: "Ridge"
      )),
      AnyResolvableNode(StubResolvableNode(
        publicKey: SignalBarsFixtures.publicKey([0x0C, 0x13]),
        lastAdvertTimestamp: 1_000,
        resolvableName: "Hilltop"
      ))
    ])
    let engine = makeEngine(
      session: session,
      clock: clock,
      pathHashMode: 0,
      directory: directory
    )

    // Passive 1-byte sighting: recency picks Ridge — the best available guess.
    await engine.ingest(.rxLogData(SignalBarsFixtures.relayedPacket(path: [0x0C])))
    #expect(await engine.currentSnapshot().repeaters.first?.name == "Ridge")

    // The discover response proves the row is Hilltop; the stored key must beat
    // the earlier guess even though the row already had a name.
    clock.advance(6)
    await engine.ingest(.discoverResponse(SignalBarsFixtures.discoverResponse(
      publicKey: SignalBarsFixtures.publicKey([0x0C, 0x13])
    )))
    #expect(await engine.currentSnapshot().repeaters.first?.name == "Hilltop")
  }

  @Test
  func `nodePoolDidChange re-resolves already-named rows`() async {
    let session = MockSignalBarsSession()
    let clock = TestClock()
    let directory = MutableNodeDirectory(nodes: [
      AnyResolvableNode(StubResolvableNode(
        publicKey: SignalBarsFixtures.publicKey([0x0C, 0x13]),
        resolvableName: "Old Name"
      ))
    ])
    let engine = makeEngine(session: session, clock: clock, directory: directory)

    await engine.ingest(.rxLogData(SignalBarsFixtures.relayedPacket(path: [0x0C])))
    #expect(await engine.currentSnapshot().repeaters.first?.name == "Old Name")

    await directory.replace([
      AnyResolvableNode(StubResolvableNode(
        publicKey: SignalBarsFixtures.publicKey([0x0C, 0x13]),
        resolvableName: "New Name"
      ))
    ])
    await engine.nodePoolDidChange()
    #expect(await engine.currentSnapshot().repeaters.first?.name == "New Name")
  }

  @Test
  func `A hash that names no known node stays unnamed`() async {
    let session = MockSignalBarsSession()
    let directory = StubNodeDirectory(nodes: [
      AnyResolvableNode(StubResolvableNode(
        publicKey: SignalBarsFixtures.publicKey([0xAA]),
        resolvableName: "Somewhere Else"
      ))
    ])
    let engine = makeEngine(session: session, clock: TestClock(), directory: directory)

    await engine.ingest(.rxLogData(SignalBarsFixtures.relayedPacket(path: [0x0C])))

    #expect(await engine.currentSnapshot().repeaters.first?.name == nil)
  }

  // MARK: - Lifecycle and publishing

  @Test
  func `Subscribers receive a snapshot whenever the table changes`() async throws {
    let session = MockSignalBarsSession()
    let engine = makeEngine(session: session, clock: TestClock())
    var stream = engine.snapshots().makeAsyncIterator()

    await engine.ingest(.rxLogData(SignalBarsFixtures.relayedPacket(path: [0x0C])))

    let snapshot = try #require(await stream.next())
    #expect(snapshot.repeaters.map(\.hexID) == ["0C"])
  }

  @Test
  func `Starting subscribes to the radio and folds its events into the table`() async throws {
    let session = MockSignalBarsSession()
    let clock = TestClock()
    let engine = SignalBarsEngine(
      session: session,
      configuration: SignalBarsEngine.Configuration(mode: .engine),
      now: clock.provider,
      // A real wait keeps the driver loop from spinning while the test runs.
      sleep: { _ in try? await Task.sleep(for: .milliseconds(50)) }
    )

    await engine.start()
    try await waitForCondition("engine never subscribed") { await session.subscriberCount == 1 }
    await session.emit(.rxLogData(SignalBarsFixtures.relayedPacket(path: [0x0C])))
    try await waitForCondition("event never reached the table") {
      await !engine.currentSnapshot().repeaters.isEmpty
    }

    await engine.stop()
    let snapshot = await engine.currentSnapshot()
    #expect(snapshot.repeaters.isEmpty, "stopping drops the table")
    #expect(snapshot.watched == nil)
  }

  @Test
  func `Stopping unsubscribes from the radio`() async throws {
    let session = MockSignalBarsSession()
    let engine = makeEngine(session: session, clock: TestClock(), mode: .viewer)

    await engine.start()
    try await waitForCondition("engine never subscribed") { await session.subscriberCount == 1 }
    await engine.stop()

    try await waitForCondition("subscription outlived stop()") {
      await session.subscriberCount == 0
    }
  }
}
