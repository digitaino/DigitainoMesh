import AVFoundation
import Foundation
import OSLog

/// The alert tones the watch screen can play when the watched repeater is heard.
///
/// Range-testing is done with the phone in a pocket while walking a boundary, so the useful
/// feedback is audible, not visual. These are the system UI sounds — short, already on every
/// device, and distinct enough from each other to pick one that carries over wind.
enum RepeaterWatchTone: String, CaseIterable, Identifiable {
  case note = "sms-received3"
  case chime = "sms-received1"
  case bell = "sms-received5"
  case tweet = "tweet_sent"
  case tink = "Tink"
  case tock = "Tock"

  var id: String {
    rawValue
  }

  var localizedName: String {
    switch self {
    case .note: L10n.Localizable.SignalBars.Watch.Tones.note
    case .chime: L10n.Localizable.SignalBars.Watch.Tones.chime
    case .bell: L10n.Localizable.SignalBars.Watch.Tones.bell
    case .tweet: L10n.Localizable.SignalBars.Watch.Tones.tweet
    case .tink: L10n.Localizable.SignalBars.Watch.Tones.tink
    case .tock: L10n.Localizable.SignalBars.Watch.Tones.tock
    }
  }

  var fileURL: URL {
    URL(fileURLWithPath: "/System/Library/Audio/UISounds/\(rawValue).caf")
  }

  static func named(_ id: String) -> RepeaterWatchTone {
    RepeaterWatchTone(rawValue: id) ?? .note
  }
}

/// Plays the watch alert tone.
///
/// Deliberately in the app target: `MC1Services` has no business importing AVFoundation, and
/// the engine already publishes everything needed to drive this — a rising `heardCount` on
/// the watched repeater — so audio is a view concern reacting to state rather than a
/// callback the service layer has to know about.
///
/// The session is `.playback` with `.mixWithOthers`, which is what makes the tone audible
/// through AirPods with the phone on silent and without stopping the user's music. That
/// combination is the whole point: a range test is useless if the alert is muted by the
/// hardware switch.
@MainActor
final class RepeaterWatchTonePlayer {
  private static let logger = Logger(subsystem: "com.mc1", category: "RepeaterWatch")

  /// Retained so playback is not cut short by deallocation.
  private var player: AVAudioPlayer?

  func play(_ tone: RepeaterWatchTone) {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, options: .mixWithOthers)
      try session.setActive(true)
      let player = try AVAudioPlayer(contentsOf: tone.fileURL)
      player.volume = 0.8
      player.play()
      self.player = player
    } catch {
      // A missing system sound or a session the OS refuses is not worth interrupting a
      // range test over; the visual flash still fires.
      Self.logger.debug("Watch tone playback failed: \(error.localizedDescription)")
    }
  }
}

/// Where the watch screen's audio preferences live.
///
/// Kept out of the shared `AppStorageKey` enum on purpose: these are properties of the phone
/// doing the walking (which earpiece, which tone carries over the wind here), not of the
/// account, so they are intentionally device-local and excluded from backup/restore.
enum RepeaterWatchPreferenceKey {
  static let soundEnabled = "repeaterWatchSoundEnabled"
  static let toneID = "repeaterWatchToneID"
}
