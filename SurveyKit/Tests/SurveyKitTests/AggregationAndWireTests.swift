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
        // Two samples on one UTC day, one on the next.
        let day1a = sample(at: 0, snr: 5)
        let day1b = sample(at: 60, snr: 5)
        let day2 = sample(at: 24 * 60, snr: 5)
        let cells = CellAggregator.aggregate([day1a, day1b, day2])
        let cell = try #require(cells.values.first)

        #expect(cell.dailyCounts.count == 2)
        #expect(cell.dailyCounts.values.sorted() == [1, 2])
        #expect(cell.earliest == day1a.timestamp)
        #expect(cell.latest == day2.timestamp)

        let wire = cell.wireCell { id in
            UploadV2RepeaterObservation(kind: "prefix", prefixB64: id, packetCount: 0)
        }
        let range = try #require(wire.timeRange)
        #expect(range.earliest.hasPrefix("2026"))
        #expect(wire.dailyCounts?.count == 2)
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

@Suite("Wire & validation")
struct WireTests {

    private func minimalPayload(receipt: String? = "cmVjZWlwdA==") -> UploadV2Payload {
        let cell = SurveyGrid.cell(containing: GeoCoordinate(latitude: 30.2672, longitude: -97.7431))!
        return UploadV2Payload(
            receiptB64: receipt,
            mode: "batch",
            cells: [
                UploadV2Cell(
                    h3: cell.stringValue,
                    snr: UploadV2SnrStats(avg: 7.5, min: 2, max: 12),
                    packetCount: 4,
                    routeBreakdown: UploadV2RouteBreakdown(flood: 3, direct: 1),
                    repeaters: []
                )
            ]
        )
    }

    @Test func wireFieldNamesAreLocked() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(minimalPayload())
        let json = String(decoding: data, as: UTF8.self)
        // Snake-case contract with the server — a rename here is an API break.
        #expect(json.contains("\"h3_resolution\":10"))
        #expect(json.contains("\"receipt_b64\""))
        #expect(json.contains("\"packet_count\":4"))
        #expect(json.contains("\"route_breakdown\""))
        #expect(json.contains("\"version\":\"2.2\""))
        #expect(!json.contains("\"contributor\""))     // anonymous by default
    }

    @Test func validationAcceptsGoodAndRejectsBad() {
        #expect(SurveyLimits.validate(minimalPayload()) == nil)

        // Anonymous without a receipt: no deletion handle → rejected.
        #expect(SurveyLimits.validate(minimalPayload(receipt: nil)) == .missingIdentity)

        var badH3 = minimalPayload()
        badH3.cells[0].h3 = "zzzz"
        #expect(SurveyLimits.validate(badH3) == .invalidH3(cellIndex: 0, value: "zzzz"))

        var badSnr = minimalPayload()
        badSnr.cells[0].snr.avg = 250
        #expect(SurveyLimits.validate(badSnr) == .implausibleSnr(cellIndex: 0, value: 250))

        // Res 7 is coarser than the system accepts.
        var badRes = minimalPayload()
        let res7 = SurveyGrid.cell(
            containing: GeoCoordinate(latitude: 30.2672, longitude: -97.7431),
            resolution: 7
        )!
        badRes.cells[0].h3 = res7.stringValue
        #expect(SurveyLimits.validate(badRes) == .unsupportedResolution(cellIndex: 0, resolution: 7))

        // Coarse-tier res 8 cells are fine.
        var res8 = minimalPayload()
        let cell8 = SurveyGrid.cell(
            containing: GeoCoordinate(latitude: 30.2672, longitude: -97.7431),
            resolution: 8
        )!
        res8.cells[0].h3 = cell8.stringValue
        #expect(SurveyLimits.validate(res8) == nil)
    }

    @Test func requestSignerRoundTripsAndRejectsTampering() {
        let key = "test-key"
        let body = Data("{\"cells\":[]}".utf8)
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let ts = String(Int(now.timeIntervalSince1970))
        let sig = RequestSigner.signature(key: key, timestamp: ts, body: body)

        #expect(RequestSigner.verify(key: key, timestamp: ts, body: body, signatureHex: sig, now: now))
        #expect(!RequestSigner.verify(key: "other", timestamp: ts, body: body, signatureHex: sig, now: now))
        #expect(!RequestSigner.verify(key: key, timestamp: ts, body: Data("x".utf8), signatureHex: sig, now: now))
        // Outside the replay window.
        let late = now.addingTimeInterval(RequestSigner.replayWindow + 1)
        #expect(!RequestSigner.verify(key: key, timestamp: ts, body: body, signatureHex: sig, now: late))
    }
}
