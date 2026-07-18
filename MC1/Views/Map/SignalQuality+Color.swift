import MC1Services
import SurveyKit
import SwiftUI
import UIKit

/// The one SNR palette. Every map overlay and legend derives its signal color
/// from this mapping of the canonical SurveyKit quality scale — do not define
/// per-view palettes.
extension SignalQuality {

    /// UIKit color for MKOverlayRenderer-based drawing.
    var uiColor: UIColor {
        switch self {
        case .excellent: .systemGreen
        case .good: .systemYellow
        case .fair: .systemOrange
        case .poor: .systemRed
        case .veryPoor: UIColor(red: 0.6, green: 0, blue: 0, alpha: 1)
        case .unknown: .systemGray
        }
    }

    /// SwiftUI color for views and legends.
    var color: Color {
        Color(uiColor)
    }
}

extension SNRQuality {

    /// Bridge to the canonical SurveyKit quality scale (same five tiers).
    var signalQuality: SignalQuality {
        switch self {
        case .excellent: .excellent
        case .good: .good
        case .fair: .fair
        case .poor: .poor
        case .veryPoor: .veryPoor
        case .unknown: .unknown
        }
    }
}
