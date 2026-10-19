import CryptoKit
import Foundation
@testable import MC1Services
import Testing

@Suite("WeatherChannel")
struct WeatherChannelTests {
  private func channel(index: UInt8, name: String) -> ChannelDTO {
    ChannelDTO(
      id: UUID(),
      radioID: UUID(),
      index: index,
      name: name,
      secret: Data(repeating: 0xAB, count: 16),
      isEnabled: true,
      lastMessageDate: nil,
      unreadCount: 0
    )
  }

  /// Spec §1.1: the key derives from the name like any MeshCore hashtag channel —
  /// `sha256("#meshwx")[0..<16]`, hash taken over the name *with* its `#`.
  @Test
  func `the secret is the first sixteen bytes of sha256 over the hashtag name`() {
    let expected = Data(SHA256.hash(data: Data("#meshwx".utf8)).prefix(16))
    #expect(WeatherChannel.secret == expected)
    #expect(WeatherChannel.secret == ChannelService.hashSecret("#meshwx"))
    #expect(WeatherChannel.secret.count == 16)
  }

  @Test
  func `an existing slot is found by exact name only`() {
    let channels = [channel(index: 0, name: "Public"), channel(index: 3, name: "#meshwx")]
    #expect(WeatherChannel.existingSlot(in: channels) == 3)
    // A differently-cased name hashes to a different key and is a different channel.
    #expect(WeatherChannel.existingSlot(in: [channel(index: 2, name: "#MeshWX")]) == nil)
    #expect(WeatherChannel.existingSlot(in: []) == nil)
  }

  /// The secret is what decrypts the channel; a slot holding it is #meshwx whatever it is
  /// called in the app's table.
  @Test
  func `a slot is found by the meshwx secret whatever its name`() {
    let renamed = ChannelDTO(
      id: UUID(), radioID: UUID(), index: 31, name: "Weather", secret: WeatherChannel.secret,
      isEnabled: true, lastMessageDate: nil, unreadCount: 0)
    #expect(WeatherChannel.existingSlot(in: [channel(index: 1, name: "#meshwx-discover"), renamed]) == 31)
  }

  @Test
  func `the free slot skips the public channel and every used index`() {
    let channels = [channel(index: 0, name: "Public"), channel(index: 1, name: "#austin"), channel(index: 3, name: "x")]
    #expect(WeatherChannel.freeSlot(in: channels, maxChannels: 8) == 2)
    #expect(WeatherChannel.freeSlot(in: [], maxChannels: 8) == 1)
  }

  @Test
  func `a full radio or a single-slot radio has no free slot`() {
    let full = (0..<4).map { channel(index: UInt8($0), name: "c\($0)") }
    #expect(WeatherChannel.freeSlot(in: full, maxChannels: 4) == nil)
    #expect(WeatherChannel.freeSlot(in: [], maxChannels: 1) == nil)
    #expect(WeatherChannel.freeSlot(in: [], maxChannels: 0) == nil)
  }
}
