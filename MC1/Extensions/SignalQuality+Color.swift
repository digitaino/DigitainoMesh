import SurveyKit
import SwiftUI
import UIKit

/// Colours and words for SurveyKit's quality scale — the one the signal mapper, the server
/// and the web map all grade cells on.
///
/// Deliberately separate from ``SNRQuality``'s palette next door: that scale is the app's
/// five-step reading of a *single* packet's SNR, this one is the six-step scale a whole
/// cell's mean is bucketed into (`veryPoor` is the step it adds). Their colours agree where
/// the scales agree, so a green hex and a green signal bar still mean the same thing.
extension SignalQuality {
  /// Best first, unknown last, so the legend and the overlay stack read the same way.
  static let coverageOrder: [SignalQuality] = [.excellent, .good, .fair, .poor, .veryPoor, .unknown]

  /// Stable, identifier-safe token for the overlay id this quality's cells live under.
  var overlayToken: String {
    rawValue
  }

  var color: Color {
    switch self {
    case .excellent: .green
    case .good: .mint
    case .fair: .yellow
    case .poor: .orange
    case .veryPoor: .red
    case .unknown: .secondary
    }
  }

  var uiColor: UIColor {
    switch self {
    case .excellent: .systemGreen
    case .good: .systemMint
    case .fair: .systemYellow
    case .poor: .systemOrange
    case .veryPoor: .systemRed
    case .unknown: .systemGray
    }
  }

  var localizedLabel: String {
    switch self {
    case .excellent: L10n.Chats.Chats.Signal.excellent
    case .good: L10n.Chats.Chats.Signal.good
    case .fair: L10n.Chats.Chats.Signal.fair
    case .poor: L10n.Chats.Chats.Signal.poor
    case .veryPoor: L10n.Tools.Tools.SignalMapper.Quality.veryPoor
    case .unknown: L10n.Chats.Chats.Path.Hop.signalUnknown
    }
  }
}
