import Foundation
import MeshCore

/// Wire-format notification preferences blob for Digitaino's custom-firmware
/// notification-prefs sync slot.
///
/// The firmware reads this blob to gate on-device beep/vibration alerts on
/// per-channel and per-contact rules, falling back to ``globalMode`` when no
/// rule matches. Mentions are matched case-insensitively against the device's
/// own node name (which lives in firmware `_prefs.node_name`).
public struct NotifPrefsBlob: Sendable, Equatable {
  /// Per-channel override. `channelIdx` matches firmware's `channel_idx`
  /// (the same value as ``Channel/index``).
  public struct ChannelRule: Sendable, Equatable {
    public let channelIdx: UInt8
    public let mode: FirmwareNotifMode

    public init(channelIdx: UInt8, mode: FirmwareNotifMode) {
      self.channelIdx = channelIdx
      self.mode = mode
    }
  }

  /// Per-contact override keyed by the first 6 bytes of the contact's public key.
  /// Matches the firmware's `entry.repeat_path` storage convention.
  public struct ContactRule: Sendable, Equatable {
    /// Exactly 6 bytes on the wire (zero-padded on encode if shorter).
    public let pubKeyPrefix: Data
    public let mode: FirmwareNotifMode

    public init(pubKeyPrefix: Data, mode: FirmwareNotifMode) {
      self.pubKeyPrefix = pubKeyPrefix
      self.mode = mode
    }
  }

  /// The newest schema version this build can read or write.
  public static let currentVersion: UInt8 = 1

  /// Schema version for forward compatibility (currently `1`).
  public var version: UInt8

  /// Default notification mode when no per-channel or per-contact rule matches.
  public var globalMode: FirmwareNotifMode

  /// Per-channel overrides. The firmware keeps at most ``Limits/channelRules`` of them;
  /// producers are expected to apply the cap themselves so a cached blob matches the wire,
  /// and the encoder truncates as a backstop.
  public var channelRules: [ChannelRule]

  /// Per-contact overrides, capped like ``channelRules``.
  public var contactRules: [ContactRule]

  /// How many rules per list a radio keeps, read from the ``SyncID/notifCaps`` slot.
  public struct Limits: Sendable, Equatable {
    public let channelRules: Int
    public let contactRules: Int

    public init(channelRules: Int, contactRules: Int) {
      self.channelRules = channelRules
      self.contactRules = contactRules
    }

    /// What firmware that predates the caps slot keeps. It reads a longer list wrongly,
    /// so nothing past these counts may be sent to it.
    public static let legacy = Limits(channelRules: 16, contactRules: 16)

    /// Parses a ``SyncID/notifCaps`` reply: `[version][max_channel_rules][max_contact_rules]`.
    /// Returns `nil` for an empty reply (firmware without the slot) or one too short to read.
    public init?(decoding data: Data) {
      guard data.count >= 3 else { return nil }
      let start = data.startIndex
      self.init(
        channelRules: Int(data[data.index(start, offsetBy: 1)]),
        contactRules: Int(data[data.index(start, offsetBy: 2)])
      )
    }
  }

  public init(
    version: UInt8 = Self.currentVersion,
    globalMode: FirmwareNotifMode = .all,
    channelRules: [ChannelRule] = [],
    contactRules: [ContactRule] = []
  ) {
    self.version = version
    self.globalMode = globalMode
    self.channelRules = channelRules
    self.contactRules = contactRules
  }

  /// Maps an iOS-level ``NotificationLevel`` to the firmware's wire-level mode.
  ///
  /// iOS  → Firmware
  /// - `.muted`        → `.silent`
  /// - `.mentionsOnly` → `.mentions`
  /// - `.all`          → `.all`
  public static func firmwareMode(from level: NotificationLevel) -> FirmwareNotifMode {
    switch level {
    case .muted: .silent
    case .mentionsOnly: .mentions
    case .all: .all
    }
  }

  // MARK: - Encoding

  /// Serializes this blob to its on-wire format for the notification-prefs sync slot.
  ///
  /// Binary layout (matches firmware `parseNotifPrefs`):
  /// `[version][global_mode][num_channel_rules]([channel_idx][mode]) x N[num_contact_rules]([pub_key_prefix(6)][mode]) x M`
  ///
  /// - Parameter limits: The receiving radio's caps. Rules past them are dropped.
  public func encode(limits: Limits) -> Data {
    var out = Data()
    out.append(version)
    out.append(globalMode.rawValue)

    let channels = Array(channelRules.prefix(min(limits.channelRules, Int(UInt8.max))))
    out.append(UInt8(channels.count))
    for r in channels {
      out.append(r.channelIdx)
      out.append(r.mode.rawValue)
    }

    let contacts = Array(contactRules.prefix(min(limits.contactRules, Int(UInt8.max))))
    out.append(UInt8(contacts.count))
    for r in contacts {
      // Force-write exactly 6 bytes, zero-padding short prefixes.
      var prefix = r.pubKeyPrefix.prefix(6)
      if prefix.count < 6 {
        prefix.append(Data(repeating: 0, count: 6 - prefix.count))
      }
      out.append(prefix)
      out.append(r.mode.rawValue)
    }
    return out
  }

  // MARK: - Decoding

  /// Parses a blob previously fetched from the notification-prefs sync slot.
  ///
  /// Tolerant of partial / truncated payloads: returns `nil` if the version
  /// byte is missing, otherwise reads as much as the bytes allow. A version
  /// beyond ``currentVersion`` also returns `nil` — a newer layout read as v1
  /// would report confident nonsense about which conversations the radio mutes.
  public init?(decoding data: Data) {
    guard data.count >= 2 else { return nil }
    var i = data.startIndex
    let version = data[i]; i = data.index(after: i)
    guard version <= Self.currentVersion else { return nil }
    let globalRaw = data[i]; i = data.index(after: i)
    guard let global = FirmwareNotifMode(rawValue: globalRaw) else { return nil }

    var channels: [ChannelRule] = []
    if i < data.endIndex {
      let n = data[i]; i = data.index(after: i)
      for _ in 0..<n {
        guard data.distance(from: i, to: data.endIndex) >= 2 else { break }
        let idx = data[i]; i = data.index(after: i)
        let modeRaw = data[i]; i = data.index(after: i)
        if let mode = FirmwareNotifMode(rawValue: modeRaw) {
          channels.append(.init(channelIdx: idx, mode: mode))
        }
      }
    }

    var contacts: [ContactRule] = []
    if i < data.endIndex {
      let n = data[i]; i = data.index(after: i)
      for _ in 0..<n {
        guard data.distance(from: i, to: data.endIndex) >= 7 else { break }
        let prefix = data.subdata(in: i..<data.index(i, offsetBy: 6))
        i = data.index(i, offsetBy: 6)
        let modeRaw = data[i]; i = data.index(after: i)
        if let mode = FirmwareNotifMode(rawValue: modeRaw) {
          contacts.append(.init(pubKeyPrefix: prefix, mode: mode))
        }
      }
    }

    self.init(
      version: version,
      globalMode: global,
      channelRules: channels,
      contactRules: contacts
    )
  }
}
