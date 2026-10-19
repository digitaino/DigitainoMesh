import Foundation

/// One page of the Weather tool's pager (docs/MESHWX_UI.md §4).
///
/// The tool is a weather app: one page per place, swiped sideways with dots, and the phone's own
/// location always first. A page is named by what it *is* — the phone's position, or one saved
/// place — so a page keeps its identity while the list is added to, reordered or thinned.
public enum WeatherPage: Sendable, Hashable, Identifiable {
  /// Where the phone is. Always the first page, whether or not a fix has been taken: with no
  /// permission it is the page that offers to ask for one, and nothing asks for it first.
  case myLocation
  case saved(WeatherSavedPlace)

  public static let myLocationID = "here"

  public var id: String {
    switch self {
    case .myLocation: Self.myLocationID
    case let .saved(place): place.id
    }
  }

  public var savedPlace: WeatherSavedPlace? {
    switch self {
    case .myLocation: nil
    case let .saved(place): place
    }
  }

  /// What the page is titled with. My location has no title of its own: its place, once resolved,
  /// carries one.
  public var label: String? {
    savedPlace?.label
  }
}

/// The pages the pager swipes through, in order (docs/MESHWX_UI.md §4).
public enum WeatherPages {
  /// My location first, then the saved places in the order Places holds them. Places is where
  /// the order is decided — adding, removing and dragging — and the pager follows it exactly, so
  /// the dots never mean something different from the list.
  public static func make(saved: [WeatherSavedPlace]) -> [WeatherPage] {
    [.myLocation] + saved.map(WeatherPage.saved)
  }

  /// The page the pager should be showing: the one asked for while it is still there, else the
  /// first. A place removed from Places while its page was open leaves the pager on My location
  /// rather than on an id nothing answers to.
  ///
  /// The caller writes the answer back. Resolving it only where it is read leaves the selection
  /// pointing at a page that is gone, which is a snapshot nothing can be built for and a spinner
  /// that never ends.
  public static func selection(_ id: String, in pages: [WeatherPage]) -> String {
    pages.contains { $0.id == id } ? id : (pages.first?.id ?? WeatherPage.myLocationID)
  }

  /// The page on either side of one, for the two neighbours a pager can be swiped to next.
  public static func neighbours(of id: String, in pages: [WeatherPage]) -> [String] {
    guard let index = pages.firstIndex(where: { $0.id == id }) else { return [] }
    return [index - 1, index + 1].compactMap { pages.indices.contains($0) ? pages[$0].id : nil }
  }

  /// The page a watched place belongs to. The notifier watches places, not pages, and names the
  /// phone's own position `WeatherWatchedPlace.myLocationID`; every other id is a saved place's,
  /// which is its page's (docs/MESHWX_UI.md §16).
  public static func pageID(forWatchedPlaceID id: String) -> String {
    id == WeatherWatchedPlace.myLocationID ? WeatherPage.myLocationID : id
  }
}
