import Foundation

/// An identity's settings and channel layout as the last radio that agreed with this phone
/// held them, slot by slot.
///
/// Captured when a ``SwapGuard`` is armed, because the connect that arms it rebuilds the
/// Device row from the new radio's `SelfInfo`, and the first guarded channel sync relabels any
/// slot where the new radio holds a different channel. Without the capture, "Copy to This
/// Radio" would copy the new radio back onto itself. Channel history is keyed by slot, so the
/// layout is what decides which chat a channel's messages land in. docs/RADIO_SWAP.md, R3/R4.
public struct IdentityProfile: Codable, Sendable, Equatable {
  public struct Channel: Codable, Sendable, Equatable {
    public var slot: UInt8
    public var name: String
    public var secret: Data

    public init(slot: UInt8, name: String, secret: Data) {
      self.slot = slot
      self.name = name
      self.secret = secret
    }
  }

  public var nodeName: String
  public var radio: MeshCoreNodeConfig.RadioSettings
  public var latitude: Double
  public var longitude: Double
  public var other: MeshCoreNodeConfig.OtherSettings
  public var channels: [Channel]
  public var capturedAt: Date

  public init(
    nodeName: String,
    radio: MeshCoreNodeConfig.RadioSettings,
    latitude: Double,
    longitude: Double,
    other: MeshCoreNodeConfig.OtherSettings,
    channels: [Channel],
    capturedAt: Date
  ) {
    self.nodeName = nodeName
    self.radio = radio
    self.latitude = latitude
    self.longitude = longitude
    self.other = other
    self.channels = channels
    self.capturedAt = capturedAt
  }

  /// The identity as a Device row and its channel rows describe it. Unconfigured rows
  /// (empty name, zero secret) are left out.
  public static func capture(device: DeviceDTO, channels: [ChannelDTO], at date: Date = Date()) -> IdentityProfile {
    IdentityProfile(
      nodeName: device.nodeName,
      radio: MeshCoreNodeConfig.RadioSettings(
        frequency: device.frequency,
        bandwidth: device.bandwidth,
        spreadingFactor: device.spreadingFactor,
        codingRate: device.codingRate,
        txPower: device.txPower
      ),
      latitude: device.latitude,
      longitude: device.longitude,
      other: MeshCoreNodeConfig.OtherSettings(
        manualAddContacts: device.manualAddContacts ? 1 : 0,
        advertLocationPolicy: device.advertLocationPolicy,
        telemetryModeBase: device.telemetryModeBase,
        telemetryModeLocation: device.telemetryModeLoc,
        telemetryModeEnvironment: device.telemetryModeEnv,
        multiAcks: device.multiAcks
      ),
      channels: channels
        .filter { ChannelService.isChannelConfigured(name: $0.name, secret: $0.secret) }
        .sorted { $0.index < $1.index }
        .map { Channel(slot: $0.index, name: $0.name, secret: $0.secret) },
      capturedAt: date
    )
  }

  /// Profile channels a radio with `maxChannels` slots does not hold at their own slot,
  /// judged against the radio's configured slots.
  public func channelsOutOfPlace(configured: [(index: UInt8, secret: Data)], maxChannels: UInt8) -> [Channel] {
    channels.filter { channel in
      channel.slot < maxChannels
        && !configured.contains { $0.index == channel.slot && $0.secret == channel.secret }
    }
  }
}
