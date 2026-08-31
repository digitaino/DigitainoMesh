import Foundation
import MC1Services

/// Whether the in-bubble Translate offer is shown at all.
///
/// The feature arrived from upstream always-on (`1a28e10d`, 2026-08-25). On a mesh whose
/// traffic is routinely multilingual that is a control on a large share of every
/// conversation, which not everyone wants (Rafael, 2026-08-31) — so it gets a switch.
///
/// Read through `UserDefaults` rather than `@AppStorage` because the two places that
/// matter are a bake state and a view model, neither of which is a `View`. Default is
/// **on**, so nobody who likes the feature loses it to an upgrade; `UserDefaults.bool`
/// cannot express that (it returns `false` for an absent key), hence the `object(forKey:)`
/// dance — the same one `DevicePreferenceStore` uses for its opt-out flags.
enum MessageTranslationPreference {
  static var isEnabled: Bool {
    UserDefaults.standard.object(forKey: AppStorageKey.messageTranslationEnabled.rawValue)
      as? Bool ?? AppStorageKey.defaultMessageTranslationEnabled
  }
}
