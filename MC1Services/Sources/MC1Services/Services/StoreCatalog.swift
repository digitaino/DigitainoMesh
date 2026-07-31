import Foundation

/// Single source of truth for every in-app-purchase product identifier.
/// Adding a new theme, bundle, or tip means adding a constant here.
///
/// IDs are namespaced under this app's own bundle identifier. App Store Connect product IDs
/// are globally unique, so an ID under another app's namespace cannot be registered by this
/// record and every product would fail to load — the store screen shows nothing at all.
public enum StoreCatalog {
  public enum Theme {
    public static let ember = "com.digitaino.PocketMesh.theme.ember"
    public static let fern = "com.digitaino.PocketMesh.theme.fern"
    public static let marine = "com.digitaino.PocketMesh.theme.marine"
    public static let olive = "com.digitaino.PocketMesh.theme.olive"
    public static let lavender = "com.digitaino.PocketMesh.theme.lavender"
    public static let sakura = "com.digitaino.PocketMesh.theme.sakura"
    public static let solarized = "com.digitaino.PocketMesh.theme.solarized"
    public static let nord = "com.digitaino.PocketMesh.theme.nord"
    public static let catppuccin = "com.digitaino.PocketMesh.theme.catppuccin"
    public static let bundleAll = "com.digitaino.PocketMesh.theme.bundle.all"

    /// Every theme the `bundleAll` purchase unlocks. Themes are not sold individually — the
    /// bundle is the only theme purchase — so this set is purely the bundle's entitlement
    /// expansion and the per-theme ownership keys used to render locked/owned state.
    public static let bundledThemeIDs: Set<String> =
      [ember, fern, marine, olive, lavender, sakura, solarized, nord, catppuccin]
  }

  public enum Tip {
    public static let coffee = "com.digitaino.PocketMesh.tips.coffee"
    public static let lunch = "com.digitaino.PocketMesh.tips.lunch"
    public static let dinner = "com.digitaino.PocketMesh.tips.dinner"
    public static let generous = "com.digitaino.PocketMesh.tips.generous"
    public static let massive = "com.digitaino.PocketMesh.tips.massive"
    public static let epic = "com.digitaino.PocketMesh.tips.epic"

    public static let all: Set<String> = [coffee, lunch, dinner, generous, massive, epic]
  }

  /// The product IDs the app fetches from the App Store and sells: the All Themes bundle and the
  /// tips. Individual themes are not sold, so they are never requested from StoreKit — the bundle
  /// purchase confers them as entitlements via `Theme.bundledThemeIDs`.
  public static let sellableProductIDs: Set<String> =
    Tip.all.union([Theme.bundleAll])
}
