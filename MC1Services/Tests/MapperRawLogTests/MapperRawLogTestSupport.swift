import Foundation
@testable import MapperRawLog
import MC1Services
import os

/// A clock the tests drive by hand.
///
/// The recorder's flush deadline is checked lazily against an injected `now`, so a test
/// that wanted to observe a five-second flush would otherwise have to sleep for five
/// seconds. Mirrors `SignalBarsTestSupport.TestClock` in the MC1Services test target;
/// duplicated rather than shared because test targets do not link each other, and a
/// shared test-support product would put MapperRawLog test code on MC1Services' side of
/// the dependency edge this module exists to enforce.
final class TestClock: Sendable {
  private let state: OSAllocatedUnfairLock<Date>

  init(_ start: Date = Date(timeIntervalSince1970: 1_753_000_000)) {
    state = OSAllocatedUnfairLock(initialState: start)
  }

  var now: Date {
    state.withLock { $0 }
  }

  var provider: @Sendable () -> Date {
    { [state] in state.withLock { $0 } }
  }

  @discardableResult
  func advance(_ interval: TimeInterval) -> Date {
    state.withLock { current in
      current = current.addingTimeInterval(interval)
      return current
    }
  }
}

// MARK: - Fixtures

/// A fully populated event, so a round trip exercises every column rather than the
/// handful a default instance happens to inhabit.
func rawEvent(
  at timestamp: Date,
  kind: MapperRawSampleKind = .probeTraceReply,
  cell: UInt64? = 0x0892_8308_280F_FFFF,
  gateOutcome: MapperGateOutcome = .accepted
) -> MapperRawSampleEvent {
  MapperRawSampleEvent(
    timestamp: timestamp,
    kind: kind,
    rxSnr: 6.25,
    txSnr: -3.5,
    rssi: -91,
    hopCount: 2,
    rttMs: 840,
    routeTypeRaw: 1,
    payloadTypeRaw: 4,
    perHopSnrs: [6.25, -3.5],
    repeaterHexID: "0C13",
    repeaterPublicKey: Data(repeating: 0xAB, count: 32),
    wasFocused: true,
    latitude: 37.7749,
    longitude: -122.4194,
    horizontalAccuracyMeters: 8,
    speedMetersPerSecond: 6.4,
    courseDegrees: 271.5,
    fixAgeSeconds: 1.2,
    cellRaw: cell,
    gateOutcome: gateOutcome
  )
}

/// A minimal breadcrumb-shaped event — the other end of the range, where almost every
/// column is nil.
func breadcrumbEvent(at timestamp: Date) -> MapperRawSampleEvent {
  MapperRawSampleEvent(
    timestamp: timestamp,
    kind: .breadcrumb,
    latitude: 37.7749,
    longitude: -122.4194,
    horizontalAccuracyMeters: 12,
    gateOutcome: .accepted
  )
}

/// Opens an in-memory store with one run already started.
func makeStoreWithRun(startedAt: Date, focusTargetHexIDs: [String] = []) async throws -> (MapperRawLogStore, UUID) {
  let store = try MapperRawLogStore.inMemory()
  let runID = try await store.createRun(
    radioID: UUID(),
    frequency: 869_525_000,
    bandwidth: 250_000,
    spreadingFactor: 11,
    codingRate: 5,
    txPower: 22,
    focusTargetHexIDs: focusTargetHexIDs,
    startedAt: startedAt
  )
  return (store, runID)
}
