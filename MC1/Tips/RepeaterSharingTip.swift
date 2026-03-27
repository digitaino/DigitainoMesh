import SwiftUI
import TipKit

/// Tip shown in Settings to encourage users to enable repeater location sharing.
/// Appears once after the app updates to a version with this feature.
struct RepeaterSharingTip: Tip {
    static let appLaunched = Tips.Event(id: "repeaterSharingAppLaunched")

    var title: Text {
        Text("Help Improve the Community Map")
    }

    var message: Text? {
        Text("Share your repeater locations to help build a more accurate and reliable mesh coverage map for everyone.")
    }

    var image: Image? {
        Image(systemName: "antenna.radiowaves.left.and.right.circle")
    }

    var options: [TipOption] {
        [Tips.MaxDisplayCount(1)]
    }

    var rules: [Rule] {
        #Rule(Self.appLaunched) { $0.donations.count >= 1 }
    }
}
