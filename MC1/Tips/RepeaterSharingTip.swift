import SwiftUI
import TipKit

/// Tip shown in Settings to encourage users to enable repeater location sharing.
/// Displays once the first time the user visits the Settings screen.
struct RepeaterSharingTip: Tip {

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
}
