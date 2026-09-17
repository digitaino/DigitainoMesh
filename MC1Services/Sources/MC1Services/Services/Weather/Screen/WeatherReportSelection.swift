import Foundation
import MeshWX

/// Which held text reply a product's screen shows (docs/MESHWX_UI.md §12, §14 Q5).
///
/// A text chunk carries its subject and nothing else, so "the newest forecast discussion" is the
/// newest discussion *anybody* asked for — the office is not in it. Picking by subject alone is
/// how a page for Round Rock came to show the discussion this phone had asked Fort Worth for:
/// same subject, different place, and the header said so while the blurb above it said otherwise.
///
/// So the page's own request decides. A reply this phone asked for is shown only when it answered
/// **this page's** request, argument and all. Anything else is only ever shown as somebody else's:
/// a reply nobody here asked for could be about anywhere, and for a product asked for by area it
/// is labelled as exactly that rather than presented as this place's.
public enum WeatherReportSelection {
  /// The reply a product screen shows, and what can honestly be said about it.
  public struct Choice: Sendable, Hashable {
    public var item: WeatherTextItem
    /// It answered a request of this phone's for what this page asks about.
    public var isOwn: Bool
    /// Nobody here asked for it and the product is asked for by area, so which office or state it
    /// is about is not known — only that the subject matches.
    public var isUnknownArea: Bool

    public init(item: WeatherTextItem, isOwn: Bool, isUnknownArea: Bool) {
      self.item = item
      self.isOwn = isOwn
      self.isUnknownArea = isUnknownArea
    }
  }

  /// - Parameters:
  ///   - request: what this page would ask for — `>afd EWX`, `>storm TX`. Nil when the page has
  ///     no place to build one from, and then only an overheard reply can be shown.
  ///   - isByArea: the product's argument names an office or a state (`WeatherReportProduct`).
  ///     `>hwo` and `>space` take none: they are the bot's products, and an overheard one is the
  ///     same product this page would have asked for.
  public static func choose(
    texts: [WeatherTextItem],
    subject: MeshWXTextSubject,
    request: WeatherRequest?,
    isByArea: Bool
  ) -> Choice? {
    let newestFirst = texts
      .filter { $0.assembly.subject == subject }
      .sorted { $0.assembly.lastReceivedAt > $1.assembly.lastReceivedAt }
    if let request, let own = newestFirst.first(where: { $0.assembly.request == request }) {
      return Choice(item: own, isOwn: true, isUnknownArea: false)
    }
    // An own reply to a *different* argument belongs to another page and is never borrowed:
    // showing Fort Worth's discussion on an Austin page is the bug, not a fallback.
    guard let overheard = newestFirst.first(where: { $0.assembly.request == nil }) else { return nil }
    return Choice(item: overheard, isOwn: false, isUnknownArea: isByArea)
  }
}
