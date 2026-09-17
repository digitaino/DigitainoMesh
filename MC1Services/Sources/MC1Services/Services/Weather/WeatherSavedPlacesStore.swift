import Foundation

/// The places the user keeps in Places, on this phone (docs/MESHWX_UI.md §5), and which of them
/// have their bell on (§16).
///
/// Device-local like the bot choice (`WeatherPreferenceStore`): which towns someone looks at is a
/// fact about this phone, not about a radio, and not worth a backup row. Stored as JSON under one
/// defaults key, so a field added to `WeatherSavedPlace` needs no migration — an unreadable file
/// reads as an empty list and the next pick writes a good one.
///
/// It lives in the service layer, not beside the screen, because the alert evaluator
/// (`WeatherAlertNotifier`) runs at service lifetime and reads the very same list: a watched place
/// is a saved place with its bell on, and there is one of it.
///
/// `@unchecked Sendable`: the only stored property is a `UserDefaults` reference, which Apple
/// documents as thread-safe.
public struct WeatherSavedPlacesStore: @unchecked Sendable {
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public var places: [WeatherSavedPlace] {
    get {
      guard let data = defaults.data(forKey: Self.key),
            let decoded = try? JSONDecoder().decode([WeatherSavedPlace].self, from: data)
      else { return [] }
      return WeatherSavedPlaces.ordered(decoded)
    }
    nonmutating set {
      guard let data = try? JSONEncoder().encode(WeatherSavedPlaces.ordered(newValue)) else { return }
      defaults.set(data, forKey: Self.key)
    }
  }

  /// The places whose bell is on, newest choice first.
  public var watched: [WeatherSavedPlace] {
    places.filter(\.isWatched)
  }

  /// Applies one edit to the list **as this store holds it**, and returns what it now holds.
  ///
  /// This is the only way the list is written. The rule it enforces is that nothing may persist a
  /// list it did not first load: a screen's copy can be a second old, or empty because the model
  /// was still starting, and writing that copy back silently deletes everything saved since. On a
  /// real phone it deleted four saved places and left the one that had just been picked
  /// (docs/MESHWX_UI.md §3.1 U-1).
  ///
  /// A write that would drop a place nobody asked to drop is refused outright, and the stored
  /// list is returned unchanged. Only ``WeatherSavedPlaces/Edit/remove(id:)`` may take a row out,
  /// and only the ceiling may take one off the end of a list that just grew.
  @discardableResult
  public func apply(_ edit: WeatherSavedPlaces.Edit) -> [WeatherSavedPlace] {
    let loaded = places
    let updated = WeatherSavedPlaces.apply(edit, to: loaded)
    var dropped = WeatherSavedPlaces.dropped(updated, from: loaded)
    if let removed = edit.removedID { dropped.remove(removed) }
    // Adding a thirteenth place pushes the oldest unwatched row off the end, which the ceiling
    // asked for (`WeatherSavedPlaces.ordered`) — nothing else is allowed to shorten the list.
    let ceiling = edit.adds && updated.count >= WeatherSavedPlaces.limit
    guard dropped.isEmpty || ceiling else { return loaded }
    places = updated
    return updated
  }

  private static let key = "weather.savedPlaces"
}
