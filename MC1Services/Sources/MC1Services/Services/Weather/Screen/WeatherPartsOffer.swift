import Foundation
import MeshWX

/// Whether to offer "Ask for the 3 missing parts", and what that ask is
/// (spec revision 10, §1.1; docs/MESHWX_UI.md §17).
///
/// The owner's first ask of revision 10, looking at a map that said "4 of 7 parts arrived":
/// *should allow me to re-request the missing data.* Three packets instead of eight, and the bot
/// sends the bytes it transmitted rather than rebuilding the answer, so what comes back fills the
/// holes in the assembly already on screen.
///
/// **Offered, never automatic.** Nothing in this app spends airtime without a tap, and a phone
/// that re-requested its own holes on appear would turn one lost packet into a packet per phone
/// per screen. Three conditions, and each of them is a different mistake avoided:
///
/// - The assembly is **incomplete**. Nothing to ask for otherwise.
/// - Its newest packet arrived at least ``settleSeconds`` ago. The bot resends a packet nothing
///   echoed, 8–10 s later, of its own accord (spec §2.3): offering inside that window asks for a
///   packet that is already on the air.
/// - Its first packet arrived no more than ``window`` ago. Past that the bot no longer holds the
///   bytes (`PARTS_CACHE_S`), so the ask can only come back Not available — and the ordinary
///   request, the whole map or the whole report, is the only honest offer.
public enum WeatherPartsOffer {
  /// How long to let the bot's own resend have its chance.
  public static let settleSeconds: TimeInterval = 15
  /// How long the bot keeps the bytes (spec revision 10, §1.1: `PARTS_CACHE_S = 600`).
  public static let window = TimeInterval(MeshWXWire.partsCacheSeconds)

  /// The ask for a sweep missing packets, or nil when it is not offered.
  public static func make(
    assembly: WeatherAreaSweepAssembly, kind: WeatherPartsKind = .areaSweep, now: Date
  ) -> WeatherRequest? {
    make(
      group: assembly.group,
      missingIndexes: assembly.missingIndexes,
      firstReceivedAt: assembly.firstReceivedAt,
      lastReceivedAt: assembly.lastReceivedAt,
      kind: kind,
      now: now)
  }

  /// The ask for a text reply missing a chunk, or nil when it is not offered. The same rule and
  /// the same wire request: a `group` is a `group` (spec §8.1, §7C).
  public static func make(
    assembly: WeatherTextAssembly, kind: WeatherPartsKind? = nil, now: Date
  ) -> WeatherRequest? {
    make(
      group: assembly.group,
      missingIndexes: assembly.missingIndexes,
      firstReceivedAt: assembly.firstReceivedAt,
      lastReceivedAt: assembly.lastReceivedAt,
      kind: kind ?? .text(subject: assembly.subject.rawValue),
      now: now)
  }

  static func make(
    group: UInt8,
    missingIndexes: [UInt8],
    firstReceivedAt: Date,
    lastReceivedAt: Date,
    kind: WeatherPartsKind,
    now: Date
  ) -> WeatherRequest? {
    guard !missingIndexes.isEmpty else { return nil }
    guard now.timeIntervalSince(lastReceivedAt) >= settleSeconds else { return nil }
    guard now.timeIntervalSince(firstReceivedAt) <= window else { return nil }
    let indexes = fitting(group: group, indexes: missingIndexes, kind: kind)
    guard !indexes.isEmpty else { return nil }
    return .parts(group: group, indexes: indexes, of: kind)
  }

  /// As many of the missing indexes as fit in a forty-byte request text
  /// (``MeshWXWire/maxRequestTextBytes``), lowest first.
  ///
  /// Both kinds of answer cap at eight packets, so in practice every index is one digit and all
  /// of them always fit. It is trimmed rather than assumed because `total` is a byte off the
  /// wire: a bot with a bug that sent `total = 200` would otherwise build a request the radio
  /// refuses, and losing the last two of ten holes is better than losing the ask.
  static func fitting(group: UInt8, indexes: [UInt8], kind: WeatherPartsKind) -> [UInt8] {
    let sorted = indexes.sorted()
    var fits: [UInt8] = []
    for index in sorted {
      let candidate = fits + [index]
      let text = WeatherRequest.parts(group: group, indexes: candidate, of: kind).wireText
      guard text.utf8.count <= MeshWXWire.maxRequestTextBytes else { break }
      fits = candidate
    }
    return fits
  }
}
