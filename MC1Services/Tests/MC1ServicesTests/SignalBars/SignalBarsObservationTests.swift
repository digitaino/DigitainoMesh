import Foundation
@testable import MC1Services
import MeshCore
import Testing

/// Spec source: legacy `AdvertisementService`'s `.rxLogData` / `.discoverResponse`
/// handling (which posted `rxLogPacketReceived`, `rxLogTraceReceived` and
/// `discoverResponseReceived`) plus `SignalBarsService.handleDiscoverResponse`'s
/// re-derivation of the display hash from the public key.
@Suite("SignalBarsObservation wire rules")
struct SignalBarsObservationTests {
  // MARK: - Hash width

  @Test
  func `The display hash is re-derived from the public key at the device's path hash mode`() throws {
    let key = SignalBarsFixtures.publicKey([0x0C, 0x13, 0xAB, 0x77])
    let cases: [(mode: UInt8, hex: String)] = [
      (0, "0C"),
      (1, "0C13"),
      (2, "0C13AB"),
      (3, "0C13AB") // clamped: the firmware advertises at most 3 bytes
    ]
    for testCase in cases {
      let id = try #require(
        SignalBarsObservation.hashID(forPublicKey: key, pathHashMode: testCase.mode)
      )
      #expect(id.hex == testCase.hex)
    }
  }

  @Test
  func `An empty public key yields no hash`() {
    #expect(SignalBarsObservation.hashID(forPublicKey: Data(), pathHashMode: 0) == nil)
  }

  @Test
  func `A probe is addressed with mode plus one key bytes`() {
    let key = SignalBarsFixtures.publicKey([0x0C, 0x13, 0xAB, 0x77])
    #expect(SignalBarsObservation.probePath(forPublicKey: key, pathHashMode: 0) == Data([0x0C]))
    #expect(SignalBarsObservation.probePath(forPublicKey: key, pathHashMode: 1) == Data([0x0C, 0x13]))
    #expect(
      SignalBarsObservation.probePath(forPublicKey: key, pathHashMode: 2) == Data([0x0C, 0x13, 0xAB])
    )
  }

  // MARK: - Discover responses

  @Test
  func `A discover response carries both legs and the key that makes a repeater probeable`() throws {
    let key = SignalBarsFixtures.publicKey([0x0C, 0x13])
    let response = SignalBarsFixtures.discoverResponse(
      publicKey: key,
      snr: 7.5,
      snrIn: -2.25,
      rssi: -66
    )
    let sighting = try #require(
      SignalBarsObservation.sighting(from: response, pathHashMode: 1)
    )
    #expect(sighting.id.hex == "0C13")
    #expect(sighting.rxSnr == 7.5)
    #expect(sighting.txSnr == -2.25)
    #expect(sighting.rssi == -66)
    #expect(sighting.publicKey == key)
  }

  // MARK: - Passive packets

  @Test
  func `A relayed packet's last hop becomes an RX-only sighting at the path's hash width`() throws {
    let cases: [(path: [UInt8], hashSize: Int, hex: String)] = [
      ([0x0C], 1, "0C"),
      ([0xAA, 0x0C], 1, "0C"),
      ([0xAA, 0xBB, 0x0C, 0x13], 2, "0C13"),
      ([0x11, 0x22, 0x33, 0x0C, 0x13, 0xAB], 3, "0C13AB")
    ]
    for testCase in cases {
      let log = SignalBarsFixtures.relayedPacket(path: testCase.path, hashSize: testCase.hashSize)
      let sighting = try #require(
        SignalBarsObservation.passiveSighting(from: log),
        "expected a sighting for \(testCase.path)"
      )
      #expect(sighting.id.hex == testCase.hex)
      #expect(sighting.rxSnr == 4.0)
      #expect(sighting.rssi == -80)
      #expect(sighting.txSnr == nil, "a passive packet says nothing about how they hear us")
      #expect(sighting.publicKey == nil)
    }
  }

  @Test
  func `Packets that cannot place a repeater are ignored`() {
    let noPath = SignalBarsFixtures.relayedPacket(path: [], hashSize: 1)
    #expect(SignalBarsObservation.passiveSighting(from: noPath) == nil)

    let noSNR = SignalBarsFixtures.relayedPacket(path: [0x0C], hashSize: 1, snr: nil)
    #expect(SignalBarsObservation.passiveSighting(from: noSNR) == nil)

    let trace = SignalBarsFixtures.relayedPacket(path: [0x0C], hashSize: 1, payloadType: .trace)
    #expect(
      SignalBarsObservation.passiveSighting(from: trace) == nil,
      "trace packets are probe replies, not sightings"
    )
  }

  // MARK: - Probe replies

  @Test
  func `A trace reply's tag is the first four payload bytes little-endian`() throws {
    let reply = try #require(
      SignalBarsObservation.probeReply(from: SignalBarsFixtures.traceReply(tag: 0x1234_5678))
    )
    #expect(reply.tag == 0x1234_5678)
    #expect(reply.localSnr == 5.0)
  }

  @Test
  func `The far end's SNR is the last path byte in quarter-dB steps`() throws {
    let cases: [(raw: Int8, snr: Double)] = [(12, 3.0), (-8, -2.0), (0, 0.0), (-40, -10.0)]
    for testCase in cases {
      let reply = try #require(
        SignalBarsObservation.probeReply(
          from: SignalBarsFixtures.traceReply(tag: 7, remoteSnrX4: testCase.raw)
        )
      )
      #expect(reply.remoteSnr == testCase.snr)
    }
  }

  @Test
  func `A reply with no path records no remote SNR rather than substituting our own`() throws {
    let reply = try #require(
      SignalBarsObservation.probeReply(
        from: SignalBarsFixtures.traceReply(tag: 7, remoteSnrX4: nil)
      )
    )
    #expect(reply.remoteSnr == nil)
    #expect(reply.localSnr == 5.0)
  }

  @Test
  func `Non-trace, truncated and SNR-less log entries are not probe replies`() {
    let notTrace = SignalBarsFixtures.relayedPacket(path: [0x0C])
    #expect(SignalBarsObservation.probeReply(from: notTrace) == nil)

    let noSNR = SignalBarsFixtures.traceReply(tag: 7, localSnr: nil)
    #expect(SignalBarsObservation.probeReply(from: noSNR) == nil)

    let truncated = ParsedRxLogData(
      snr: 5,
      rssi: nil,
      rawPayload: Data(),
      routeType: .direct,
      payloadType: .trace,
      payloadVersion: 0,
      payloadTypeBits: 0,
      transportCode: nil,
      pathLength: 0,
      pathNodes: [],
      packetPayload: Data([0x01, 0x02])
    )
    #expect(SignalBarsObservation.probeReply(from: truncated) == nil)
  }

  // MARK: - Subscription filter

  @Test
  func `The engine subscribes to signal-bars sync pushes, discover responses and RX logs only`() {
    let filter = SignalBarsObservation.eventFilter
    #expect(filter.matches(.syncValue(.signalBars, Data([0x02, 0x00]))))
    #expect(!filter.matches(.syncValue(.notifPrefs, Data([0x01]))))
    #expect(filter.matches(.discoverResponse(
      SignalBarsFixtures.discoverResponse(publicKey: SignalBarsFixtures.publicKey([0x0C]))
    )))
    #expect(filter.matches(.rxLogData(SignalBarsFixtures.relayedPacket(path: [0x0C]))))
    #expect(!filter.matches(.advertisement(publicKey: Data([0x0C]))))
    #expect(!filter.matches(.ok(value: nil)))
  }
}
