import Foundation
import Testing
@testable import SurveyKit

@Suite("CellAggregator")
struct CellAggregatorTests {

    private func sample(
        at minute: Int,
        snr: Double?,
        txSnr: Double? = nil,
        active: Bool = false,
        hops: Int? = 0,
        repeaters: [SurveySample.RepeaterSighting] = []
    ) -> SurveySample {
        SurveySample(
            timestamp: Date(timeIntervalSince1970: 1_780_000_000 + TimeInterval(minute * 60)),
            coordinate: GeoCoordinate(latitude: 30.2672, longitude: -97.7431),
            snr: snr,
            txSnr: txSnr,
            rssi: -90,
            route: .flood,
            isActiveProbe: active,
            hopCount: hops,
            repeaters: repeaters
        )
    }

    @Test func aggregatesDirectionalRepeaterStats() throws {
        let samples = [
            // We heard repeater A twice…
            sample(at: 0, snr: 8, repeaters: [.init(id: "aabbcc", rxSnr: 8, rssi: -88)]),
            sample(at: 1, snr: 12, repeaters: [.init(id: "aabbcc", rxSnr: 12, rssi: -84)]),
            // …and A heard us once (discover response with TX SNR).
            sample(at: 2, snr: nil, txSnr: 6, active: true, repeaters: [.init(id: "aabbcc", txSnr: 6)]),
        ]
        let cells = CellAggregator.aggregate(samples)
        let cell = try #require(cells.values.first)
        #expect(cells.count == 1)
        #expect(cell.packetCount == 3)
        #expect(cell.activePacketCount == 1)
        #expect(cell.passivePacketCount == 2)

        let repeater = try #require(cell.repeaters["aabbcc"])
        #expect(repeater.rxPacketCount == 2)
        #expect(repeater.txPacketCount == 1)
        #expect(repeater.avgRxSnr == 10)
        #expect(repeater.avgTxSnr == 6)
        #expect(repeater.firstHeard < repeater.lastHeard)
    }

    // MARK: - The packet split: hearing, being heard, and merely being on the path

    /// A probe reply carries both legs at once — "here is my reading of you", in a packet we
    /// measured ourselves. The old either/or booked it as TX only and lost the RX half.
    @Test func bothLegsOfOneSightingAreCountedSeparately() throws {
        let samples = [
            sample(at: 0, snr: 9, txSnr: 5, active: true, repeaters: [
                .init(id: "aabbcc", rxSnr: 9, txSnr: 5, rssi: -70)
            ])
        ]
        let cells = CellAggregator.aggregate(samples)
        let repeater = try #require(cells.values.first?.repeaters["aabbcc"])

        #expect(repeater.rxPacketCount == 1)
        #expect(repeater.txPacketCount == 1)
        #expect(repeater.packetCount == 2)
        #expect(repeater.relayCount == 0)
        #expect(repeater.rxSnrCount == 1)
        #expect(repeater.txSnrCount == 1)
    }

    /// An upstream hop: on the path, measured by somebody else. Real evidence of reach
    /// *through* the mesh, and not a packet either of us heard.
    @Test func aSignallessHopCountsAsRelayOnly() throws {
        let samples = [
            sample(at: 0, snr: 6, repeaters: [
                .init(id: "0c"),
                .init(id: "42", rxSnr: 6, rssi: -80)
            ])
        ]
        let cells = CellAggregator.aggregate(samples)
        let cell = try #require(cells.values.first)

        let upstream = try #require(cell.repeaters["0c"])
        #expect(upstream.relayCount == 1)
        #expect(upstream.rxPacketCount == 0)
        #expect(upstream.txPacketCount == 0)
        #expect(upstream.packetCount == 0, "path membership is not a packet count")
        #expect(upstream.lastDirectHeard == nil)
        #expect(upstream.lastHeard == samples[0].timestamp, "it did appear in a path")

        let lastHop = try #require(cell.repeaters["42"])
        #expect(lastHop.relayCount == 0)
        #expect(lastHop.packetCount == 1)
    }

    // MARK: - Freshness

    @Test func lastDirectReadingIsThePairFromTheLatestSighting() throws {
        // Strongest reading first, then a weaker but later one, then an out-of-order older
        // one: "strongest now" must read the *latest* pair, and folding history in the wrong
        // order must not pair a new instant with an old number.
        let strongEarly = sample(at: 0, snr: 12, repeaters: [.init(id: "42", rxSnr: 12)])
        let weakLate = sample(at: 10, snr: 2, repeaters: [.init(id: "42", rxSnr: 2)])
        let outOfOrder = sample(at: 5, snr: 8, repeaters: [.init(id: "42", rxSnr: 8)])

        var cell = AggregatedCell(cell: try #require(
            SurveyGrid.cell(containing: GeoCoordinate(latitude: 30.2672, longitude: -97.7431))
        ))
        CellAggregator.fold(strongEarly, into: &cell)
        CellAggregator.fold(weakLate, into: &cell)
        CellAggregator.fold(outOfOrder, into: &cell)

        let repeater = try #require(cell.repeaters["42"])
        #expect(repeater.lastDirectHeard == weakLate.timestamp)
        #expect(repeater.lastRxSnr == 2)
        #expect(repeater.maxRxSnr == 12, "the best reading is still kept, just not as the current one")
        #expect(repeater.rxSnrCount == 3)
    }

    /// Our own packet came back through this node: it heard our radio, without ever saying
    /// with what SNR.
    @Test func anEchoFirstHopProvesTheUplink() throws {
        let echo = sample(at: 0, snr: 7, repeaters: [
            .init(id: "0c", isEcho: true),
            .init(id: "42", rxSnr: 7)
        ])
        let cells = CellAggregator.aggregate([echo])
        let cell = try #require(cells.values.first)

        let firstHop = try #require(cell.repeaters["0c"])
        #expect(firstHop.echoCount == 1)
        #expect(firstHop.lastUplinkAt == echo.timestamp)
        #expect(firstHop.lastDirectHeard == nil, "it heard us; we never measured it")
        #expect(firstHop.txSnrCount == 0, "an echo is not a reported reading")

        let lastHop = try #require(cell.repeaters["42"])
        #expect(lastHop.echoCount == 0)
        #expect(lastHop.lastUplinkAt == nil, "the hop that reached *us* proves nothing about the uplink")
    }

    @Test func aReportedTxReadingProvesTheUplink() throws {
        let reply = sample(at: 3, snr: nil, txSnr: 4, active: true, repeaters: [
            .init(id: "42", txSnr: 4)
        ])
        let cells = CellAggregator.aggregate([reply])
        let repeater = try #require(cells.values.first?.repeaters["42"])

        #expect(repeater.lastUplinkAt == reply.timestamp)
        #expect(repeater.echoCount == 0)
        #expect(repeater.lastDirectHeard == nil)
    }

    @Test func keepsTimeDataAtFullFidelity() throws {
        // Two samples on one UTC day, one on the next. Local aggregates keep full
        // time fidelity; day-bucketing to the privacy rules happens at the wire
        // boundary (wire v3, M2).
        let day1a = sample(at: 0, snr: 5)
        let day1b = sample(at: 60, snr: 5)
        let day2 = sample(at: 24 * 60, snr: 5)
        let cells = CellAggregator.aggregate([day1a, day1b, day2])
        let cell = try #require(cells.values.first)

        #expect(cell.dailyCounts.count == 2)
        #expect(cell.dailyCounts.values.sorted() == [1, 2])
        #expect(cell.earliest == day1a.timestamp)
        #expect(cell.latest == day2.timestamp)
    }

    @Test func bucketsAtBaseResolution() throws {
        let cells = CellAggregator.aggregate([sample(at: 0, snr: 5)])
        let cell = try #require(cells.keys.first)
        #expect(cell.resolution == SurveyGrid.baseResolution)
    }

    @Test func deadZoneNeedsProbesAndSilence() {
        guard let cell = SurveyGrid.cell(containing: GeoCoordinate(latitude: 30, longitude: -97)) else {
            Issue.record("cell derivation failed")
            return
        }
        var aggregate = AggregatedCell(cell: cell)
        #expect(!aggregate.isDeadZone)         // never probed → just unexplored
        aggregate.probesSent = 2
        #expect(aggregate.isDeadZone)          // probed, heard nothing
        CellAggregator.fold(sample(at: 0, snr: 3), into: &aggregate)
        #expect(!aggregate.isDeadZone)         // heard something after all
    }

    @Test func qualityScaleMatchesCanonicalThresholds() {
        #expect(SignalQuality(snr: 10) == .excellent)
        #expect(SignalQuality(snr: 9.9) == .good)
        #expect(SignalQuality(snr: 5) == .good)
        #expect(SignalQuality(snr: 0) == .fair)
        #expect(SignalQuality(snr: -0.1) == .poor)
        #expect(SignalQuality(snr: -10) == .poor)
        #expect(SignalQuality(snr: -10.1) == .veryPoor)
        #expect(SignalQuality(snr: nil) == .unknown)
    }
}
