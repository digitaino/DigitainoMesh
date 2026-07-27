import Foundation

/// How well a repeater hears *us* — the TX leg of a link, which can only be learned by
/// transmitting something and reading the SNR the far end reports back.
public enum RepeaterTXState: Sendable, Equatable {
  /// Never probed. The far end has told us nothing about how it hears us.
  case unknown
  /// A probe is in flight.
  case measuring
  /// A probe came back carrying the remote SNR.
  case measured(SNRQuality)
  /// A probe was attempted and produced no usable remote SNR — it timed out, the send
  /// failed, or the reply omitted the remote leg. The firmware draws "X" for this state.
  ///
  /// RX is never substituted for TX here: the two legs differ whenever antennas or power
  /// differ between the ends, and the firmware never fakes one from the other.
  case failed
}

/// One repeater in the signal-bars table, with both legs of its link to this radio.
///
/// The identity is a ``NodeHexID`` rather than a string: the same repeater is advertised
/// at 1-, 2- or 3-byte hash widths depending on the path a packet took, and only
/// ``NodeHexID/identifiesSameNode(as:)`` gets that comparison right.
public struct RepeaterSignal: Sendable, Equatable, Identifiable {
  /// The repeater's hash, at the widest width we have heard it at.
  public var id: NodeHexID
  /// Resolved display name, or `nil` when no contact or discovered node answers to the hash.
  public var name: String?
  /// How well *we* hear *them*, in dB.
  public var rxSnr: Double?
  /// How well *they* hear *us*, in dB. Only meaningful when ``txState`` is `.measured`.
  public var txSnr: Double?
  /// Measurement state of the TX leg.
  public var txState: RepeaterTXState
  /// Received signal strength of the last packet heard from this repeater, in dBm.
  public var rssi: Int?
  /// Round-trip time of the last successful probe, in milliseconds.
  public var rttMs: Int?
  /// When this radio last heard anything from the repeater.
  public var lastHeard: Date
  /// Full public key, when a discover response has supplied one. Probing needs it.
  public var publicKey: Data?
  /// Consecutive failed probes. Drives the retry backoff and eventually stops probing.
  public var failCount: Int
  /// When the last probe was *sent* (not answered).
  public var lastProbeAt: Date?
  /// Whether the device's own table flagged this entry as its best link. Viewer mode only —
  /// the engine computes its own ordering with ``SignalBarsBlob/score(rxSnr:txSnr:)``.
  public var isDeviceBest: Bool

  public init(
    id: NodeHexID,
    name: String? = nil,
    rxSnr: Double? = nil,
    txSnr: Double? = nil,
    txState: RepeaterTXState = .unknown,
    rssi: Int? = nil,
    rttMs: Int? = nil,
    lastHeard: Date,
    publicKey: Data? = nil,
    failCount: Int = 0,
    lastProbeAt: Date? = nil,
    isDeviceBest: Bool = false
  ) {
    self.id = id
    self.name = name
    self.rxSnr = rxSnr
    self.txSnr = txSnr
    self.txState = txState
    self.rssi = rssi
    self.rttMs = rttMs
    self.lastHeard = lastHeard
    self.publicKey = publicKey
    self.failCount = failCount
    self.lastProbeAt = lastProbeAt
    self.isDeviceBest = isDeviceBest
  }

  /// Canonical uppercase hex of ``id``, for display and logging.
  public var hexID: String {
    id.hex
  }

  /// Quality band of the RX leg.
  public var rxQuality: SNRQuality {
    SNRQuality(snr: rxSnr)
  }

  /// Quality band of the TX leg, `.unknown` until a probe measures it.
  public var txQuality: SNRQuality {
    if case let .measured(quality) = txState { return quality }
    return .unknown
  }

  /// Whether a probe is currently in flight for this repeater.
  public var isMeasuring: Bool {
    txState == .measuring
  }

  // MARK: - Ordering

  /// Ordering tier: bidirectional links first, then in-flight measurements, then links
  /// whose TX leg is unknown or broken. Matches the firmware's Signals page grouping.
  var orderingTier: Int {
    switch txState {
    case .measured: 0
    case .measuring: 1
    case .unknown, .failed: 2
    }
  }

  /// The unified best-link score shared with the firmware: `0.6·TX + 0.4·RX` with a
  /// weak-leg guard. Only a *measured* TX leg counts; an unmeasured one scores on RX
  /// alone rather than pretending the link is symmetric.
  var linkScore: Double {
    if case .measured = txState, let txSnr {
      return SignalBarsBlob.score(rxSnr: rxSnr, txSnr: txSnr)
    }
    return SignalBarsBlob.score(rxSnr: rxSnr, txSnr: nil)
  }

  /// Sorts best-link-first: tier, then score.
  static func isOrderedBefore(_ lhs: RepeaterSignal, _ rhs: RepeaterSignal) -> Bool {
    if lhs.orderingTier != rhs.orderingTier { return lhs.orderingTier < rhs.orderingTier }
    return lhs.linkScore > rhs.linkScore
  }
}
