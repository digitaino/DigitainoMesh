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
}
