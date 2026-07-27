import Foundation

/// Where the repeater table comes from.
public enum SignalBarsMode: Sendable, Equatable {
  /// Stock firmware: the app runs its own probe engine and builds the table itself.
  case engine
  /// Digitaino custom firmware: the device owns the engine and the app mirrors its table,
  /// so the OLED and the app agree and no duplicate RF traffic is generated. The app still
  /// asks the device to measure things, it just never transmits on its own.
  case viewer
}

/// State of the repeater the user is range-testing.
///
/// Every sighting of the watched repeater bumps ``heardCount``; a UI façade drives its
/// flash and audio cues off that counter rather than off a callback, so nothing about the
/// engine has to know a view exists.
public struct WatchedRepeaterState: Sendable, Equatable {
  /// The hash the user asked to watch — matched against sightings with the bidirectional
  /// prefix rule, so watching `"0C"` also matches the same node heard as `"0C13"`.
  public let id: NodeHexID
  /// How many times the watched repeater has been heard since it was set.
  public var heardCount: Int
  public var lastHeardAt: Date?
  public var rxSnr: Double?
  public var txSnr: Double?

  public init(
    id: NodeHexID,
    heardCount: Int = 0,
    lastHeardAt: Date? = nil,
    rxSnr: Double? = nil,
    txSnr: Double? = nil
  ) {
    self.id = id
    self.heardCount = heardCount
    self.lastHeardAt = lastHeardAt
    self.rxSnr = rxSnr
    self.txSnr = txSnr
  }

  public var rxQuality: SNRQuality {
    SNRQuality(snr: rxSnr)
  }
}

/// Everything the signal-bars UI needs, as one immutable value.
///
/// The engine publishes a fresh snapshot whenever anything observable changes, and skips
/// publishing when nothing did — so a five-second poll that returns an identical device
/// table produces no churn. A SwiftUI façade is then a subscription and an assignment.
public struct SignalBarsSnapshot: Sendable, Equatable {
  /// Whether the table is the device's or the app's own.
  public let mode: SignalBarsMode
  /// The complete table, best link first. Drives scoring and the toolbar indicator.
  public let repeaters: [RepeaterSignal]
  /// The rows to render: ``repeaters`` minus stale and dismissed entries.
  public let displayRepeaters: [RepeaterSignal]
  /// Whether a manual refresh is running.
  public let isRefreshing: Bool
  /// Whether anything is stale enough for "clear stale" to act on.
  public let hasStaleRepeaters: Bool
  public let watched: WatchedRepeaterState?
  /// Bumped on every inbound signal observation — a UI cue for the RX arrow.
  public let rxFlashTick: UInt
  /// Bumped on every transmission the engine causes — a UI cue for the TX arrow.
  public let txFlashTick: UInt

  public init(
    mode: SignalBarsMode,
    repeaters: [RepeaterSignal],
    displayRepeaters: [RepeaterSignal],
    isRefreshing: Bool,
    hasStaleRepeaters: Bool,
    watched: WatchedRepeaterState?,
    rxFlashTick: UInt,
    txFlashTick: UInt
  ) {
    self.mode = mode
    self.repeaters = repeaters
    self.displayRepeaters = displayRepeaters
    self.isRefreshing = isRefreshing
    self.hasStaleRepeaters = hasStaleRepeaters
    self.watched = watched
    self.rxFlashTick = rxFlashTick
    self.txFlashTick = txFlashTick
  }

  /// The best link — what the toolbar indicator shows.
  public var best: RepeaterSignal? {
    repeaters.first
  }

  /// An empty table, for a façade's initial value.
  public static func empty(mode: SignalBarsMode = .engine) -> SignalBarsSnapshot {
    SignalBarsSnapshot(
      mode: mode,
      repeaters: [],
      displayRepeaters: [],
      isRefreshing: false,
      hasStaleRepeaters: false,
      watched: nil,
      rxFlashTick: 0,
      txFlashTick: 0
    )
  }
}
