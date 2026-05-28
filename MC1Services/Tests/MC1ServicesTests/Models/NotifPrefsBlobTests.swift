import Testing
import Foundation
import MeshCore
@testable import MC1Services

@Suite("NotifPrefsBlob")
struct NotifPrefsBlobTests {

    // MARK: - Mode mapping (iOS NotificationLevel <-> firmware FirmwareNotifMode)

    @Test("iOS .muted maps to firmware .silent")
    func mapMutedToSilent() {
        #expect(NotifPrefsBlob.firmwareMode(from: .muted) == .silent)
    }

    @Test("iOS .mentionsOnly maps to firmware .mentions")
    func mapMentionsToMentions() {
        #expect(NotifPrefsBlob.firmwareMode(from: .mentionsOnly) == .mentions)
    }

    @Test("iOS .all maps to firmware .all")
    func mapAllToAll() {
        #expect(NotifPrefsBlob.firmwareMode(from: .all) == .all)
    }

    // MARK: - Encoding wire layout

    @Test("Empty blob encodes to 4 bytes: version, global_mode, 0, 0")
    func encodeEmpty() {
        let blob = NotifPrefsBlob(globalMode: .all)
        let data = blob.encode()
        #expect(data.count == 4)
        #expect(data[0] == 1)   // version
        #expect(data[1] == FirmwareNotifMode.all.rawValue)
        #expect(data[2] == 0)   // num_channel_rules
        #expect(data[3] == 0)   // num_contact_rules
    }

    @Test("Channel rules encode as (channel_idx, mode) pairs after the count byte")
    func encodeChannelRules() {
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
        #expect(data[7] == 0)   // num_contact_rules
    }

    @Test("Contact rules encode 6-byte prefix + mode")
    func encodeContactRules() {
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

    @Test("Short pub_key prefix is zero-padded to 6 bytes on encode")
    func encodePadsShortPubKey() {
        let blob = NotifPrefsBlob(
            globalMode: .all,
            contactRules: [.init(pubKeyPrefix: Data([0xAB, 0xCD]), mode: .silent)]
        )
        let data = blob.encode()
        // Expect bytes 4..<10 to be AB CD 00 00 00 00
        let stored = data.subdata(in: 4..<10)
        #expect(Array(stored) == [0xAB, 0xCD, 0x00, 0x00, 0x00, 0x00])
    }

    @Test("Long pub_key prefix is truncated to 6 bytes on encode")
    func encodeTruncatesLongPubKey() {
        let blob = NotifPrefsBlob(
            globalMode: .all,
            contactRules: [.init(pubKeyPrefix: Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]), mode: .silent)]
        )
        let data = blob.encode()
        let stored = data.subdata(in: 4..<10)
        #expect(Array(stored) == [1, 2, 3, 4, 5, 6])
    }

    @Test("Channel rules above maxChannelRules are dropped during encode")
    func encodeClampsChannelRules() {
        let many = (0..<32).map { NotifPrefsBlob.ChannelRule(channelIdx: UInt8($0), mode: .silent) }
        let blob = NotifPrefsBlob(globalMode: .all, channelRules: many)
        let data = blob.encode()
        #expect(data[2] == UInt8(NotifPrefsBlob.maxChannelRules))
    }

    @Test("Contact rules above maxContactRules are dropped during encode")
    func encodeClampsContactRules() {
        let many = (0..<32).map { i in
            NotifPrefsBlob.ContactRule(pubKeyPrefix: Data([UInt8(i), 0, 0, 0, 0, 0]), mode: .silent)
        }
        let blob = NotifPrefsBlob(globalMode: .all, contactRules: many)
        let data = blob.encode()
        #expect(data[3] == UInt8(NotifPrefsBlob.maxContactRules))
    }

    // MARK: - Round-trip

    @Test("encode -> decode round-trip preserves all fields")
    func roundTripFull() throws {
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
        let data = original.encode()
        let decoded = try #require(NotifPrefsBlob(decoding: data))

        #expect(decoded.version == 1)
        #expect(decoded.globalMode == original.globalMode)
        #expect(decoded.channelRules == original.channelRules)
        #expect(decoded.contactRules == original.contactRules)
    }

    @Test("Decoding an empty blob produces all-defaults")
    func decodeEmpty() throws {
        let data = Data([1, FirmwareNotifMode.all.rawValue, 0, 0])
        let decoded = try #require(NotifPrefsBlob(decoding: data))
        #expect(decoded.globalMode == .all)
        #expect(decoded.channelRules.isEmpty)
        #expect(decoded.contactRules.isEmpty)
    }

    @Test("Decoding rejects payloads with too few bytes for header")
    func decodeTooShort() {
        #expect(NotifPrefsBlob(decoding: Data()) == nil)
        #expect(NotifPrefsBlob(decoding: Data([1])) == nil)
    }

    @Test("Decoding stops gracefully on truncated channel-rule entries")
    func decodeTruncatedChannelRule() throws {
        // [ver=1][global=all][nch=2][idx=3, mode=silent][idx=5 ... truncated]
        let data = Data([1, FirmwareNotifMode.all.rawValue, 2, 3, FirmwareNotifMode.silent.rawValue, 5])
        let decoded = try #require(NotifPrefsBlob(decoding: data))
        #expect(decoded.channelRules.count == 1)
        #expect(decoded.channelRules[0].channelIdx == 3)
        #expect(decoded.channelRules[0].mode == .silent)
    }

    @Test("Decoding stops gracefully on truncated contact-rule entries")
    func decodeTruncatedContactRule() throws {
        // [ver=1][global=all][nch=0][nrt=2][pub_key(6) + mode(1) = 1 valid entry][partial second]
        var data = Data([1, FirmwareNotifMode.all.rawValue, 0, 2])
        data.append(Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]))
        data.append(FirmwareNotifMode.silent.rawValue)
        data.append(Data([0x11, 0x22]))  // truncated second entry (missing 4 bytes + mode)
        let decoded = try #require(NotifPrefsBlob(decoding: data))
        #expect(decoded.contactRules.count == 1)
        #expect(decoded.contactRules[0].pubKeyPrefix == Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]))
    }

    @Test("Decoding tolerates unknown FirmwareNotifMode raw values by dropping the entry")
    func decodeUnknownMode() throws {
        // version, global=all, nch=2, [3, valid=mentions], [4, invalid=99], nrt=0
        let data = Data([1, FirmwareNotifMode.all.rawValue, 2,
                         3, FirmwareNotifMode.mentions.rawValue,
                         4, 99,
                         0])
        let decoded = try #require(NotifPrefsBlob(decoding: data))
        // Invalid entry is silently skipped (encoder/firmware never produces it)
        #expect(decoded.channelRules.count == 1)
        #expect(decoded.channelRules[0].channelIdx == 3)
    }

    @Test("Decoding rejects unknown global mode")
    func decodeUnknownGlobalMode() {
        let data = Data([1, 99, 0, 0])
        #expect(NotifPrefsBlob(decoding: data) == nil)
    }

    // MARK: - Equatable conformance

    @Test("Equal blobs compare equal")
    func equatable() {
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
    }

    @Test("Different global modes are unequal")
    func notEqual() {
        let a = NotifPrefsBlob(globalMode: .all)
        let b = NotifPrefsBlob(globalMode: .mentions)
        #expect(a != b)
    }
}
