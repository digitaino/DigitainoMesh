import CryptoKit
import Foundation

/// Route type extracted from header byte bits 0-1.
/// All 4 possible 2-bit values are valid (cannot be unknown).
public enum RouteType: UInt8, Sendable, Codable, CaseIterable {
  case tcFlood = 0
  case flood = 1
  case direct = 2
  case tcDirect = 3

  /// Whether this route type includes a 4-byte transport code.
  public var hasTransportCode: Bool {
    self == .tcFlood || self == .tcDirect
  }

  /// Whether the packet was flood-routed, accumulating each relay's hash into its path.
  /// Direct-routed packets carry the remaining route instead, so their path length is not
  /// a count of hops traversed.
  public var isFlood: Bool {
    self == .flood || self == .tcFlood
  }

  /// Human-readable display name.
  public var displayName: String {
    switch self {
    case .tcFlood: "TC_FLOOD"
    case .flood: "FLOOD"
    case .direct: "DIRECT"
    case .tcDirect: "TC_DIRECT"
    }
  }
}

/// Payload type extracted from header byte bits 2-5.
/// Values 0-11 are defined; 12-15 map to .unknown.
public enum PayloadType: UInt8, Sendable, CaseIterable {
  case request = 0
  case response = 1
  case textMessage = 2
  case ack = 3
  case advert = 4
  case groupText = 5
  case groupData = 6
  case anonRequest = 7
  case path = 8
  case trace = 9
  case multipart = 10
  case control = 11
  case rawCustom = 15
  case unknown = 255

  /// Initialize from raw 4-bit value (0-15). Values 12-14 (reserved) return .unknown; 15 returns .rawCustom.
  public init(fromBits bits: UInt8) {
    self = PayloadType(rawValue: bits) ?? .unknown
  }

  /// Human-readable display name.
  public var displayName: String {
    switch self {
    case .request: "REQUEST"
    case .response: "RESPONSE"
    case .textMessage: "TEXT_MSG"
    case .ack: "ACK"
    case .advert: "ADVERT"
    case .groupText: "GROUP_TEXT"
    case .groupData: "GROUP_DATA"
    case .anonRequest: "ANON_REQ"
    case .path: "PATH"
    case .trace: "TRACE"
    case .multipart: "MULTIPART"
    case .control: "CONTROL"
    case .rawCustom: "RAW_CUSTOM"
    case .unknown: "UNKNOWN"
    }
  }
}

/// Parsed RF packet data from rxLogData events.
public struct ParsedRxLogData: Sendable, Equatable {
  // Always available (raw)
  public let snr: Double?
  public let rssi: Int?
  public let rawPayload: Data

  // Always available (parsed)
  public let routeType: RouteType
  public let payloadType: PayloadType
  public let payloadVersion: UInt8

  /// Raw 4-bit payload-type bits from the header, before mapping to `PayloadType`.
  /// Required by `TransportCodeRegionResolver`, which must hash the wire-format
  /// nibble (firmware bits 12-14 currently map to `PayloadType.unknown = 255`,
  /// which would corrupt the HMAC input).
  public let payloadTypeBits: UInt8

  /// Conditional on route type
  public let transportCode: Data?

  // Path information (empty if malformed)
  public let pathLength: UInt8
  public let pathNodes: [UInt8]

  /// Message payload (after header/path extraction)
  public let packetPayload: Data

  /// 1-byte sender pubkey hash for direct messages (nil for channel/other types).
  public let senderPubkeyPrefix: Data?

  /// 1-byte recipient pubkey hash for direct messages (nil for channel/other types).
  public let recipientPubkeyPrefix: Data?

  /// Correlation hash for "heard repeats" detection. Local-only — see
  /// ``computePacketHash(from:)`` for why it differs from ``contentHash``.
  public let packetHash: String

  /// Firmware-compatible content hash — the packet's mesh-wide identity.
  /// See ``computeContentHash(payloadTypeBits:rawPathLengthByte:packetPayload:)``.
  public let contentHash: String

  public init(
    snr: Double?,
    rssi: Int?,
    rawPayload: Data,
    routeType: RouteType,
    payloadType: PayloadType,
    payloadVersion: UInt8,
    payloadTypeBits: UInt8,
    transportCode: Data?,
    pathLength: UInt8,
    pathNodes: [UInt8],
    packetPayload: Data,
    senderPubkeyPrefix: Data? = nil,
    recipientPubkeyPrefix: Data? = nil
  ) {
    self.snr = snr
    self.rssi = rssi
    self.rawPayload = rawPayload
    self.routeType = routeType
    self.payloadType = payloadType
    self.payloadVersion = payloadVersion
    self.payloadTypeBits = payloadTypeBits
    self.transportCode = transportCode
    self.pathLength = pathLength
    self.pathNodes = pathNodes
    self.packetPayload = packetPayload
    self.senderPubkeyPrefix = senderPubkeyPrefix
    self.recipientPubkeyPrefix = recipientPubkeyPrefix
    packetHash = Self.computePacketHash(from: packetPayload)
    contentHash = Self.computeContentHash(
      payloadTypeBits: payloadTypeBits,
      rawPathLengthByte: pathLength,
      packetPayload: packetPayload
    )
  }

  /// Compute SHA256 hash of packetPayload, return first 8 bytes as hex.
  ///
  /// Local-only correlation key. It deliberately omits the payload-type nibble, so it
  /// does NOT match the firmware's own packet hash — use ``contentHash`` for anything
  /// that must agree with another node's or an observer's view of the same packet.
  public static func computePacketHash(from packetPayload: Data) -> String {
    let hash = SHA256.hash(data: packetPayload)
    return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  /// Compute the firmware's content hash for a packet: SHA256 over the payload-type
  /// nibble followed by the packet payload (header and path excluded), truncated to
  /// 8 bytes of lowercase hex.
  ///
  /// This is the mesh-wide identity of a transmission: every node and observer that
  /// hears the packet — through any path — derives the same value, because the
  /// route-mutable bytes (route bits, version bits, transport code, path) are all
  /// excluded. It is the key CoreScope observers group observations under.
  ///
  /// TRACE packets fold in the raw path-length byte as a little-endian UInt16,
  /// matching firmware — their path bytes are per-hop SNR readings that mutate at
  /// every hop, so the firmware pins the *length* instead.
  ///
  /// - Parameters:
  ///   - payloadTypeBits: raw 4-bit payload-type nibble from the header (bits 2-5),
  ///     NOT the mapped ``PayloadType`` raw value (bits 12-14 map to `.unknown` = 255,
  ///     which would corrupt the hash input).
  ///   - rawPathLengthByte: the undecoded path-length byte (hash-size bits included).
  ///     Only read for TRACE packets.
  ///   - packetPayload: payload after header/transport-code/path extraction.
  public static func computeContentHash(
    payloadTypeBits: UInt8,
    rawPathLengthByte: UInt8,
    packetPayload: Data
  ) -> String {
    var input = Data([payloadTypeBits])
    if payloadTypeBits == PayloadType.trace.rawValue {
      input.append(contentsOf: [rawPathLengthByte, 0x00])
    }
    input.append(packetPayload)
    let hash = SHA256.hash(data: input)
    return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
  }
}
