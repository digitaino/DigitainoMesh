import SwiftUI
import TipKit

/// Tip shown in the Weather tab to explain the long-press gesture on weather product cards.
/// Displays once the first time the user sees weather data.
struct WXLongPressTip: Tip {

    var title: Text {
        Text("Request More Details")
    }

    var message: Text? {
        Text("Long press any weather card to request forecasts, TAFs, METARs, outlooks, storm reports, and more from the weather bot.")
    }

    var image: Image? {
        Image(systemName: "hand.tap")
    }

    var options: [TipOption] {
        [Tips.MaxDisplayCount(1)]
    }
}
