import Foundation
@testable import MeshCore
import Testing

@Suite("Sync registry commands")
struct SyncRegistryCommandsTests {
  // MARK: - Opcodes

  @Test
  func `sync registry opcodes match firmware`() {
    #expect(CommandCode.getSync.rawValue == 0x44)
    #expect(CommandCode.setSync.rawValue == 0x45)
    #expect(CommandCode.listSync.rawValue == 0x46)
    #expect(ResponseCode.syncValue.rawValue == 0x64)
    #expect(ResponseCode.syncList.rawValue == 0x65)
    #expect(SyncID.notifPrefs.rawValue == 1)
    #expect(SyncID.signalBars.rawValue == 2)
    #expect(SyncID.motionHint.rawValue == 3)
    #expect(FirmwareNotifMode.silent.rawValue == 0)
    #expect(FirmwareNotifMode.all.rawValue == 1)
    #expect(FirmwareNotifMode.mentions.rawValue == 2)
    #expect(FirmwareNotifMode.urgent.rawValue == 3)
  }

  @Test
  func `syncValue routes through the device-category parser`() {
    #expect(ResponseCode.syncValue.category == .device)
  }

  @Test
  func `syncList routes through the device-category parser`() {
    #expect(ResponseCode.syncList.category == .device)
  }

  // MARK: - getSync

  @Test
  func `getSync notifPrefs format`() {
    #expect(PacketBuilder.getSync(id: .notifPrefs) == Data([0x44, 0x01]))
  }

  @Test
  func `getSync signalBars format`() {
    #expect(PacketBuilder.getSync(id: .signalBars) == Data([0x44, 0x02]))
  }

  // MARK: - setSync

  @Test
  func `setSync format carries a little-endian length before the blob`() {
    let packet = PacketBuilder.setSync(id: .notifPrefs, payload: Data([0xDE, 0xAD, 0xBE, 0xEF]))

    #expect(packet[0] == 0x45, "Command code")
    #expect(packet[1] == 0x01, "Sync ID")
    #expect(packet[2] == 0x04 && packet[3] == 0x00, "Payload length LE")
    #expect(Data(packet[4...]) == Data([0xDE, 0xAD, 0xBE, 0xEF]), "Blob follows the header")
    #expect(packet == Data([0x45, 0x01, 0x04, 0x00, 0xDE, 0xAD, 0xBE, 0xEF]))
  }

  @Test
  func `setSync with an empty payload still writes a zero length`() {
    #expect(PacketBuilder.setSync(id: .signalBars, payload: Data()) == Data([0x45, 0x02, 0x00, 0x00]))
  }

  @Test
  func `setSync encodes multi-byte lengths little-endian`() {
    // 300 == 0x012C -> low byte 0x2C, high byte 0x01.
    let packet = PacketBuilder.setSync(id: .signalBars, payload: Data(repeating: 0x5A, count: 300))

    #expect(packet[2] == 0x2C && packet[3] == 0x01, "300 bytes as LE UInt16")
    #expect(packet.count == 4 + 300)
  }

  @Test
  func `setSync clamps payloads the length field cannot describe`() {
    // The 16-bit length field cannot describe more than 65535 bytes; the builder
    // truncates rather than trapping on the UInt16 conversion.
    let packet = PacketBuilder.setSync(
      id: .notifPrefs,
      payload: Data(repeating: 0xFF, count: PacketBuilder.syncMaxPayloadBytes + 16)
    )

    #expect(packet[2] == 0xFF && packet[3] == 0xFF, "Length saturates at 0xFFFF")
    #expect(packet.count == 4 + PacketBuilder.syncMaxPayloadBytes)
  }

  // MARK: - listSync

  @Test
  func `listSync format is the bare command code`() {
    #expect(PacketBuilder.listSync() == Data([0x46]))
  }

  // MARK: - motionHint

  @Test
  func `motionHint rides setSync with a version and level byte`() {
    // The blob layout ([version][level]) belongs to the consuming service; MeshCore
    // only needs the slot id to frame it correctly.
    #expect(
      PacketBuilder.setSync(id: .motionHint, payload: Data([0x01, 0x02]))
        == Data([0x45, 0x03, 0x02, 0x00, 0x01, 0x02])
    )
  }
}
