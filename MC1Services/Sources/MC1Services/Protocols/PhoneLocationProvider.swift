import CoreLocation
import Foundation

/// A phone GPS fix at a moment in time, as the service layer sees it.
///
/// A plain value rather than `CLLocation` because the app target owns the
/// location frameworks; this package only carries the numbers (the same
/// boundary `ReferenceLocationProvider` draws for signal bars).
public struct PhoneLocationFix: Sendable, Equatable {
  public let latitude: Double
  public let longitude: Double
  /// When the fix was taken. Consumers judge usefulness by age
  /// (``NodeLocationStalenessPolicy/isFixFresh(_:now:maxFixAge:)``), never by
  /// presence — the app caches its last one-shot fix indefinitely.
  public let timestamp: Date

  public init(latitude: Double, longitude: Double, timestamp: Date) {
    self.latitude = latitude
    self.longitude = longitude
    self.timestamp = timestamp
  }
}

/// Read-only access to the phone's cached GPS fix, for stamping receive-time
/// location onto rows the service layer creates (`Message.userLatitude`/
/// `userLongitude`). Deliberately passive: implementations must never trigger
/// a location request or a permission prompt — ingestion runs constantly and
/// in the background, and it only gets to record what the app already knows.
public protocol PhoneLocationProvider: Sendable {
  /// The most recent fix the app holds, or nil when none exists.
  /// Async to allow MainActor-isolated implementations to be called from other actors.
  func currentFix() async -> PhoneLocationFix?
}

public extension PhoneLocationProvider {
  /// The current fix only when it is worth writing to a row: fresh (judged by
  /// age against ``NodeLocationStalenessPolicy/maxFixAge``) and geographically
  /// valid (no null-island sentinel). The one write-time gate every stamping
  /// site shares — ingest and send — so "what counts as a stampable fix" can
  /// never drift between them. Callers add their own event-shaped gates on
  /// top (ingest also requires a live delivery with bounded transit).
  func stampableFix(now: Date) async -> PhoneLocationFix? {
    guard let fix = await currentFix(),
          NodeLocationStalenessPolicy.isFixFresh(fix.timestamp, now: now),
          CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude).isValidFix
    else { return nil }
    return fix
  }
}
