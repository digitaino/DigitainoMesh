import Foundation
@testable import MC1Services
import Testing

@Suite("SignalBarsBlob")
struct SignalBarsBlobTests {
  private func entry(
    id: UInt8 = 0,
    idHash: [UInt8] = [],
    rxSnrX4: Int8 = 0,
    txSnrX4: Int8 = 0,
    hasRx: Bool = true,
    hasTx: Bool = true,
    txFailed: Bool = false,
    isBest: Bool = false,
    ageSeconds: UInt16 = 0,
    rttMs: UInt16 = 0
  ) -> SignalBarsBlob.Entry {
    .init(
      id: id,
      idHash: idHash,
      rxSnrX4: rxSnrX4,
      txSnrX4: txSnrX4,
      hasRx: hasRx,
      hasTx: hasTx,
      txFailed: txFailed,
      isBest: isBest,
      ageSeconds: ageSeconds,
      rttMs: rttMs
    )
  }

  // MARK: - Encoding wire layout (v2)

  @Test
  func `Empty blob encodes to 2 bytes: version 2, count 0`() {
    let data = SignalBarsBlob().encode()
    #expect(data.count == 2)
    #expect(data[0] == 2) // version
    #expect(data[1] == 0) // count
  }

  @Test
  func `One entry encodes header + an 11-byte v2 record with correct fields, flags and LE values`() {
    let blob = SignalBarsBlob(entries: [
      entry(
        id: 0x0C,
        rxSnrX4: 40,
        txSnrX4: -20,
        hasRx: true,
        hasTx: true,
        txFailed: false,
        isBest: true,
        ageSeconds: 300,
        rttMs: 1234
      )
    ])
    let data = blob.encode()
    #expect(data.count == 2 + 11)
    #expect(data[0] == 2) // version
    #expect(data[1] == 1) // count
    #expect(data[2] == 1) // id_len — empty idHash falls back to [id]
    #expect(data[3] == 0x0C) // h0
    #expect(data[4] == 0x00) // h1 (unused, zero-filled)
    #expect(data[5] == 0x00) // h2 (unused, zero-filled)
    #expect(data[6] == UInt8(bitPattern: 40)) // rx_x4
    #expect(data[7] == UInt8(bitPattern: -20)) // tx_x4 (236)
    #expect(data[8] == (0x01 | 0x02 | 0x08)) // has_rx | has_tx | is_best
    #expect(data[9] == UInt8(300 & 0xFF)) // age lo (0x2C)
    #expect(data[10] == UInt8(300 >> 8)) // age hi (0x01)
    #expect(data[11] == UInt8(1234 & 0xFF)) // rtt lo (0xD2)
    #expect(data[12] == UInt8(1234 >> 8)) // rtt hi (0x04)
  }

  @Test
  func `A multi-byte hash writes its real length and bytes, and is truncated to 3`() {
    let data = SignalBarsBlob(entries: [entry(id: 0x0C, idHash: [0x0C, 0x13, 0xAB, 0xFF])]).encode()
    #expect(data[2] == 3) // id_len clamped to 3
    #expect(data[3] == 0x0C)
    #expect(data[4] == 0x13)
    #expect(data[5] == 0xAB)
  }

  // MARK: - Round-trip

  @Test
  func `encode then decode round-trips every entry`() throws {
    let entries = [
      entry(
        id: 1,
        idHash: [1],
        rxSnrX4: 44,
        txSnrX4: 20,
        hasRx: true,
        hasTx: true,
        txFailed: false,
        isBest: true,
        ageSeconds: 5,
        rttMs: 800
      ),
      entry(
        id: 0xFF,
        idHash: [0xFF, 0x0A, 0x7C],
        rxSnrX4: -40,
        txSnrX4: 0,
        hasRx: true,
        hasTx: false,
        txFailed: true,
        isBest: false,
        ageSeconds: 65535,
        rttMs: 0
      )
    ]
    let data = SignalBarsBlob(entries: entries).encode()
    let decoded = try #require(SignalBarsBlob(decoding: data))
    #expect(decoded.version == 2)
    #expect(decoded.entries == entries)
  }

  @Test
  func `An entry encoded without an idHash decodes with the id as its single hash byte`() throws {
    let data = SignalBarsBlob(entries: [entry(id: 0x0C)]).encode()
    let decoded = try #require(SignalBarsBlob(decoding: data))
    #expect(decoded.entries.first?.idHash == [0x0C])
    #expect(decoded.entries.first?.hexID == "0C")
  }

  // MARK: - Decoding

  @Test
  func `Legacy version-1 payloads still decode as 8-byte records`() throws {
    // id=0x07, rx=-1 (0xFF), tx=0, flags = has_rx | tx_failed (0x05), age=0, rtt=0
    let data = Data([1, 1, 0x07, 0xFF, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00])
    let blob = try #require(SignalBarsBlob(decoding: data))
    #expect(blob.version == 1)
    let entry = try #require(blob.entries.first)
    #expect(entry.id == 0x07)
    #expect(entry.rxSnrX4 == -1)
    #expect(entry.hasRx == true)
    #expect(entry.hasTx == false)
    #expect(entry.txFailed == true)
    #expect(entry.isBest == false)
    #expect(entry.idHash.isEmpty) // v1 carries no hash; hexID falls back to [id]
    #expect(entry.hexID == "07")
  }

  @Test
  func `A version-2 id_len of 0 is read as 1 byte and a length above 3 is clamped to 3`() throws {
    let short = Data([2, 1, 0, 0xAB, 0xCD, 0xEF, 0, 0, 0, 0, 0, 0, 0])
    #expect(try #require(SignalBarsBlob(decoding: short)).entries.first?.idHash == [0xAB])

    let long = Data([2, 1, 5, 0xAB, 0xCD, 0xEF, 0, 0, 0, 0, 0, 0, 0])
    #expect(try #require(SignalBarsBlob(decoding: long)).entries.first?.idHash == [0xAB, 0xCD, 0xEF])
  }

  @Test
  func `Decoding rejects payloads too short for the header`() {
    #expect(SignalBarsBlob(decoding: Data()) == nil)
    #expect(SignalBarsBlob(decoding: Data([1])) == nil)
  }

  @Test
  func `Decoding stops gracefully on a truncated trailing version-2 entry`() throws {
    // count says 2, but only one full 11-byte record + a 3-byte stub follow
    var data = Data([2, 2])
    data.append(contentsOf: [1, 0x0C, 0, 0, 40, 20, 0x03, 0x05, 0x00, 0xD2, 0x04]) // full record
    data.append(contentsOf: [1, 0x0D, 0]) // partial
    let decoded = try #require(SignalBarsBlob(decoding: data))
    #expect(decoded.entries.count == 1)
    #expect(decoded.entries[0].id == 0x0C)
  }

  @Test
  func `Decoding stops gracefully on a truncated trailing version-1 entry`() throws {
    var data = Data([1, 2])
    data.append(contentsOf: [0x0C, 40, 20, 0x03, 0x05, 0x00, 0xD2, 0x04]) // full entry
    data.append(contentsOf: [0x0D, 10]) // partial
    let decoded = try #require(SignalBarsBlob(decoding: data))
    #expect(decoded.entries.count == 1)
    #expect(decoded.entries[0].id == 0x0C)
  }

  // MARK: - Computed accessors

  @Test
  func `rxSnr and txSnr convert from x4 and respect has_rx and has_tx`() {
    let e = entry(rxSnrX4: 40, txSnrX4: -8, hasRx: true, hasTx: true)
    #expect(e.rxSnr == 10.0) // 40 / 4
    #expect(e.txSnr == -2.0) // -8 / 4

    let none = entry(rxSnrX4: 40, txSnrX4: 40, hasRx: false, hasTx: false)
    #expect(none.rxSnr == nil)
    #expect(none.txSnr == nil)
  }

  @Test
  func `hexID is uppercase hex at the advertised hash width`() {
    #expect(entry(id: 0x0C).hexID == "0C")
    #expect(entry(id: 0xAB).hexID == "AB")
    #expect(entry(id: 5).hexID == "05")
    #expect(entry(id: 0x0C, idHash: [0x0C, 0x13]).hexID == "0C13")
    #expect(entry(id: 0x0C, idHash: [0x0C, 0x13, 0xAB]).hexID == "0C13AB")
  }

  // MARK: - Shared best-link scorer

  @Test
  func `A bidirectional score is 0_6 times TX plus 0_4 times RX`() {
    // rx=10, tx=20 -> 12 + 4 = 16
    #expect(abs(SignalBarsBlob.score(rxSnr: 10, txSnr: 20) - 16.0) < 0.0001)
  }

  @Test
  func `The blend favours TX over RX`() {
    let strongRx = SignalBarsBlob.score(rxSnr: 20, txSnr: 0) // 8
    let strongTx = SignalBarsBlob.score(rxSnr: 0, txSnr: 20) // 12
    #expect(strongTx > strongRx)
  }

  @Test
  func `Weak-leg guard: a dead direction at or below -10 dB ranks the link by that leg`() {
    // RX dead, TX great -> ranked by RX (-12), not the blend
    #expect(SignalBarsBlob.score(rxSnr: -12, txSnr: 20) == -12)
    // TX dead, RX fine -> ranked by TX (-15)
    #expect(SignalBarsBlob.score(rxSnr: 8, txSnr: -15) == -15)
    // Boundary: exactly -10 triggers the guard (<=)
    #expect(SignalBarsBlob.score(rxSnr: -10, txSnr: 20) == -10)
  }

  @Test
  func `Unidirectional links score by their one leg and an empty link scores -999`() {
    #expect(SignalBarsBlob.score(rxSnr: 7, txSnr: nil) == 7)
    #expect(SignalBarsBlob.score(rxSnr: nil, txSnr: 5) == 5)
    #expect(SignalBarsBlob.score(rxSnr: nil, txSnr: nil) == -999)
  }

  // MARK: - Equatable

  @Test
  func `Equal blobs compare equal and differing ids compare unequal`() {
    let a = SignalBarsBlob(entries: [entry(id: 1, rxSnrX4: 10)])
    let b = SignalBarsBlob(entries: [entry(id: 1, rxSnrX4: 10)])
    #expect(a == b)
    let c = SignalBarsBlob(entries: [entry(id: 2, rxSnrX4: 10)])
    #expect(a != c)
  }
}
