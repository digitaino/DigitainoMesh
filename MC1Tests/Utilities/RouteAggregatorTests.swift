import CoreLocation
import Foundation
import Testing
@testable import MC1

// MARK: - Hop Hash Parsing

@Suite("RouteAggregator Hop Hash Parsing")
struct RouteAggregatorHopHashParsingTests {

    @Test("parseHopHashes splits data into correct chunks")
    func splitsDataIntoChunks() {
        let data = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
        let hashes = RouteAggregator.parseHopHashes(pathNodes: data, hashSize: 2)

        #expect(hashes.count == 3)
        #expect(hashes[0] == Data([0x01, 0x02]))
        #expect(hashes[1] == Data([0x03, 0x04]))
        #expect(hashes[2] == Data([0x05, 0x06]))
    }

    @Test("parseHopHashes handles data not evenly divisible by hashSize")
    func handlesUnevenData() {
        let data = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let hashes = RouteAggregator.parseHopHashes(pathNodes: data, hashSize: 2)

        #expect(hashes.count == 3)
        #expect(hashes[2] == Data([0x05]))
    }

    @Test("parseHopHashes returns empty for empty data")
    func emptyDataReturnsEmpty() {
        let hashes = RouteAggregator.parseHopHashes(pathNodes: Data(), hashSize: 4)
        #expect(hashes.isEmpty)
    }

    @Test("parseHopHashes returns empty for zero hashSize")
    func zeroHashSizeReturnsEmpty() {
        let data = Data([0x01, 0x02])
        let hashes = RouteAggregator.parseHopHashes(pathNodes: data, hashSize: 0)
        #expect(hashes.isEmpty)
    }

    @Test("parseHopHashes returns single chunk when hashSize equals data length")
    func singleChunk() {
        let data = Data([0x01, 0x02, 0x03])
        let hashes = RouteAggregator.parseHopHashes(pathNodes: data, hashSize: 3)

        #expect(hashes.count == 1)
        #expect(hashes[0] == data)
    }
}

// MARK: - Aggregation

@Suite("RouteAggregator Aggregation")
struct RouteAggregatorAggregationTests {

    private func makeHop(key: UInt8, lat: Double = 52.0, lon: Double = 5.0, name: String = "Node") -> RouteAggregator.LocatedHop {
        RouteAggregator.LocatedHop(
            publicKey: Data([key]),
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            name: name
        )
    }

    @Test("aggregate with empty routes produces empty result")
    func emptyRoutesProduceEmptyResult() {
        let result = RouteAggregator.aggregate(routes: [], directional: false)

        #expect(result.bubbleAnnotations.isEmpty)
        #expect(result.segmentData.isEmpty)
        #expect(result.locatedRepeaterCount == 0)
        #expect(result.segmentCount == 0)
    }

    @Test("aggregate with single hop route produces bubble but no segments")
    func singleHopProducesBubbleNoSegments() {
        let hop = makeHop(key: 0x01, name: "Relay-A")
        let routes: [(hops: [RouteAggregator.LocatedHop], snr: Double?, direction: RouteAggregator.RouteDirection)] = [
            (hops: [hop], snr: -5.0, direction: .unspecified)
        ]

        let result = RouteAggregator.aggregate(routes: routes, directional: false)

        #expect(result.locatedRepeaterCount == 1)
        #expect(result.segmentCount == 0)
        #expect(result.bubbleAnnotations.count == 1)
        #expect(result.segmentData.isEmpty)
    }

    @Test("aggregate with empty hop array does not crash")
    func emptyHopArrayDoesNotCrash() {
        let routes: [(hops: [RouteAggregator.LocatedHop], snr: Double?, direction: RouteAggregator.RouteDirection)] = [
            (hops: [], snr: nil, direction: .unspecified)
        ]

        let result = RouteAggregator.aggregate(routes: routes, directional: false)

        #expect(result.locatedRepeaterCount == 0)
        #expect(result.segmentCount == 0)
    }

    @Test("aggregate with two hops produces one segment")
    func twoHopsProduceOneSegment() {
        let hopA = makeHop(key: 0x01, lat: 52.0, lon: 5.0, name: "A")
        let hopB = makeHop(key: 0x02, lat: 52.1, lon: 5.1, name: "B")
        let routes: [(hops: [RouteAggregator.LocatedHop], snr: Double?, direction: RouteAggregator.RouteDirection)] = [
            (hops: [hopA, hopB], snr: 10.0, direction: .outbound)
        ]

        let result = RouteAggregator.aggregate(routes: routes, directional: false)

        #expect(result.locatedRepeaterCount == 2)
        #expect(result.segmentCount == 1)
        #expect(result.bubbleAnnotations.count == 2)
        #expect(result.segmentData.count == 1)
    }

    @Test("aggregate with three hops produces two segments")
    func threeHopsProduceTwoSegments() {
        let hopA = makeHop(key: 0x01, lat: 52.0, lon: 5.0, name: "A")
        let hopB = makeHop(key: 0x02, lat: 52.1, lon: 5.1, name: "B")
        let hopC = makeHop(key: 0x03, lat: 52.2, lon: 5.2, name: "C")
        let routes: [(hops: [RouteAggregator.LocatedHop], snr: Double?, direction: RouteAggregator.RouteDirection)] = [
            (hops: [hopA, hopB, hopC], snr: nil, direction: .inbound)
        ]

        let result = RouteAggregator.aggregate(routes: routes, directional: false)

        #expect(result.locatedRepeaterCount == 3)
        #expect(result.segmentCount == 2)
    }

    @Test("aggregate skips self-loop segments")
    func skipsSelfLoopSegments() {
        let hop = makeHop(key: 0x01, name: "A")
        let routes: [(hops: [RouteAggregator.LocatedHop], snr: Double?, direction: RouteAggregator.RouteDirection)] = [
            (hops: [hop, hop], snr: nil, direction: .unspecified)
        ]

        let result = RouteAggregator.aggregate(routes: routes, directional: false)

        #expect(result.locatedRepeaterCount == 1)
        #expect(result.segmentCount == 0)
    }

    @Test("aggregate non-directional canonicalizes A→B and B→A into one segment")
    func nonDirectionalCanonicalizesSegments() {
        let hopA = makeHop(key: 0x01, lat: 52.0, lon: 5.0, name: "A")
        let hopB = makeHop(key: 0x02, lat: 52.1, lon: 5.1, name: "B")
        let routes: [(hops: [RouteAggregator.LocatedHop], snr: Double?, direction: RouteAggregator.RouteDirection)] = [
            (hops: [hopA, hopB], snr: nil, direction: .outbound),
            (hops: [hopB, hopA], snr: nil, direction: .inbound)
        ]

        let result = RouteAggregator.aggregate(routes: routes, directional: false)

        #expect(result.segmentCount == 1)
        #expect(result.segmentData.first?.frequency == 2)
    }

    @Test("aggregate directional keeps A→B and B→A as separate segments")
    func directionalKeepsSeparateSegments() {
        let hopA = makeHop(key: 0x01, lat: 52.0, lon: 5.0, name: "A")
        let hopB = makeHop(key: 0x02, lat: 52.1, lon: 5.1, name: "B")
        let routes: [(hops: [RouteAggregator.LocatedHop], snr: Double?, direction: RouteAggregator.RouteDirection)] = [
            (hops: [hopA, hopB], snr: nil, direction: .outbound),
            (hops: [hopB, hopA], snr: nil, direction: .inbound)
        ]

        let result = RouteAggregator.aggregate(routes: routes, directional: true)

        #expect(result.segmentCount == 2)
    }

    @Test("aggregate accumulates packet count for repeated nodes")
    func accumulatesPacketCount() {
        let hop = makeHop(key: 0x01, name: "Relay")
        let routes: [(hops: [RouteAggregator.LocatedHop], snr: Double?, direction: RouteAggregator.RouteDirection)] = [
            (hops: [hop], snr: nil, direction: .unspecified),
            (hops: [hop], snr: nil, direction: .unspecified),
            (hops: [hop], snr: nil, direction: .unspecified)
        ]

        let result = RouteAggregator.aggregate(routes: routes, directional: false)

        #expect(result.locatedRepeaterCount == 1)
        #expect(result.bubbleAnnotations.first?.packetCount == 3)
    }

    @Test("aggregate with mix of empty and populated routes does not crash")
    func mixedEmptyAndPopulatedRoutes() {
        let hopA = makeHop(key: 0x01, name: "A")
        let hopB = makeHop(key: 0x02, lat: 52.1, lon: 5.1, name: "B")
        let routes: [(hops: [RouteAggregator.LocatedHop], snr: Double?, direction: RouteAggregator.RouteDirection)] = [
            (hops: [], snr: nil, direction: .unspecified),
            (hops: [hopA], snr: -3.0, direction: .outbound),
            (hops: [], snr: nil, direction: .inbound),
            (hops: [hopA, hopB], snr: 8.0, direction: .outbound)
        ]

        let result = RouteAggregator.aggregate(routes: routes, directional: false)

        #expect(result.locatedRepeaterCount == 2)
        #expect(result.segmentCount == 1)
    }
}
