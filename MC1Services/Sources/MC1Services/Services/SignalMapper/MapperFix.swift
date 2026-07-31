import Foundation

/// A location fix, as much of one as the signal mapper is ever allowed to see.
///
/// Deliberately not `CLLocation`: the capture engine must be drivable from a test with no
/// CoreLocation involved, and keeping the type this narrow makes it obvious at every call
/// site that nothing beyond a coordinate, its accuracy and its age crosses into the mapper.
/// Raw coordinates never leave the phone — they are bucketed to an H3 cell inside the
/// engine and only the cell is ever stored (docs/SIGNAL_MAPPER_V2.md §3.1).
public struct MapperFix: Sendable, Equatable {
  public var latitude: Double
  public var longitude: Double
  /// Reported horizontal accuracy in meters. Negative means "no valid fix", matching
  /// CoreLocation's own convention, and is rejected by the engine.
  public var horizontalAccuracyMeters: Double
  /// Ground speed in m/s when the platform reports a valid one.
  ///
  /// The fix gate's displacement budget reads this (§2.2): a fix taken at 15 m/s is a claim
  /// about a place the phone left seconds ago, and how many seconds is exactly
  /// `displacement / speed`. It needs no permission — CoreLocation reports speed with the
  /// same fix it reports the coordinate with — which is what makes it the mechanism that
  /// still works when Motion & Fitness was declined.
  public var speedMetersPerSecond: Double?
  /// When the fix was captured — not when it was handed over. The staleness rule is about
  /// the former.
  public var timestamp: Date
  /// Whether the phone is known to have moved since this fix was captured.
  ///
  /// Set by the fix cache when its movement hint reports motion while this fix is the one
  /// being served, and cleared by construction whenever a fresh fix replaces it. The engine
  /// **rejects** a fix carrying this: age and accuracy both say a fix is good, and neither
  /// notices that the phone carrying it walked away — which is precisely how a packet ends
  /// up attributed to a cell the user has left (§2.2).
  ///
  /// It is a one-way flag, not a distance: the cache knows *that* we moved, never how far.
  /// Learning how far would mean another fix, which is the thing being waited for.
  public var movedSinceCapture: Bool

  public init(
    latitude: Double,
    longitude: Double,
    horizontalAccuracyMeters: Double,
    speedMetersPerSecond: Double? = nil,
    timestamp: Date,
    movedSinceCapture: Bool = false
  ) {
    self.latitude = latitude
    self.longitude = longitude
    self.horizontalAccuracyMeters = horizontalAccuracyMeters
    self.speedMetersPerSecond = speedMetersPerSecond
    self.timestamp = timestamp
    self.movedSinceCapture = movedSinceCapture
  }
}

/// Supplies the most recent usable location fix.
///
/// The real implementation is CoreLocation-backed and lives in the app target
/// (`MapperFixCache`) — MC1Services deliberately does not import CoreLocation here, so the
/// capture engine stays testable and this package stays free of the permission-bearing
/// frameworks.
///
/// **Never blocks.** An implementation returns whatever it already holds and refreshes in
/// the background; a packet arrives on the RX path and the engine cannot sit on it waiting
/// for GPS. Returning `nil` is a normal answer, and the engine drops the observation
/// rather than queueing it — a guessed cell is worse than no cell (§2.2).
public protocol MapperFixProviding: Sendable {
  /// The cached fix, or nil when there isn't one worth handing over.
  func latestFix() async -> MapperFix?
}

/// A provider that never has a fix. The default wiring, so an unconfigured engine captures
/// nothing rather than capturing something wrong.
public struct NoMapperFixProvider: MapperFixProviding {
  public init() {}

  public func latestFix() async -> MapperFix? {
    nil
  }
}
