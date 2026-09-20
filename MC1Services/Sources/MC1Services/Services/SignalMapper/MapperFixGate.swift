import Foundation
import SurveyKit

/// The one place that decides what a location fix is good for.
///
/// It exists because there used to be two answers. The probe engine planned transmissions on
/// its own `usableFix()` — present, not moved, inside the flat age budget — while the capture
/// engine placed the *results* on a stricter test that also demanded horizontal accuracy and a
/// speed-scaled age. During GPS warm-up the two disagreed for minutes at a time: probes flew,
/// the ride strip counted the replies, and every row they produced was written with no
/// `cellRaw` at all, invisible to the card and to the summaries for ever, because the store's
/// cell fetch is an equality match on a column that was nil (field report with screenshot,
/// 2026-09-04 — HUD "3 probes · 12 replies", card "Unknown / 0 readings of you").
///
/// So there are two verdicts here rather than two gates, and they are nested:
///
/// - **Placeable.** A fix exists, the phone is not known to have moved away from it, it is
///   inside the flat ``MapperTuning/fixMaxAgeSeconds``, and its coordinate resolves to a cell.
///   This is exactly what the probe engine asks before transmitting, so *if a probe is sent,
///   its reply can be placed* — the invariant the disagreement broke.
/// - **Confident** (``MapperGateOutcome/accepted``). Placeable, and it also passes the
///   speed-scaled age budget and the accuracy limit. Only a confident fix may fold into the
///   `(cell, day)` aggregates, feed the dead-zone `probesSent` denominator or be tested
///   against an anchor disc. That path is unchanged, deliberately: a doubtful placement must
///   never reach a statistic.
///
/// A raw row keeps the placeable cell either way and records ``MapperGateOutcome`` beside it,
/// which is the owner's decision of 2026-09-04: §2 of docs/SIGNAL_MAPPER_V3.md gives the
/// observation table `horizontalAccuracyMeters` and `fixAgeSeconds` columns precisely so a
/// consumer can filter by quality later, and throwing the position away is the one thing no
/// downstream reader can undo. A row is therefore confidently placed when `cellRaw != nil &&
/// gateOutcome == .accepted`, doubtfully placed when `cellRaw != nil` and the outcome is
/// anything else, and unplaced when `cellRaw` is nil.
///
/// Pure and synchronous: it reads a fix, a clock reading and a tuning, and touches no actor
/// state, so both engines can call it and a test can call it with neither.
public enum MapperFixGate {
  /// What one fix is worth, from both readings at once.
  public struct Verdict: Sendable, Equatable {
    /// The fix examined, whenever there was one — a rejected fix still knew something, and
    /// the raw row records it.
    public let fix: MapperFix?
    /// The coordinate and cell the fix resolves to, or nil when it is not placeable at all.
    public let coordinate: GeoCoordinate?
    public let cell: H3Cell?
    public let outcome: MapperGateOutcome

    /// Whether a row may carry this fix's cell. Doubtful placements are placeable.
    public var isPlaceable: Bool {
      cell != nil
    }

    /// Whether an aggregate, an anchor test or a probe denominator may use it.
    public var isConfident: Bool {
      outcome == .accepted
    }
  }

  /// Grades `fix` as of `now`.
  ///
  /// The order of the tests is the order in which a fix stops being usable, and it is not
  /// arbitrary:
  ///
  /// 1. **There isn't one.** Nothing to place against.
  /// 2. **The phone moved.** The cache saw a movement hint after this fix was taken, so
  ///    whatever the fix says, the phone is somewhere else now. Age and accuracy both still
  ///    look perfect here, which is why this test has to exist separately.
  /// 3. **It is older than the flat budget.** Past ``MapperTuning/fixMaxAgeSeconds`` nothing
  ///    may be placed at all: at that point the coordinate is a claim about a different
  ///    place, not a vaguer claim about this one.
  /// 4. **Its accuracy is negative.** CoreLocation's sentinel for "the latitude and
  ///    longitude in this object are not a real fix" — so there is no position to keep, and
  ///    the (0, 0) it usually carries resolves to a perfectly good cell in the Gulf of
  ///    Guinea if anything is allowed to place it.
  /// 5. **It resolves to no cell.** A coordinate outside the grid places nothing.
  ///
  /// Everything after that is *doubt*, not absence, and keeps the cell: the speed-scaled age
  /// budget first (so a fix that fails both still reports the same `.staleFix` it always
  /// did), then accuracy.
  public static func evaluate(fix: MapperFix?, at now: Date, tuning: MapperTuning) -> Verdict {
    guard let fix else {
      return Verdict(fix: nil, coordinate: nil, cell: nil, outcome: .noFix)
    }
    guard !fix.movedSinceCapture else {
      return Verdict(fix: fix, coordinate: nil, cell: nil, outcome: .movedSinceCapture)
    }
    guard now.timeIntervalSince(fix.timestamp) <= tuning.fixMaxAgeSeconds else {
      return Verdict(fix: fix, coordinate: nil, cell: nil, outcome: .staleFix)
    }
    // Unplaceable rather than doubtful, and this is the one accuracy test that belongs on
    // this side of the line. A negative ``MapperFix/horizontalAccuracyMeters`` is
    // CoreLocation's sentinel saying the coordinate *itself* is invalid — it is normally
    // (0, 0), which `SurveyGrid` resolves happily — so unlike an accuracy that is merely
    // too poor there is no position here to hand downstream. Keeping it painted a hexagon
    // at 0°N 0°E from the raw log, and "fit all" then framed the map from the rider to the
    // Gulf of Guinea.
    guard fix.horizontalAccuracyMeters >= 0 else {
      return Verdict(fix: fix, coordinate: nil, cell: nil, outcome: .inaccurateFix)
    }

    let coordinate = GeoCoordinate(latitude: fix.latitude, longitude: fix.longitude)
    guard let cell = SurveyGrid.cell(containing: coordinate) else {
      return Verdict(fix: fix, coordinate: coordinate, cell: nil, outcome: .noFix)
    }

    guard now.timeIntervalSince(fix.timestamp) <= toleratedAgeSeconds(for: fix, tuning: tuning) else {
      return Verdict(fix: fix, coordinate: coordinate, cell: cell, outcome: .staleFix)
    }
    // Doubt, not absence: the coordinate is real and merely vague, and throwing it away is
    // the one thing no downstream reader can undo. The sentinel that says it is *not* real
    // was rejected above.
    guard fix.horizontalAccuracyMeters <= tuning.fixMaxAccuracyMeters else {
      return Verdict(fix: fix, coordinate: coordinate, cell: cell, outcome: .inaccurateFix)
    }

    return Verdict(fix: fix, coordinate: coordinate, cell: cell, outcome: .accepted)
  }

  /// How old a fix may be before it stops describing where the phone is.
  ///
  /// ``MapperTuning/fixMaxAgeSeconds`` is a bound on *time*, and the thing that actually
  /// matters is a bound on *distance*: at 15 m/s a 119-second-old fix passes the age test
  /// and points at a cell nearly two kilometers back down the road. So when the fix reports
  /// its own ground speed — which CoreLocation supplies with the fix and no permission
  /// gates — the budget shrinks to `fixMaxDisplacementMeters / speed`, and the effective
  /// limit is whichever of the two is tighter.
  ///
  /// A stationary phone (speed 0, or a platform that reported none) keeps the full age
  /// budget, which is correct: it is still in the same cell an hour later. This is the half
  /// of the movement rule that survives a declined Motion & Fitness prompt, where the
  /// hint-driven ``MapperFix/movedSinceCapture`` never fires at all.
  public static func toleratedAgeSeconds(for fix: MapperFix, tuning: MapperTuning) -> TimeInterval {
    guard let speed = fix.speedMetersPerSecond, speed > 0,
          tuning.fixMaxDisplacementMeters > 0 else {
      return tuning.fixMaxAgeSeconds
    }
    return Swift.min(tuning.fixMaxAgeSeconds, tuning.fixMaxDisplacementMeters / speed)
  }
}
