import Foundation
@testable import MC1Services
import MeshCore
import Testing

@Suite("NotifPrefsBlob")
struct NotifPrefsBlobTests {
  // MARK: - Mode mapping (iOS NotificationLevel -> firmware FirmwareNotifMode)

  @Test
  func `iOS notification levels map onto the firmware wire modes`() {
    #expect(NotifPrefsBlob.firmwareMode(from: .muted) == .silent)
    #expect(NotifPrefsBlob.firmwareMode(from: .mentionsOnly) == .mentions)
    #expect(NotifPrefsBlob.firmwareMode(from: .all) == .all)
  }

  @Test
  func `FirmwareNotifMode raw values are frozen to the firmware wire bytes`() {
    #expect(FirmwareNotifMode.silent.rawValue == 0)
    #expect(FirmwareNotifMode.all.rawValue == 1)
    #expect(FirmwareNotifMode.mentions.rawValue == 2)
    #expect(FirmwareNotifMode.urgent.rawValue == 3)
  }

  // MARK: - Encoding wire layout

  @Test
  func `Empty blob encodes to 4 bytes: version, global_mode, 0, 0`() {
    let blob = NotifPrefsBlob(globalMode: .all)
    let data = blob.encode()
    #expect(data.count == 4)
    #expect(data[0] == 1) // version
    #expect(data[1] == FirmwareNotifMode.all.rawValue)
    #expect(data[2] == 0) // num_channel_rules
    #expect(data[3] == 0) // num_contact_rules
  }

  @Test
  func `Channel rules encode as channel_idx and mode pairs after the count byte`() {
    let blob = NotifPrefsBlob(
      globalMode: .all,
      channelRules: [
        .init(channelIdx: 3, mode: .mentions),
        .init(channelIdx: 5, mode: .silent)
      ]
    )
    let data = blob.encode()
    // [ver=1][global=1][nch=2][3, mentions][5, silent][nrt=0]
    #expect(data.count == 4 + 2 * 2)
    #expect(data[2] == 2)
    #expect(data[3] == 3)
    #expect(data[4] == FirmwareNotifMode.mentions.rawValue)
    #expect(data[5] == 5)
    #expect(data[6] == FirmwareNotifMode.silent.rawValue)
    #expect(data[7] == 0) // num_contact_rules
  }

  @Test
  func `Contact rules encode a 6-byte pubkey prefix followed by the mode`() {
    let prefix = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x12, 0x34])
    let blob = NotifPrefsBlob(
      globalMode: .all,
      contactRules: [.init(pubKeyPrefix: prefix, mode: .silent)]
    )
    let data = blob.encode()
    // [ver=1][global=1][nch=0][nrt=1][DE AD BE EF 12 34][silent]
    #expect(data.count == 4 + 7)
    #expect(data[3] == 1)
    #expect(data.subdata(in: 4..<10) == prefix)
    #expect(data[10] == FirmwareNotifMode.silent.rawValue)
  }

  @Test
  func `A short pubkey prefix is zero-padded to 6 bytes on encode`() {
    let blob = NotifPrefsBlob(
      globalMode: .all,
      contactRules: [.init(pubKeyPrefix: Data([0xAB, 0xCD]), mode: .silent)]
    )
    let data = blob.encode()
    #expect(Array(data.subdata(in: 4..<10)) == [0xAB, 0xCD, 0x00, 0x00, 0x00, 0x00])
  }

  @Test
  func `A long pubkey prefix is truncated to 6 bytes on encode`() {
    let blob = NotifPrefsBlob(
      globalMode: .all,
      contactRules: [.init(pubKeyPrefix: Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]), mode: .silent)]
    )
    let data = blob.encode()
    #expect(Array(data.subdata(in: 4..<10)) == [1, 2, 3, 4, 5, 6])
  }

  @Test
  func `Rule lists above the firmware caps are dropped during encode`() {
    let manyChannels = (0..<32).map { NotifPrefsBlob.ChannelRule(channelIdx: UInt8($0), mode: .silent) }
    #expect(NotifPrefsBlob(globalMode: .all, channelRules: manyChannels).encode()[2] == UInt8(NotifPrefsBlob.maxChannelRules))

    let manyContacts = (0..<32).map { i in
      NotifPrefsBlob.ContactRule(pubKeyPrefix: Data([UInt8(i), 0, 0, 0, 0, 0]), mode: .silent)
    }
    #expect(NotifPrefsBlob(globalMode: .all, contactRules: manyContacts).encode()[3] == UInt8(NotifPrefsBlob.maxContactRules))
  }

  // MARK: - Round-trip

  @Test
  func `encode then decode round-trips every field`() throws {
    let original = NotifPrefsBlob(
      globalMode: .mentions,
      channelRules: [
        .init(channelIdx: 1, mode: .silent),
        .init(channelIdx: 2, mode: .mentions),
        .init(channelIdx: 7, mode: .all)
      ],
      contactRules: [
        .init(pubKeyPrefix: Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]), mode: .silent),
        .init(pubKeyPrefix: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06]), mode: .all)
      ]
    )
    let decoded = try #require(NotifPrefsBlob(decoding: original.encode()))

    #expect(decoded.version == 1)
    #expect(decoded.globalMode == original.globalMode)
    #expect(decoded.channelRules == original.channelRules)
    #expect(decoded.contactRules == original.contactRules)
  }

  @Test
  func `Decoding an empty blob produces all-defaults`() throws {
    let data = Data([1, FirmwareNotifMode.all.rawValue, 0, 0])
    let decoded = try #require(NotifPrefsBlob(decoding: data))
    #expect(decoded.globalMode == .all)
    #expect(decoded.channelRules.isEmpty)
    #expect(decoded.contactRules.isEmpty)
  }

  // MARK: - Malformed input

  @Test
  func `Decoding rejects payloads with too few bytes for the header`() {
    #expect(NotifPrefsBlob(decoding: Data()) == nil)
    #expect(NotifPrefsBlob(decoding: Data([1])) == nil)
  }

  @Test
  func `Decoding stops gracefully on truncated channel-rule entries`() throws {
    // [ver=1][global=all][nch=2][idx=3, mode=silent][idx=5 ... truncated]
    let data = Data([1, FirmwareNotifMode.all.rawValue, 2, 3, FirmwareNotifMode.silent.rawValue, 5])
    let decoded = try #require(NotifPrefsBlob(decoding: data))
    #expect(decoded.channelRules.count == 1)
    #expect(decoded.channelRules[0].channelIdx == 3)
    #expect(decoded.channelRules[0].mode == .silent)
  }

  @Test
  func `Decoding stops gracefully on truncated contact-rule entries`() throws {
    // [ver=1][global=all][nch=0][nrt=2][pub_key(6) + mode(1) = 1 valid entry][partial second]
    var data = Data([1, FirmwareNotifMode.all.rawValue, 0, 2])
    data.append(Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]))
    data.append(FirmwareNotifMode.silent.rawValue)
    data.append(Data([0x11, 0x22])) // truncated second entry (missing 4 bytes + mode)
    let decoded = try #require(NotifPrefsBlob(decoding: data))
    #expect(decoded.contactRules.count == 1)
    #expect(decoded.contactRules[0].pubKeyPrefix == Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]))
  }

  @Test
  func `Decoding tolerates an unknown rule mode by dropping just that entry`() throws {
    // version, global=all, nch=2, [3, valid=mentions], [4, invalid=99], nrt=0
    let data = Data([
      1, FirmwareNotifMode.all.rawValue, 2,
      3, FirmwareNotifMode.mentions.rawValue,
      4, 99,
      0
    ])
    let decoded = try #require(NotifPrefsBlob(decoding: data))
    // Invalid entry is silently skipped (encoder/firmware never produces it)
    #expect(decoded.channelRules.count == 1)
    #expect(decoded.channelRules[0].channelIdx == 3)
  }

  @Test
  func `Decoding rejects an unknown global mode`() {
    #expect(NotifPrefsBlob(decoding: Data([1, 99, 0, 0])) == nil)
  }

  @Test
  func `Decoding rejects a schema version this build cannot read`() {
    let current = NotifPrefsBlob.currentVersion
    #expect(NotifPrefsBlob(decoding: Data([current, FirmwareNotifMode.all.rawValue, 0, 0])) != nil)
    // A v2 layout parsed as v1 would misreport which conversations the radio mutes.
    #expect(NotifPrefsBlob(decoding: Data([current + 1, FirmwareNotifMode.all.rawValue, 0, 0])) == nil)
  }

  // MARK: - Equatable

  @Test
  func `Equal blobs compare equal and differing global modes compare unequal`() {
    let a = NotifPrefsBlob(
      globalMode: .all,
      channelRules: [.init(channelIdx: 1, mode: .silent)],
      contactRules: [.init(pubKeyPrefix: Data([1, 2, 3, 4, 5, 6]), mode: .silent)]
    )
    let b = NotifPrefsBlob(
      globalMode: .all,
      channelRules: [.init(channelIdx: 1, mode: .silent)],
      contactRules: [.init(pubKeyPrefix: Data([1, 2, 3, 4, 5, 6]), mode: .silent)]
    )
    #expect(a == b)
    #expect(NotifPrefsBlob(globalMode: .all) != NotifPrefsBlob(globalMode: .mentions))
  }
}
