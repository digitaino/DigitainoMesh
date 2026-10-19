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
