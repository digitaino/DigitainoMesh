import Foundation
import MC1Services

/// The requests this phone has put on the air, kept between visits (docs/MESHWX_UI.md §12).
///
/// Device-local like the bot choice and the saved places (`WeatherPreferenceStore`): what this
/// phone asked for is a fact about this phone, and it belongs to no radio — the answers were
/// broadcast to everyone, and only the asking is this app's to remember. One JSON blob under one
/// defaults key, capped and aged by `WeatherRequestLog`, so it can never become a history; an
/// unreadable blob reads as an empty log and the next request writes a good one.
struct WeatherRequestLogStore {
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var entries: [WeatherRequestLogEntry] {
    get {
      guard let data = defaults.data(forKey: Self.key),
            let decoded = try? JSONDecoder().decode([WeatherRequestLogEntry].self, from: data)
      else { return [] }
      return WeatherRequestLog.ordered(decoded, now: Date())
    }
    nonmutating set {
      guard let data = try? JSONEncoder().encode(WeatherRequestLog.ordered(newValue, now: Date())) else { return }
      defaults.set(data, forKey: Self.key)
    }
  }

  private static let key = "weather.requestLog"
}
