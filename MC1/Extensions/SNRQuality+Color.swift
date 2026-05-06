import MC1Services
import SwiftUI
import UIKit

extension SNRQuality {
    /// SwiftUI color for signal quality indicators.
    var color: Color {
        switch self {
        case .excellent: .green
        case .good: .yellow
        case .fair, .poor, .veryPoor: .red
        case .unknown: .secondary
        }
    }

    /// UIKit color matching `color` for use in MKOverlayRenderers and other UIKit contexts.
    var uiColor: UIColor {
        switch self {
        case .excellent: .systemGreen
        case .good: .systemYellow
        case .fair, .poor, .veryPoor: .systemRed
        case .unknown: .systemGray
        }
    }
}
