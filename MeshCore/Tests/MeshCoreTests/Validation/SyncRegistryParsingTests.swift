import Foundation
@testable import MeshCore
import Testing

@Suite("Sync registry parsing")
struct SyncRegistryParsingTests {
  // MARK: - Happy path

  @Test
  func `syncValue parses a blob for notifPrefs`() {
    // Wire frame: [0x64][sync_id][len_lo][len_hi][blob...]
    let frame = Data([0x64, 0x01, 0x03, 0x00, 0xAA, 0xBB, 0xCC])

    let event = PacketParser.parse(frame)
    guard case let .syncValue(id, blob) = event else {
      Issue.record("Expected .syncValue, got \(event)")
      return
    }
    #expect(id == .notifPrefs)
    #expect(blob == Data([0xAA, 0xBB, 0xCC]))
  }

  @Test
  func `syncValue parses a multi-byte length little-endian`() {
    // 260 == 0x0104 -> low byte 0x04, high byte 0x01.
    var frame = Data([0x64, 0x02, 0x04, 0x01])
    frame.append(Data(repeating: 0x5A, count: 260))

    let event = PacketParser.parse(frame)
    guard case let .syncValue(id, blob) = event else {
      Issue.record("Expected .syncValue, got \(event)")
      return
    }
    #expect(id == .signalBars)
    #expect(blob.count == 260)
    #expect(blob.allSatisfy { $0 == 0x5A })
  }

  @Test
  func `syncValue parses an empty blob`() {
    let event = PacketParser.parse(Data([0x64, 0x02, 0x00, 0x00]))
    guard case let .syncValue(id, blob) = event else {
      Issue.record("Expected .syncValue, got \(event)")
      return
    }
    #expect(id == .signalBars)
    #expect(blob.isEmpty)
  }

  @Test
  func `syncValue ignores bytes past the declared length`() {
    let event = PacketParser.parse(Data([0x64, 0x01, 0x02, 0x00, 0x11, 0x22, 0x33, 0x44]))
    guard case let .syncValue(_, blob) = event else {
      Issue.record("Expected .syncValue, got \(event)")
      return
    }
    #expect(blob == Data([0x11, 0x22]), "Only the declared length is taken")
  }

  // MARK: - Malformed frames

  @Test
  func `syncValue rejects a frame shorter than its header`() {
    let event = PacketParser.parse(Data([0x64, 0x01, 0x03]))
    guard case let .parseFailure(_, reason) = event else {
      Issue.record("Expected .parseFailure, got \(event)")
      return
    }
    #expect(reason.contains("too short"))
  }

  @Test
  func `syncValue rejects a truncated blob`() {
    // Declares 8 bytes but only carries 2.
    let event = PacketParser.parse(Data([0x64, 0x01, 0x08, 0x00, 0xAA, 0xBB]))
    guard case let .parseFailure(_, reason) = event else {
      Issue.record("Expected .parseFailure, got \(event)")
      return
    }
    #expect(reason.contains("truncated"))
  }

  @Test
  func `syncValue rejects an unknown sync_id`() {
    let event = PacketParser.parse(Data([0x64, 0x09, 0x01, 0x00, 0xAA]))
    guard case let .parseFailure(_, reason) = event else {
      Issue.record("Expected .parseFailure, got \(event)")
      return
    }
    #expect(reason.contains("unknown sync_id"))
  }

  // MARK: - Round trip

  @Test
  func `setSync payload survives a build then parse round trip`() {
    let blob = Data((0..<64).map { UInt8($0) })
    let command = PacketBuilder.setSync(id: .notifPrefs, payload: blob)

    // The device echoes the stored blob back under the syncValue response code,
    // reusing the same [sync_id][len LE][blob] framing the command carries.
    var response = Data([ResponseCode.syncValue.rawValue])
    response.append(Data(command.dropFirst()))

    let event = PacketParser.parse(response)
    guard case let .syncValue(id, decoded) = event else {
      Issue.record("Expected .syncValue, got \(event)")
      return
    }
    #expect(id == .notifPrefs)
    #expect(decoded == blob)
  }

  // MARK: - syncList

  @Test
  func `syncList parses entries with little-endian lengths`() {
    // Wire frame: [0x65][count]([sync_id][len_lo][len_hi]) x count
    // 300 == 0x012C -> low byte 0x2C, high byte 0x01.
    let frame = Data([0x65, 0x02, 0x01, 0x10, 0x00, 0x02, 0x2C, 0x01])

    let event = PacketParser.parse(frame)
    guard case let .syncList(entries) = event else {
      Issue.record("Expected .syncList, got \(event)")
      return
    }
    #expect(entries == [
      SyncListEntry(id: 0x01, length: 16),
      SyncListEntry(id: 0x02, length: 300),
    ])
  }

  @Test
  func `syncList parses an empty registry`() {
    let event = PacketParser.parse(Data([0x65, 0x00]))
    guard case let .syncList(entries) = event else {
      Issue.record("Expected .syncList, got \(event)")
      return
    }
    #expect(entries.isEmpty)
  }

  @Test
  func `syncList preserves sync_ids this library does not know`() {
    // Newer firmware may advertise slots beyond SyncID; the raw id must survive.
    let event = PacketParser.parse(Data([0x65, 0x01, 0x7F, 0x02, 0x00]))
    guard case let .syncList(entries) = event else {
      Issue.record("Expected .syncList, got \(event)")
      return
    }
    #expect(entries == [SyncListEntry(id: 0x7F, length: 2)])
  }

  @Test
  func `syncList ignores bytes past the declared count`() {
    let event = PacketParser.parse(Data([0x65, 0x01, 0x02, 0x08, 0x00, 0xDE, 0xAD]))
    guard case let .syncList(entries) = event else {
      Issue.record("Expected .syncList, got \(event)")
      return
    }
    #expect(entries == [SyncListEntry(id: 0x02, length: 8)], "Only the declared count is taken")
  }

  @Test
  func `syncList rejects an empty payload`() {
    let event = PacketParser.parse(Data([0x65]))
    guard case let .parseFailure(_, reason) = event else {
      Issue.record("Expected .parseFailure, got \(event)")
      return
    }
    #expect(reason.contains("empty"))
  }

  @Test
  func `syncList rejects a truncated entry table`() {
    // Declares two entries but carries bytes for one and a half.
    let event = PacketParser.parse(Data([0x65, 0x02, 0x01, 0x10, 0x00, 0x02, 0x2C]))
    guard case let .parseFailure(_, reason) = event else {
      Issue.record("Expected .parseFailure, got \(event)")
      return
    }
    #expect(reason.contains("truncated"))
  }
}
