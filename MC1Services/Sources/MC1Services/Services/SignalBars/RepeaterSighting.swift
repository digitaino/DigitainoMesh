import Foundation
import MeshCore

/// One observation of a repeater, distilled from a device event.
///
/// Both sources of RX data reduce to this: a discover response (which also carries the
/// full public key and the SNR the repeater reported for *us*), and any relayed packet,
/// whose last path hop tells us we can hear that repeater right now.
struct RepeaterSighting: Sendable, Equatable {
  /// The repeater's hash, at whatever width the source supplied.
  var id: NodeHexID
  /// How well we heard them, in dB.
  var rxSnr: Double
  /// How well they heard us, when the source knows. Only discover responses do.
  var txSnr: Double?
  var rssi: Int?
  /// Full public key, when the source carries one. Without it the repeater cannot be probed.
  var publicKey: Data?
}

/// A probe reply, correlated back to the probe that caused it.
struct RepeaterProbeReply: Sendable, Equatable {
  /// The tag the probe was sent with.
  var tag: UInt32
  /// The SNR *we* measured for the reply.
  var localSnr: Double
  /// The SNR the far end recorded for our probe, when the reply carries it.
  var remoteSnr: Double?
}

/// Turns raw device events into signal-bars observations.
///
/// Kept separate from the engine and free of state so every wire rule is a pure function
/// with a byte-level test.
enum SignalBarsObservation {
  /// The events the engine subscribes to.
  static let eventFilter = EventFilter { event in
    switch event {
    case .discoverResponse, .rxLogData: true
    case let .syncValue(id, _): id == .signalBars
    default: false
    }
  }

  /// A discover response: the only source that carries a full public key *and* both legs
  /// of the link, because the responding repeater reports the SNR it measured for us.
  ///
  /// The hash is re-derived from the public key at the device's configured path hash width
  /// (`mode + 1` → 1/2/3 bytes) so the table's IDs match what the rest of the mesh
  /// advertises for the same node.
  static func sighting(
    from response: DiscoverResponse,
    pathHashMode: UInt8
  ) -> RepeaterSighting? {
    guard let id = hashID(forPublicKey: response.publicKey, pathHashMode: pathHashMode) else {
      return nil
    }
    return RepeaterSighting(
      id: id,
      rxSnr: response.snr,
      txSnr: response.snrIn,
      rssi: response.rssi,
      publicKey: response.publicKey
    )
  }

  /// Any relayed packet: the last hop of its path is a repeater we can currently hear.
  ///
  /// Passive sightings carry no public key and no TX leg — they only refresh the RX side
  /// and prove the repeater is alive.
  static func passiveSighting(from log: ParsedRxLogData) -> RepeaterSighting? {
    guard log.payloadType != .trace else { return nil }
    guard let snr = log.snr, let lastHop = log.pathNodes.last else { return nil }

    // Path hops are packed at the hash width the sender used; take a whole hop, not a
    // single byte, so a 2- or 3-byte path yields the wide form of the ID.
    let hashSize = decodePathLen(log.pathLength)?.hashSize ?? 1
    let hopBytes: [UInt8] =
      (1...NodeHexID.maxByteWidth).contains(hashSize) && hashSize <= log.pathNodes.count
        ? Array(log.pathNodes.suffix(hashSize))
        : [lastHop]

    guard let id = NodeHexID(bytes: hopBytes) else { return nil }
    return RepeaterSighting(id: id, rxSnr: snr, rssi: log.rssi)
  }

  /// A trace reply seen in the RX log.
  ///
  /// This view — rather than the parsed `.traceData` event — is what the probe engine
  /// correlates on, because it is the only one that also carries *our* receive SNR for the
  /// reply. Layout: the tag is the first four payload bytes, little-endian, and the last
  /// path byte is the far end's SNR in 0.25 dB steps.
  static func probeReply(from log: ParsedRxLogData) -> RepeaterProbeReply? {
    guard log.payloadType == .trace else { return nil }
    guard log.packetPayload.count >= 4, let snr = log.snr else { return nil }
    return RepeaterProbeReply(
      tag: log.packetPayload.readUInt32LE(at: 0),
      localSnr: snr,
      remoteSnr: log.pathNodes.last.map { Double(Int8(bitPattern: $0)) / 4.0 }
    )
  }

  /// The hash ID a public key is advertised under at the device's path hash mode
  /// (0/1/2 → 1/2/3 bytes), clamped to the widths the firmware can advertise.
  static func hashID(forPublicKey key: Data, pathHashMode: UInt8) -> NodeHexID? {
    guard !key.isEmpty else { return nil }
    let width = min(NodeHexID.maxByteWidth, max(1, Int(pathHashMode) + 1))
    return NodeHexID(data: key.prefix(width))
  }

  /// The leading key bytes a trace probe must be addressed with at this path hash mode.
  static func probePath(forPublicKey key: Data, pathHashMode: UInt8) -> Data {
    Data(key.prefix(min(NodeHexID.maxByteWidth, Int(pathHashMode) + 1)))
  }
}
