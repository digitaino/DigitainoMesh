import Foundation

/// Wire-format snapshot of the firmware's live repeater signal table, fetched via
/// ``SyncID/signalBars`` on Digitaino custom firmware.
///
/// The device builds this on demand from its in-memory `_signals[]` table (it is
/// *not* persisted to flash), so every `getSync(.signalBars)` returns a fresh view.
///
/// ``SignalBarsService`` uses this in *viewer mode* (custom firmware present): the
/// app suppresses its own ping engine and simply mirrors this table, so the OLED
/// and the app show identical bars with zero duplicate RF traffic.
///
/// Binary layout (matches firmware `AbstractUITask::serializeSignalBars`):
/// `[version][count]` then `count` × `{ id, rx_x4, tx_x4, flags, age_s(LE), rtt_ms(LE) }`
/// where `flags`: bit0 `has_rx` · bit1 `has_tx` · bit2 `tx_failed` · bit3 `is_best`.
public struct SignalBarsBlob: Sendable, Equatable {

    /// One tracked repeater as reported by the firmware.
    public struct Entry: Sendable, Equatable {
        /// First byte of the repeater hash — the match/ping key and what the OLED shows.
        public let id: UInt8
        /// Full advertised repeater hash (1-3 bytes) for display; empty falls back to `[id]`.
        public let idHash: [UInt8]
        /// RX SNR in 0.25 dB steps (how well *we* hear *them*).
        public let rxSnrX4: Int8
        /// TX SNR in 0.25 dB steps (how well *they* hear *us*).
        public let txSnrX4: Int8
        public let hasRx: Bool
        public let hasTx: Bool
        /// A ping was attempted but failed (firmware draws "X").
        public let txFailed: Bool
        /// Firmware's chosen best repeater (computed with the shared scorer).
        public let isBest: Bool
        /// Seconds since the repeater was last heard.
        public let ageSeconds: UInt16
        /// Last ping round-trip in ms (0 = unknown).
        public let rttMs: UInt16

        public init(id: UInt8, idHash: [UInt8] = [], rxSnrX4: Int8, txSnrX4: Int8,
                    hasRx: Bool, hasTx: Bool, txFailed: Bool, isBest: Bool,
                    ageSeconds: UInt16, rttMs: UInt16) {
            self.id = id
            self.idHash = idHash
            self.rxSnrX4 = rxSnrX4
            self.txSnrX4 = txSnrX4
            self.hasRx = hasRx
            self.hasTx = hasTx
            self.txFailed = txFailed
            self.isBest = isBest
            self.ageSeconds = ageSeconds
            self.rttMs = rttMs
        }

        /// RX SNR in dB, or `nil` if no RX data.
        public var rxSnr: Double? { hasRx ? Double(rxSnrX4) / 4.0 : nil }
        /// TX SNR in dB, or `nil` if no TX measurement.
        public var txSnr: Double? { hasTx ? Double(txSnrX4) / 4.0 : nil }
        /// Hex repeater id at the advertised hash size (e.g. "0C", "0C13", "0C13AB").
        public var hexID: String {
            (idHash.isEmpty ? [id] : idHash).map { String(format: "%02X", $0) }.joined()
        }
    }

    /// Schema version for forward compatibility (currently `1`).
    public var version: UInt8

    /// Tracked repeaters, in the firmware's table order.
    public var entries: [Entry]

    public init(version: UInt8 = 1, entries: [Entry] = []) {
        self.version = version
        self.entries = entries
    }

    // MARK: - Decoding

    /// Parses a blob previously fetched via `getSync(.signalBars)`.
    /// Tolerant of truncation: stops at the last whole entry the bytes allow.
    public init?(decoding data: Data) {
        guard data.count >= 2 else { return nil }
        let bytes = [UInt8](data)
        let version = bytes[0]
        let count = Int(bytes[1])
        var entries: [Entry] = []
        entries.reserveCapacity(count)
        var i = 2
        if version >= 2 {
            // v2 entry (11 bytes): id_len, h0, h1, h2, rx, tx, flags, age(LE), rtt(LE)
            for _ in 0..<count {
                guard i + 11 <= bytes.count else { break }
                let n = max(1, min(Int(bytes[i]), 3))
                let idHash = Array(bytes[(i + 1)...(i + n)])   // h0..h(n-1)
                let flags = bytes[i + 6]
                entries.append(Entry(
                    id: bytes[i + 1],
                    idHash: idHash,
                    rxSnrX4: Int8(bitPattern: bytes[i + 4]),
                    txSnrX4: Int8(bitPattern: bytes[i + 5]),
                    hasRx: flags & 0x01 != 0,
                    hasTx: flags & 0x02 != 0,
                    txFailed: flags & 0x04 != 0,
                    isBest: flags & 0x08 != 0,
                    ageSeconds: UInt16(bytes[i + 7]) | (UInt16(bytes[i + 8]) << 8),
                    rttMs: UInt16(bytes[i + 9]) | (UInt16(bytes[i + 10]) << 8)
                ))
                i += 11
            }
        } else {
            // v1 entry (8 bytes): id, rx, tx, flags, age(LE), rtt(LE)
            for _ in 0..<count {
                guard i + 8 <= bytes.count else { break }
                let flags = bytes[i + 3]
                entries.append(Entry(
                    id: bytes[i],
                    rxSnrX4: Int8(bitPattern: bytes[i + 1]),
                    txSnrX4: Int8(bitPattern: bytes[i + 2]),
                    hasRx: flags & 0x01 != 0,
                    hasTx: flags & 0x02 != 0,
                    txFailed: flags & 0x04 != 0,
                    isBest: flags & 0x08 != 0,
                    ageSeconds: UInt16(bytes[i + 4]) | (UInt16(bytes[i + 5]) << 8),
                    rttMs: UInt16(bytes[i + 6]) | (UInt16(bytes[i + 7]) << 8)
                ))
                i += 8
            }
        }
        self.init(version: version, entries: entries)
    }

    // MARK: - Encoding (round-trip / tests)

    /// Serializes to the firmware wire format. The device is normally the producer;
    /// the app only decodes — this exists mainly for round-trip tests.
    public func encode() -> Data {
        var out = Data()
        out.append(2)   // version 2
        let items = Array(entries.prefix(255))
        out.append(UInt8(items.count))
        for e in items {
            let hash = Array((e.idHash.isEmpty ? [e.id] : e.idHash).prefix(3))
            out.append(UInt8(hash.count))
            out.append(hash.count > 0 ? hash[0] : e.id)
            out.append(hash.count > 1 ? hash[1] : 0)
            out.append(hash.count > 2 ? hash[2] : 0)
            out.append(UInt8(bitPattern: e.rxSnrX4))
            out.append(UInt8(bitPattern: e.txSnrX4))
            var flags: UInt8 = 0
            if e.hasRx { flags |= 0x01 }
            if e.hasTx { flags |= 0x02 }
            if e.txFailed { flags |= 0x04 }
            if e.isBest { flags |= 0x08 }
            out.append(flags)
            out.append(UInt8(e.ageSeconds & 0xFF))
            out.append(UInt8(e.ageSeconds >> 8))
            out.append(UInt8(e.rttMs & 0xFF))
            out.append(UInt8(e.rttMs >> 8))
        }
        return out
    }

    // MARK: - Shared best-link scoring

    /// SNR (dB) at/below which a direction counts as "dead" — matches the firmware's
    /// weak-leg guard (`-40` in x4 units).
    public static let weakLegThreshold: Double = -10.0

    /// The unified best-link score, identical to the firmware's `signalScore`.
    ///
    /// Bidirectional links score `0.6·TX + 0.4·RX`, **unless** either leg is
    /// ≤ -10 dB — then the link is ranked by its dead leg (weak-leg guard), so a
    /// one-way-broken link can never be crowned "best". Unidirectional links score
    /// by their one available direction.
    ///
    /// Used by ``SignalBarsService`` engine mode (stock firmware) to pick the best
    /// repeater the same way the device does; viewer mode trusts the device's
    /// `is_best` flag directly.
    public static func score(rxSnr: Double?, txSnr: Double?) -> Double {
        if let rx = rxSnr, let tx = txSnr {
            let weak = Swift.min(rx, tx)
            if weak <= weakLegThreshold { return weak }
            return tx * 0.6 + rx * 0.4
        }
        if let rx = rxSnr { return rx }
        if let tx = txSnr { return tx }
        return -999
    }
}
