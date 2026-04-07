import MC1Services
import SwiftUI
import UIKit

extension SNRQuality {
    /// SwiftUI color for signal quality indicators.
    var color: Color {
        switch self {
        case .excellent, .good: .green
        case .fair: .yellow
        case .poor, .veryPoor: .red
        case .unknown: .secondary
        }
    }

    /// UIKit color for MapKit renderers.
    var uiColor: UIColor {
        switch self {
        case .excellent: .systemGreen
        case .good: .systemYellow
        case .fair: .systemOrange
        case .poor: .systemRed
        case .veryPoor: UIColor(red: 0.600, green: 0.106, blue: 0.106, alpha: 1)
        case .unknown: .systemGray
        }
    }

    /// Localized display label for signal quality.
    var localizedLabel: String {
        switch self {
        case .excellent: L10n.Chats.Chats.Signal.excellent
        case .good: L10n.Chats.Chats.Signal.good
        case .fair: L10n.Chats.Chats.Signal.fair
        case .poor: L10n.Chats.Chats.Signal.poor
        case .veryPoor: L10n.Chats.Chats.Signal.veryPoor
        case .unknown: L10n.Chats.Chats.Path.Hop.signalUnknown
        }
    }
}
