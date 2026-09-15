import Foundation

/// The `#meshwx` hashtag channel the weather bot broadcasts on (spec §1.1).
///
/// A hashtag channel's key derives from its name — `SHA256("#meshwx")[0..<16]`, the same
/// derivation `JoinHashtagChannelView` performs — so there is no secret to distribute and
/// the app can offer to add the channel itself. Whether it does is the user's call
/// (docs/MESHWX.md: prompted, never silent).
public enum WeatherChannel {
  /// The channel name, including the hash. Case matters: the key is derived from these
  /// exact bytes, so `#MeshWX` would be a different channel with a different key.
  public static let name = "#meshwx"

  /// The 16-byte channel secret.
  public static var secret: Data { ChannelService.hashSecret(name) }

  /// The slot already carrying `#meshwx`, if any.
  ///
  /// By secret first: the secret is what decrypts the channel, so a slot holding it *is*
  /// `#meshwx` whatever it was named when it was added (another app, a typed variant). The name
  /// is the fallback for a table whose secret column has not synced.
  public static func existingSlot(in channels: [ChannelDTO]) -> UInt8? {
    let secret = secret
    return channels.first { $0.secret == secret }?.index ?? channels.first { $0.name == name }?.index
  }

  /// The first unused slot above 0 (slot 0 is the public channel), or nil when the radio is
  /// full or reports fewer than two slots.
  public static func freeSlot(in channels: [ChannelDTO], maxChannels: UInt8) -> UInt8? {
    guard maxChannels > 1 else { return nil }
    let used = Set(channels.map(\.index))
    return (UInt8(1)..<maxChannels).first { !used.contains($0) }
  }
}
