import Foundation
@testable import MC1Services
@testable import MeshCore
import Testing

/// A scriptable stand-in for the two sync-registry operations, recording every call so a
/// test can prove the latch avoided a round trip.
actor MockSyncRegistrySession: SyncRegistrySessionOps {
  private(set) var listSyncCalls = 0
  private(set) var syncWrites: [(id: SyncID, payload: Data)] = []

  var listSyncResult: Result<[SyncListEntry], any Error> = .success([])
  var setSyncError: (any Error)?

  init(listSyncResult: Result<[SyncListEntry], any Error> = .success([])) {
    self.listSyncResult = listSyncResult
  }

  func setListSyncResult(_ result: Result<[SyncListEntry], any Error>) {
    listSyncResult = result
  }

  func setSetSyncError(_ error: (any Error)?) {
    setSyncError = error
  }

  func listSync() async throws -> [SyncListEntry] {
    listSyncCalls += 1
    return try listSyncResult.get()
  }

  func setSync(_ id: SyncID, payload: Data) async throws {
    syncWrites.append((id, payload))
    if let setSyncError { throw setSyncError }
  }
}

enum SyncRegistryFixtures {
  static let signalBarsSlot = SyncListEntry(id: SyncID.signalBars.rawValue, length: 32)
  static let motionHintSlot = SyncListEntry(id: SyncID.motionHint.rawValue, length: 2)
  static let notifPrefsSlot = SyncListEntry(id: SyncID.notifPrefs.rawValue, length: 8)

  /// The error stock firmware produces for an opcode it does not implement.
  static let rejection = MeshCoreError.deviceError(code: 1)
  /// A link problem, which must never latch a classification.
  static let timeout = MeshCoreError.timeout
}

@Suite("SyncRegistryProbe")
struct SyncRegistryProbeTests {
  // MARK: - Classification

  @Test
  func `a listSync reply classifies the device as supported`() async {
    let session = MockSyncRegistrySession(
      listSyncResult: .success([SyncRegistryFixtures.notifPrefsSlot, SyncRegistryFixtures.signalBarsSlot])
    )
    let probe = SyncRegistryProbe(session: session)

    #expect(await probe.probe() == .supported)
    #expect(await probe.supportsSlot(.signalBars))
    #expect(await probe.supportsSlot(.notifPrefs))
    #expect(await probe.supportsSlot(.motionHint) == false)
  }

  @Test
  func `a device error classifies the device as unsupported`() async {
    let session = MockSyncRegistrySession(listSyncResult: .failure(SyncRegistryFixtures.rejection))
    let probe = SyncRegistryProbe(session: session)

    #expect(await probe.probe() == .unsupported)
    #expect(await probe.supportsSlot(.signalBars) == false)
  }

  @Test
  func `a timeout leaves the classification unknown`() async {
    let session = MockSyncRegistrySession(listSyncResult: .failure(SyncRegistryFixtures.timeout))
    let probe = SyncRegistryProbe(session: session)

    #expect(await probe.probe() == .unknown)
    #expect(await probe.advertisedSlots.isEmpty)
  }

  // MARK: - Latching

  @Test
  func `a supported classification is answered from the latch`() async {
    let session = MockSyncRegistrySession(listSyncResult: .success([SyncRegistryFixtures.signalBarsSlot]))
    let probe = SyncRegistryProbe(session: session)

    await probe.probe()
    await probe.probe()
    await probe.probe()

    #expect(await session.listSyncCalls == 1)
  }

  @Test
  func `an unsupported classification is answered from the latch`() async {
    let session = MockSyncRegistrySession(listSyncResult: .failure(SyncRegistryFixtures.rejection))
    let probe = SyncRegistryProbe(session: session)

    await probe.probe()
    await probe.probe()

    #expect(await session.listSyncCalls == 1)
  }

  @Test
  func `an inconclusive probe retries rather than latching`() async {
    let session = MockSyncRegistrySession(listSyncResult: .failure(SyncRegistryFixtures.timeout))
    let probe = SyncRegistryProbe(session: session)

    #expect(await probe.probe() == .unknown)
    await session.setListSyncResult(.success([SyncRegistryFixtures.signalBarsSlot]))

    #expect(await probe.probe() == .supported)
    #expect(await session.listSyncCalls == 2)
  }

  // MARK: - Signal-bars mode

  @Test
  func `the advertised signal-bars slot selects viewer mode`() async {
    let session = MockSyncRegistrySession(listSyncResult: .success([SyncRegistryFixtures.signalBarsSlot]))
    let probe = SyncRegistryProbe(session: session)

    #expect(await probe.signalBarsMode() == .viewer)
  }

  @Test
  func `a rejected listSync selects engine mode`() async {
    let session = MockSyncRegistrySession(listSyncResult: .failure(SyncRegistryFixtures.rejection))
    let probe = SyncRegistryProbe(session: session)

    #expect(await probe.signalBarsMode() == .engine)
  }

  @Test
  func `a registry without the signal-bars slot still selects engine mode`() async {
    let session = MockSyncRegistrySession(listSyncResult: .success([SyncRegistryFixtures.notifPrefsSlot]))
    let probe = SyncRegistryProbe(session: session)

    #expect(await probe.signalBarsMode() == .engine)
    #expect(await probe.support == .supported)
  }

  @Test
  func `an inconclusive probe falls back to engine mode without latching`() async {
    let session = MockSyncRegistrySession(listSyncResult: .failure(SyncRegistryFixtures.timeout))
    let probe = SyncRegistryProbe(session: session)

    #expect(await probe.signalBarsMode() == .engine)
    #expect(await probe.support == .unknown)
  }
}
