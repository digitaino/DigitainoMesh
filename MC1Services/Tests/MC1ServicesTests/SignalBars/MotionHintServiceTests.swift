import Foundation
@testable import MC1Services
@testable import MeshCore
import Testing

@Suite("MotionHintService")
struct MotionHintServiceTests {
  /// A probe that has already classified the device as advertising the motion-hint slot.
  private func makeCapableProbe(_ session: MockSyncRegistrySession) async -> SyncRegistryProbe {
    await session.setListSyncResult(.success([SyncRegistryFixtures.motionHintSlot]))
    let probe = SyncRegistryProbe(session: session)
    await probe.probe()
    return probe
  }

  // MARK: - Wire format

  @Test
  func `a level is written as version byte then level`() async {
    let session = MockSyncRegistrySession()
    let probe = await makeCapableProbe(session)
    let service = MotionHintService(session: session, registry: probe)

    #expect(await service.push(.slow))

    let writes = await session.syncWrites
    #expect(writes.count == 1)
    #expect(writes[0].id == .motionHint)
    #expect(writes[0].payload == Data([1, 1]))
  }

  @Test
  func `every movement level maps to its firmware code`() async {
    let session = MockSyncRegistrySession()
    let probe = await makeCapableProbe(session)
    let service = MotionHintService(session: session, registry: probe)

    for hint in MovementHint.allCases {
      await service.push(hint)
    }

    let payloads = await session.syncWrites.map(\.payload)
    #expect(payloads == [Data([1, 0]), Data([1, 1]), Data([1, 2])])
  }

  // MARK: - Debounce

  @Test
  func `an unchanged level is not written twice`() async {
    let session = MockSyncRegistrySession()
    let probe = await makeCapableProbe(session)
    let service = MotionHintService(session: session, registry: probe)

    #expect(await service.push(.fast))
    #expect(await service.push(.fast) == false)
    #expect(await service.push(.fast) == false)

    #expect(await session.syncWrites.count == 1)
  }

  @Test
  func `a changed level is written`() async {
    let session = MockSyncRegistrySession()
    let probe = await makeCapableProbe(session)
    let service = MotionHintService(session: session, registry: probe)

    await service.push(.stationary)
    await service.push(.slow)
    await service.push(.stationary)

    #expect(await session.syncWrites.count == 3)
  }

  @Test
  func `a moving level is re-pushed once the keepalive interval elapses`() async {
    let clock = TestClock()
    let session = MockSyncRegistrySession()
    let probe = await makeCapableProbe(session)
    let service = MotionHintService(
      session: session,
      registry: probe,
      refreshInterval: 45,
      now: clock.provider
    )

    #expect(await service.push(.slow))
    clock.advance(44)
    #expect(await service.push(.slow) == false)
    clock.advance(2)
    #expect(await service.push(.slow))

    #expect(await session.syncWrites.count == 2)
  }

  @Test
  func `a stationary level is never re-pushed by the keepalive`() async {
    let clock = TestClock()
    let session = MockSyncRegistrySession()
    let probe = await makeCapableProbe(session)
    let service = MotionHintService(
      session: session,
      registry: probe,
      refreshInterval: 45,
      now: clock.provider
    )

    #expect(await service.push(.stationary))
    clock.advance(600)
    #expect(await service.push(.stationary) == false)

    #expect(await session.syncWrites.count == 1)
  }

  @Test
  func `reset makes the next unchanged level push again`() async {
    let session = MockSyncRegistrySession()
    let probe = await makeCapableProbe(session)
    let service = MotionHintService(session: session, registry: probe)

    await service.push(.slow)
    await service.reset()
    #expect(await service.push(.slow))

    #expect(await session.syncWrites.count == 2)
  }

  // MARK: - Capability gating

  @Test
  func `nothing is written when the slot is not advertised`() async {
    let session = MockSyncRegistrySession(listSyncResult: .success([SyncRegistryFixtures.signalBarsSlot]))
    let probe = SyncRegistryProbe(session: session)
    await probe.probe()
    let service = MotionHintService(session: session, registry: probe)

    #expect(await service.push(.fast) == false)
    #expect(await session.syncWrites.isEmpty)
  }

  @Test
  func `nothing is written on firmware without the sync registry`() async {
    let session = MockSyncRegistrySession(listSyncResult: .failure(SyncRegistryFixtures.rejection))
    let probe = SyncRegistryProbe(session: session)
    let service = MotionHintService(session: session, registry: probe)

    #expect(await service.push(.fast) == false)
    #expect(await session.syncWrites.isEmpty)
  }

  @Test
  func `a rejected write latches the service inert`() async {
    let session = MockSyncRegistrySession()
    let probe = await makeCapableProbe(session)
    await session.setSetSyncError(SyncRegistryFixtures.rejection)
    let service = MotionHintService(session: session, registry: probe)

    #expect(await service.push(.slow) == false)
    #expect(await service.push(.fast) == false)

    #expect(await session.syncWrites.count == 1)
  }

  @Test
  func `a transient write failure is retried on the next reading`() async {
    let session = MockSyncRegistrySession()
    let probe = await makeCapableProbe(session)
    await session.setSetSyncError(SyncRegistryFixtures.timeout)
    let service = MotionHintService(session: session, registry: probe)

    #expect(await service.push(.slow) == false)
    await session.setSetSyncError(nil)
    #expect(await service.push(.slow))

    #expect(await session.syncWrites.count == 2)
  }
}
