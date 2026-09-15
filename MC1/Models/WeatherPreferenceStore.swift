import Foundation

/// Phone-local choices for the Weather tool. Device-local on purpose: which bot to listen to
/// is a fact about where the phone is, not about a radio, and not worth a backup row.
struct WeatherPreferenceStore {
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// The wire id of the bot the user picked, or nil to choose automatically.
  ///
  /// The id rather than the public key, because a bot can be heard on `#meshwx` for hours
  /// before the radio collects its advert: the id is the only name that message carries, and
  /// a pick the user made while the bot was heard-only has to survive the advert arriving.
  var selectedBotID: UInt16? {
    get {
      guard let stored = defaults.object(forKey: Self.selectedBotKey) as? Int else { return nil }
      return UInt16(exactly: stored)
    }
    nonmutating set {
      if let newValue {
        defaults.set(Int(newValue), forKey: Self.selectedBotKey)
      } else {
        defaults.removeObject(forKey: Self.selectedBotKey)
      }
    }
  }

  private static let selectedBotKey = "weather.selectedBotID"
}
