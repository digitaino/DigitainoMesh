import Foundation
import MC1Services

/// Phone-local choices for the Weather tool. Device-local on purpose: which bot to listen to
/// is a fact about where the phone is, not about a radio, and not worth a backup row.
struct WeatherPreferenceStore {
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// The bot the user picked, with where and when (`WeatherBotPick`, phase 2), or nil to choose
  /// automatically.
  ///
  /// By the wire id rather than the public key, because a bot can be heard on `#meshwx` for hours
  /// before the radio collects its advert: the id is the only name that message carries, and a pick
  /// the user made while the bot was heard-only has to survive the advert arriving. The key rides
  /// along when there is one, to tell apart two radios answering to one id. The bare id this
  /// store kept before phase 2 is dropped on first read (`WeatherBotPickStore`): it said nothing
  /// about where it was made, and the choice it stood for is exactly the one that followed a phone
  /// across the state.
  var botPick: WeatherBotPick? {
    get { WeatherBotPickStore(defaults: defaults).pick }
    nonmutating set { WeatherBotPickStore(defaults: defaults).pick = newValue }
  }
}
