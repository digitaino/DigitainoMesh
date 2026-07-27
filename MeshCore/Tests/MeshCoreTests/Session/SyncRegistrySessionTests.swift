import Foundation
@testable import MeshCore
import Testing

@Suite("Sync registry session methods")
struct SyncRegistrySessionTests {
  // MARK: - getSync

  @Test
  func `getSync emits the correct frame and returns the blob`() async throws {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
    )
    try await startSession(session, transport: transport)

    let task = Task {
      try await session.getSync(.signalBars)
    }

    try await waitUntil("getSync should be sent") {
      await transport.sentData.count == 2
    }
    let sent = await transport.sentData[1]
    #expect(sent == Data([0x44, 0x02]))

    await transport.simulateReceive(makeSyncValuePacket(id: .signalBars, blob: Data([0x01, 0x02, 0x03])))

    let blob = try await task.value
    #expect(blob == Data([0x01, 0x02, 0x03]))
    await session.stop()
  }

  @Test
  func `getSync ignores a syncValue for a different slot`() async throws {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
    )
    try await startSession(session, transport: transport)

    let task = Task {
      try await session.getSync(.notifPrefs)
    }
    try await waitUntil("getSync should be sent") {
      await transport.sentData.count == 2
    }

    // A blob for the other slot must not resolve this request; if it did, the
    // request would return 0xFF instead of the 0x42 that follows.
    await transport.simulateReceive(makeSyncValuePacket(id: .signalBars, blob: Data([0xFF])))
    try? await Task.sleep(for: .milliseconds(50))
    await transport.simulateReceive(makeSyncValuePacket(id: .notifPrefs, blob: Data([0x42])))

    let blob = try await task.value
    #expect(blob == Data([0x42]), "Only the matching slot resolves the request")
    await session.stop()
  }

  @Test
  func `getSync returns an empty blob when the device stores nothing`() async throws {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
    )
    try await startSession(session, transport: transport)

    let task = Task {
      try await session.getSync(.notifPrefs)
    }
    try await waitUntil("getSync should be sent") {
      await transport.sentData.count == 2
    }
    await transport.simulateReceive(makeSyncValuePacket(id: .notifPrefs, blob: Data()))

    let blob = try await task.value
    #expect(blob.isEmpty)
    await session.stop()
  }

  @Test
  func `getSync throws deviceError when the firmware rejects the opcode`() async throws {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
    )
    try await startSession(session, transport: transport)

    let task = Task {
      try await session.getSync(.notifPrefs)
    }
    try await waitUntil("getSync should be sent") {
      await transport.sentData.count == 2
    }
    await transport.simulateError(code: 3)

    let err = await #expect(throws: MeshCoreError.self) {
      try await task.value
    }
    guard case let .deviceError(code)? = err else {
      Issue.record("Expected deviceError, got \(String(describing: err))")
      await session.stop()
      return
    }
    #expect(code == 3)
    await session.stop()
  }

  @Test
  func `getSync times out when a malformed syncValue never decodes`() async throws {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 0.2, clientIdentifier: "MCTst")
    )
    try await startSession(session, transport: transport)

    let task = Task {
      try await session.getSync(.notifPrefs)
    }
    try await waitUntil("getSync should be sent") {
      await transport.sentData.count == 2
    }

    // Declares 8 blob bytes but carries 2 — parses to .parseFailure, never .syncValue.
    await transport.simulateReceive(Data([0x64, 0x01, 0x08, 0x00, 0xAA, 0xBB]))

    let err = await #expect(throws: MeshCoreError.self) {
      try await task.value
    }
    guard case .timeout? = err else {
      Issue.record("Expected timeout, got \(String(describing: err))")
      await session.stop()
      return
    }
    await session.stop()
  }

  // MARK: - setSync

  @Test
  func `setSync emits the correct frame and awaits OK`() async throws {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
    )
    try await startSession(session, transport: transport)

    let task = Task {
      try await session.setSync(.notifPrefs, payload: Data([0xDE, 0xAD]))
    }
    try await waitUntil("setSync should be sent") {
      await transport.sentData.count == 2
    }
    let sent = await transport.sentData[1]
    #expect(sent == Data([0x45, 0x01, 0x02, 0x00, 0xDE, 0xAD]))

    await transport.simulateOK()
    try await task.value
    await session.stop()
  }

  @Test
  func `setSync throws deviceError on an error response`() async throws {
    let transport = MockTransport()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 10, clientIdentifier: "MCTst")
    )
    try await startSession(session, transport: transport)

    let task = Task {
      try await session.setSync(.signalBars, payload: Data([0x01]))
    }
    try await waitUntil("setSync should be sent") {
      await transport.sentData.count == 2
    }
    await transport.simulateError(code: 5)

    let err = await #expect(throws: MeshCoreError.self) {
      try await task.value
    }
    guard case let .deviceError(code)? = err else {
      Issue.record("Expected deviceError, got \(String(describing: err))")
      await session.stop()
      return
    }
    #expect(code == 5)
    await session.stop()
  }
}

private func makeSyncValuePacket(id: SyncID, blob: Data) -> Data {
  var packet = Data([ResponseCode.syncValue.rawValue, id.rawValue])
  packet.append(contentsOf: withUnsafeBytes(of: UInt16(blob.count).littleEndian) { Array($0) })
  packet.append(blob)
  return packet
}

private func startSession(
  _ session: MeshCoreSession,
  transport: MockTransport
) async throws {
  let startTask = Task { try await session.start() }
  try await waitUntil("transport should send appStart before session starts") {
    await transport.sentData.count == 1
  }
  await transport.simulateReceive(makeSelfInfoPacket())
  try await startTask.value
}

private func makeSelfInfoPacket() -> Data {
  var payload = Data([ResponseCode.selfInfo.rawValue])
  payload.append(1) // adv type
  payload.append(UInt8(bitPattern: 22)) // tx power
  payload.append(UInt8(bitPattern: 22)) // max tx power
  payload.append(Data(repeating: 0x01, count: 32)) // pubkey
  payload.append(contentsOf: withUnsafeBytes(of: Int32(0).littleEndian) { Array($0) }) // lat
  payload.append(contentsOf: withUnsafeBytes(of: Int32(0).littleEndian) { Array($0) }) // lon
  payload.append(0) // multi acks
  payload.append(0) // adv loc policy
  payload.append(0) // telemetry mode
  payload.append(0) // manual add
  payload.append(contentsOf: withUnsafeBytes(of: UInt32(869_525).littleEndian) { Array($0) }) // freq
  payload.append(contentsOf: withUnsafeBytes(of: UInt32(250_000).littleEndian) { Array($0) }) // bw
  payload.append(11) // sf
  payload.append(5) // cr
  return payload
}
