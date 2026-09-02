import Foundation
@testable import MC1Services
import MeshCore
import Testing

/// `packetContentHash` is the message row's copy of a packet's mesh-wide identity —
/// the value the opt-in Packet Scope lookup keys on. These tests pin the two places
/// it must survive: the backup wire format (additively — legacy envelopes have no
/// key) and the DTO ↔ model round trip.
@Suite("Message packetContentHash")
struct MessagePacketContentHashTests {
  /// MeshCore's `Data(hexString:)` is internal; a two-line local stand-in beats
  /// widening that API for a test.
  private func data(hex: String) -> Data {
    var bytes: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      bytes.append(UInt8(hex[index..<next], radix: 16)!)
      index = next
    }
    return Data(bytes)
  }

  private func makeDTO(hash: String?) -> MessageDTO {
    MessageDTO(
      id: UUID(),
      radioID: UUID(),
      contactID: nil,
      channelIndex: 3,
      text: "hello mesh",
      timestamp: 1_788_229_000,
      createdAt: Date(timeIntervalSince1970: 1_788_229_000),
      direction: .incoming,
      status: .delivered,
      textType: .plain,
      ackCode: nil,
      pathLength: 1,
      snr: 7.5,
      senderKeyPrefix: nil,
      senderNodeName: "Node",
      isRead: false,
      replyToID: nil,
      roundTripTime: nil,
      heardRepeats: 0,
      retryAttempt: 0,
      maxRetryAttempts: 0,
      packetContentHash: hash
    )
  }

  @Test
  func `round-trips through the backup wire format`() throws {
    let dto = makeDTO(hash: "286dcbdeab84b458")
    let data = try JSONEncoder().encode(dto)
    let decoded = try JSONDecoder().decode(MessageDTO.self, from: data)
    #expect(decoded.packetContentHash == "286dcbdeab84b458")
  }

  @Test
  func `a legacy envelope without the key decodes to nil`() throws {
    let dto = makeDTO(hash: "286dcbdeab84b458")
    var json = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(dto)) as? [String: Any]
    )
    json.removeValue(forKey: "packetContentHash")
    let legacyData = try JSONSerialization.data(withJSONObject: json)
    let decoded = try JSONDecoder().decode(MessageDTO.self, from: legacyData)
    #expect(decoded.packetContentHash == nil)
  }

  @Test
  func `survives the DTO to model to DTO round trip`() {
    let dto = makeDTO(hash: "b120e42c91ae7ca9")
    let model = Message(dto: dto)
    #expect(model.packetContentHash == "b120e42c91ae7ca9")
    let back = MessageDTO(from: model)
    #expect(back.packetContentHash == "b120e42c91ae7ca9")
  }

  @Test
  func `RxLogEntryDTO contentHash applies the firmware formula to persisted fields`() {
    let parsed = ParsedRxLogData(
      snr: nil,
      rssi: nil,
      rawPayload: data(hex: "0541ABBA4CA2B63CFF458621FB325BC6B2073010B6C14ECB"),
      routeType: .flood,
      payloadType: .response,
      payloadVersion: 0,
      payloadTypeBits: 1,
      transportCode: nil,
      pathLength: 0x41,
      pathNodes: [0xAB, 0xBA],
      packetPayload: data(hex: "4CA2B63CFF458621FB325BC6B2073010B6C14ECB")
    )
    let entry = RxLogEntryDTO(radioID: UUID(), from: parsed)
    // Ground truth from the CoreScope observer network for this live packet.
    #expect(entry.contentHash == "286dcbdeab84b458")
    #expect(entry.contentHash == parsed.contentHash)
  }
}
