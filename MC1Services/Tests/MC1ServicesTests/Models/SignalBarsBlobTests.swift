import Testing
import Foundation
@testable import MC1Services

@Suite("SignalBarsBlob")
struct SignalBarsBlobTests {

    private func entry(
        id: UInt8 = 0,
        rxSnrX4: Int8 = 0,
        txSnrX4: Int8 = 0,
        hasRx: Bool = true,
        hasTx: Bool = true,
        txFailed: Bool = false,
        isBest: Bool = false,
        ageSeconds: UInt16 = 0,
        rttMs: UInt16 = 0
    ) -> SignalBarsBlob.Entry {
        .init(id: id, rxSnrX4: rxSnrX4, txSnrX4: txSnrX4,
              hasRx: hasRx, hasTx: hasTx, txFailed: txFailed, isBest: isBest,
              ageSeconds: ageSeconds, rttMs: rttMs)
    }

    // MARK: - Encoding wire layout

    @Test("Empty blob encodes to 2 bytes: version, count")
    func encodeEmpty() {
        let data = SignalBarsBlob().encode()
        #expect(data.count == 2)
        #expect(data[0] == 1)   // version
        #expect(data[1] == 0)   // count
    }

    @Test("One entry encodes header + 8 bytes with correct fields, flags, and LE values")
    func encodeOneEntry() {
        let blob = SignalBarsBlob(entries: [
            entry(id: 0x0C, rxSnrX4: 40, txSnrX4: -20, hasRx: true, hasTx: true,
                  txFailed: false, isBest: true, ageSeconds: 300, rttMs: 1234)
        ])
        let data = blob.encode()
        #expect(data.count == 2 + 8)
        #expect(data[0] == 1)                          // version
        #expect(data[1] == 1)                          // count
        #expect(data[2] == 0x0C)                       // id
        #expect(data[3] == UInt8(bitPattern: 40))      // rx_x4
        #expect(data[4] == UInt8(bitPattern: -20))     // tx_x4 (236)
        #expect(data[5] == (0x01 | 0x02 | 0x08))       // has_rx | has_tx | is_best
        #expect(data[6] == UInt8(300 & 0xFF))          // age lo (0x2C)
        #expect(data[7] == UInt8(300 >> 8))            // age hi (0x01)
        #expect(data[8] == UInt8(1234 & 0xFF))         // rtt lo (0xD2)
        #expect(data[9] == UInt8(1234 >> 8))           // rtt hi (0x04)
    }

    // MARK: - Round-trip

    @Test("encode -> decode round-trip preserves all entries")
    func roundTrip() throws {
        let entries = [
            entry(id: 1, rxSnrX4: 44, txSnrX4: 20, hasRx: true, hasTx: true,
                  txFailed: false, isBest: true, ageSeconds: 5, rttMs: 800),
            entry(id: 0xFF, rxSnrX4: -40, txSnrX4: 0, hasRx: true, hasTx: false,
                  txFailed: true, isBest: false, ageSeconds: 65535, rttMs: 0)
        ]
        let data = SignalBarsBlob(entries: entries).encode()
        let decoded = try #require(SignalBarsBlob(decoding: data))
        #expect(decoded.version == 1)
        #expect(decoded.entries == entries)
    }

    @Test("Flags and signed SNR decode correctly")
    func decodeFlagsAndSign() throws {
        // id=0x07, rx=-1 (0xFF), tx=0, flags = has_rx | tx_failed (0x05), age=0, rtt=0
        let data = Data([1, 1, 0x07, 0xFF, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00])
        let e = try #require(SignalBarsBlob(decoding: data)).entries.first
        let entry = try #require(e)
        #expect(entry.id == 0x07)
        #expect(entry.rxSnrX4 == -1)
        #expect(entry.hasRx == true)
        #expect(entry.hasTx == false)
        #expect(entry.txFailed == true)
        #expect(entry.isBest == false)
    }

    // MARK: - Decode tolerance

    @Test("Decoding rejects payloads too short for the header")
    func decodeTooShort() {
        #expect(SignalBarsBlob(decoding: Data()) == nil)
        #expect(SignalBarsBlob(decoding: Data([1])) == nil)
    }

    @Test("Decoding stops gracefully on a truncated trailing entry")
    func decodeTruncated() throws {
        // count says 2, but only one full 8-byte entry + a 2-byte stub follow
        var data = Data([1, 2])
        data.append(contentsOf: [0x0C, 40, 20, 0x03, 0x05, 0x00, 0xD2, 0x04]) // full entry
        data.append(contentsOf: [0x0D, 10])                                     // partial
        let decoded = try #require(SignalBarsBlob(decoding: data))
        #expect(decoded.entries.count == 1)
        #expect(decoded.entries[0].id == 0x0C)
    }

    // MARK: - Computed accessors

    @Test("rxSnr / txSnr convert from x4 and respect has_rx/has_tx")
    func computedSnr() {
        let e = entry(rxSnrX4: 40, txSnrX4: -8, hasRx: true, hasTx: true)
        #expect(e.rxSnr == 10.0)    // 40 / 4
        #expect(e.txSnr == -2.0)    // -8 / 4

        let none = entry(rxSnrX4: 40, txSnrX4: 40, hasRx: false, hasTx: false)
        #expect(none.rxSnr == nil)
        #expect(none.txSnr == nil)
    }

    @Test("hexID is two-digit uppercase hex")
    func hexID() {
        #expect(entry(id: 0x0C).hexID == "0C")
        #expect(entry(id: 0xAB).hexID == "AB")
        #expect(entry(id: 5).hexID == "05")
    }

    // MARK: - Shared best-link scorer

    @Test("Bidirectional score is 0.6*TX + 0.4*RX")
    func scoreBlend() {
        // rx=10, tx=20 -> 12 + 4 = 16
        #expect(abs(SignalBarsBlob.score(rxSnr: 10, txSnr: 20) - 16.0) < 0.0001)
    }

    @Test("Blend favors TX over RX")
    func scoreFavorsTX() {
        let strongRx = SignalBarsBlob.score(rxSnr: 20, txSnr: 0)   // 8
        let strongTx = SignalBarsBlob.score(rxSnr: 0, txSnr: 20)   // 12
        #expect(strongTx > strongRx)
    }

    @Test("Weak-leg guard: a dead direction (<= -10 dB) ranks the link by that leg")
    func scoreWeakLegGuard() {
        // RX dead, TX great -> ranked by RX (-12), not the blend
        #expect(SignalBarsBlob.score(rxSnr: -12, txSnr: 20) == -12)
        // TX dead, RX fine -> ranked by TX (-15)
        #expect(SignalBarsBlob.score(rxSnr: 8, txSnr: -15) == -15)
        // Boundary: exactly -10 triggers the guard (<=)
        #expect(SignalBarsBlob.score(rxSnr: -10, txSnr: 20) == -10)
    }

    @Test("Unidirectional and empty scores")
    func scoreUnidirectional() {
        #expect(SignalBarsBlob.score(rxSnr: 7, txSnr: nil) == 7)
        #expect(SignalBarsBlob.score(rxSnr: nil, txSnr: 5) == 5)
        #expect(SignalBarsBlob.score(rxSnr: nil, txSnr: nil) == -999)
    }

    // MARK: - Equatable

    @Test("Equal blobs compare equal")
    func equatable() {
        let a = SignalBarsBlob(entries: [entry(id: 1, rxSnrX4: 10)])
        let b = SignalBarsBlob(entries: [entry(id: 1, rxSnrX4: 10)])
        #expect(a == b)
        let c = SignalBarsBlob(entries: [entry(id: 2, rxSnrX4: 10)])
        #expect(a != c)
    }
}
