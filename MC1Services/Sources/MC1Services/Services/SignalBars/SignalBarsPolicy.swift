import Foundation

/// Every cadence, threshold and priority rule the signal-bars engine follows, as data.
///
/// The engine holds one of these and asks it questions; nothing here touches a clock or a
/// radio, so the whole probe schedule is testable by passing a `now`. Defaults mirror the
/// firmware's own round-robin engine so app and device converge on the same table.
public struct SignalBarsPolicy: Sendable, Equatable {
  /// Minimum gap between two probes, so the engine never bursts the radio.
  public var minProbeSpacing: Duration = .seconds(1)
  /// How often viewer mode re-reads the device's table when no push arrives.
  public var viewerPollInterval: Duration = .seconds(5)
  /// Base probe interval for the current best link — the one worth keeping fresh.
  public var bestRepeaterInterval: TimeInterval = 45
  /// Base probe interval for every other tracked repeater.
  public var otherRepeaterInterval: TimeInterval = 120
  /// Backoff after 1, 2, and 3+ consecutive probe failures.
  public var failRetryIntervals: [TimeInterval] = [20, 45, 90]
  /// Consecutive failures at which the engine stops probing a repeater altogether.
  public var maxFailCount: Int = 4
  /// Age at which an entry is dropped from the table entirely (engine mode only — in
  /// viewer mode the device owns the table).
  public var staleThreshold: TimeInterval = 300
  /// Age past which an entry is hidden from the display list. `nil` disables auto-hide.
  public var staleHideThreshold: TimeInterval? = 900
  /// Window used by "clear stale" when auto-hide is disabled.
  public var manualClearWindow: TimeInterval = 60
  /// Delay between hearing a repeater and firing the reactive probe it triggered.
  public var reactiveTriggerDelay: TimeInterval = 2
  /// Minimum gap before a repeater whose TX leg already failed is reactively re-probed.
  public var reactiveFailedCooldown: TimeInterval = 30
  /// How often engine mode broadcasts a discover request.
  public var discoverProbeInterval: TimeInterval = 30
  /// Table capacity, matching the firmware's `SIGNAL_MAX`.
  public var maxTrackedRepeaters: Int = 8
  /// Probe timeout used until the device suggests one.
  public var defaultProbeTimeoutMs: Int = 5000
  /// Idle wait when nothing is due to be probed.
  public var idleCycleInterval: Duration = .seconds(2)
  /// How long a device-side discovery scan is given before re-reading the table.
  public var discoveryScanSettleDelay: Duration = .seconds(4)
  /// How long a device-side ping is given before re-reading the table.
  public var deviceProbeSettleDelay: Duration = .seconds(2)
  /// How long a discover broadcast is given to bring in public keys before ping-all.
  public var discoverSettleDelay: Duration = .seconds(3)
  /// Minimum gap between name-resolution passes over the node directory.
  public var nameResolveThrottle: TimeInterval = 5
  /// Discover filter selecting repeaters only.
  public var discoverFilter: UInt8 = 0x04

  public init() {}

  /// How often this repeater should be probed, or `nil` to stop probing it.
  ///
  /// Failed links back off on a 20/45/90-second ladder and drop out entirely at
  /// ``maxFailCount``; healthy ones split into the best link and everything else. The
  /// movement hint then shortens whatever came out, because a moving radio's links change
  /// faster than a parked one's.
  public func probeInterval(
    for repeater: RepeaterSignal,
    isBest: Bool,
    movement: MovementHint
  ) -> TimeInterval? {
    guard repeater.failCount < maxFailCount else { return nil }
    let base: TimeInterval
    if repeater.failCount > 0 {
      let index = min(repeater.failCount, failRetryIntervals.count) - 1
      base = failRetryIntervals[max(0, index)]
    } else {
      base = isBest ? bestRepeaterInterval : otherRepeaterInterval
    }
    return base / Double(movement.cadenceDivisor)
  }

  /// The repeater most in need of a probe, or `nil` when nothing is due.
  ///
  /// A repeater that has never been probed always wins — an unknown TX leg is the biggest
  /// gap in the table. Among the rest, the most overdue goes first. Repeaters without a
  /// public key are unprobeable and skipped.
  public func nextProbeTarget(
    among repeaters: [RepeaterSignal],
    now: Date,
    movement: MovementHint
  ) -> RepeaterSignal? {
    let bestID = repeaters.first?.id
    var choice: (repeater: RepeaterSignal, urgency: TimeInterval)?

    for repeater in repeaters {
      let isBest = bestID.map { repeater.id == $0 } ?? false
      guard let urgency = probeUrgency(
        for: repeater,
        isBest: isBest,
        now: now,
        movement: movement
      ) else { continue }

      if choice == nil || urgency < choice!.urgency {
        choice = (repeater, urgency)
      }
    }

    return choice?.repeater
  }

  /// How badly this repeater needs a probe, as a sort key where lower goes first, or `nil` when
  /// it must not be probed at all right now: unprobeable, already in flight, burnt out, or
  /// still inside its interval.
  ///
  /// Exposed so a caller with an ordering preference of its own — the engine's newly promoted
  /// best link — asks whether a row is due instead of reaching around the cadence and the
  /// failure ladder to probe it.
  public func probeUrgency(
    for repeater: RepeaterSignal,
    isBest: Bool,
    now: Date,
    movement: MovementHint
  ) -> TimeInterval? {
    guard repeater.publicKey != nil else { return nil }
    guard !repeater.isMeasuring else { return nil }
    guard let interval = probeInterval(for: repeater, isBest: isBest, movement: movement) else {
      return nil
    }
    // A never-measured TX leg is the biggest gap in the table, so it outranks any overdue row.
    guard repeater.txState != .unknown else { return -TimeInterval.infinity }
    let overdue = now.timeIntervalSince(repeater.lastProbeAt ?? .distantPast) - interval
    return overdue >= 0 ? -overdue : nil
  }

  /// Whether hearing this repeater should schedule a reactive probe.
  ///
  /// Never measured means measure now; already failed means try again, but only after the
  /// cooldown — hearing a packet suggests the link may be back, and re-probing on every
  /// packet would flood a marginal link.
  public func shouldProbeReactively(_ repeater: RepeaterSignal, now: Date) -> Bool {
    guard repeater.publicKey != nil else { return false }
    switch repeater.txState {
    case .unknown:
      return true
    case .failed:
      let lastProbe = repeater.lastProbeAt ?? .distantPast
      return now.timeIntervalSince(lastProbe) > reactiveFailedCooldown
    case .measuring, .measured:
      return false
    }
  }
}
