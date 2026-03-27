import CoreLocation
import Foundation
import Testing
@testable import MC1
@testable import MC1Services

@Suite("RepeaterResolver")
struct RepeaterResolverTests {

    private func createRepeater(
        prefix: UInt8,
        secondByte: UInt8,
        name: String,
        lastAdvertTimestamp: UInt32,
        latitude: Double,
        longitude: Double
    ) -> ContactDTO {
        ContactDTO(
            id: UUID(),
            deviceID: UUID(),
            publicKey: Data([prefix, secondByte] + Array(repeating: UInt8(0), count: 30)),
            name: name,
            typeRawValue: ContactType.repeater.rawValue,
            flags: 0,
            outPathLength: 0,
            outPath: Data(),
            lastAdvertTimestamp: lastAdvertTimestamp,
            latitude: latitude,
            longitude: longitude,
            lastModified: 0,
            nickname: nil,
            isBlocked: false,
            isMuted: false,
            isFavorite: false,
            lastMessageDate: nil,
            unreadCount: 0
        )
    }

    @Test("prefers closest repeater when location available")
    func prefersClosestWithLocation() {
        let repeaterA = createRepeater(
            prefix: 0x3F,
            secondByte: 0x01,
            name: "Near",
            lastAdvertTimestamp: 10,
            latitude: 37.0,
            longitude: -122.0
        )
        let repeaterB = createRepeater(
            prefix: 0x3F,
            secondByte: 0x02,
            name: "Far",
            lastAdvertTimestamp: 200,
            latitude: 38.0,
            longitude: -123.0
        )

        let userLocation = CLLocation(latitude: 37.0005, longitude: -122.0005)
        let match = RepeaterResolver.bestMatch(for: Data([0x3F]), in: [repeaterA, repeaterB], userLocation: userLocation)

        #expect(match?.displayName == "Near")
    }

    @Test("exact match with full public key ignores proximity/recency")
    func exactMatchWithFullPublicKey() {
        let repeaterA = createRepeater(
            prefix: 0x3F,
            secondByte: 0x01,
            name: "Target",
            lastAdvertTimestamp: 10,
            latitude: 38.0,
            longitude: -123.0
        )
        let repeaterB = createRepeater(
            prefix: 0x3F,
            secondByte: 0x02,
            name: "Closer and Newer",
            lastAdvertTimestamp: 200,
            latitude: 37.0,
            longitude: -122.0
        )

        let userLocation = CLLocation(latitude: 37.0005, longitude: -122.0005)
        // PathHop with full key of repeaterA - should match exactly despite repeaterB being closer/newer
        let hop = PathHop(hashBytes: Data([0x3F]), publicKey: repeaterA.publicKey, resolvedName: "Target")
        let match = RepeaterResolver.bestMatch(for: hop, in: [repeaterA, repeaterB], userLocation: userLocation)

        #expect(match?.displayName == "Target")
    }

    @Test("PathHop without public key falls back to proximity/recency")
    func pathHopWithoutKeyFallsBackToProximity() {
        let repeaterA = createRepeater(
            prefix: 0x3F,
            secondByte: 0x01,
            name: "Far",
            lastAdvertTimestamp: 10,
            latitude: 38.0,
            longitude: -123.0
        )
        let repeaterB = createRepeater(
            prefix: 0x3F,
            secondByte: 0x02,
            name: "Near",
            lastAdvertTimestamp: 200,
            latitude: 37.0,
            longitude: -122.0
        )

        let userLocation = CLLocation(latitude: 37.0005, longitude: -122.0005)
        // PathHop with nil publicKey - should fall back to proximity match
        let hop = PathHop(hashBytes: Data([0x3F]), resolvedName: nil)
        let match = RepeaterResolver.bestMatch(for: hop, in: [repeaterA, repeaterB], userLocation: userLocation)

        #expect(match?.displayName == "Near")
    }

    @Test("PathHop with deleted contact key falls back to hash byte match")
    func pathHopWithDeletedContactFallsBack() {
        let repeaterA = createRepeater(
            prefix: 0x3F,
            secondByte: 0x01,
            name: "Only Match",
            lastAdvertTimestamp: 10,
            latitude: 0,
            longitude: 0
        )

        // PathHop has a key that doesn't match any current repeater (contact was deleted)
        let deletedKey = Data([0x3F, 0xFF] + Array(repeating: UInt8(0), count: 30))
        let hop = PathHop(hashBytes: Data([0x3F]), publicKey: deletedKey, resolvedName: "Deleted")
        let match = RepeaterResolver.bestMatch(for: hop, in: [repeaterA], userLocation: nil)

        // Falls back to hash byte match
        #expect(match?.displayName == "Only Match")
    }

    // MARK: - DiscoveredNodeDTO Tests

    private func createDiscoveredNode(
        prefix: UInt8,
        secondByte: UInt8,
        name: String,
        lastAdvertTimestamp: UInt32,
        lastHeard: Date = Date(),
        latitude: Double,
        longitude: Double
    ) -> DiscoveredNodeDTO {
        DiscoveredNodeDTO(
            id: UUID(),
            deviceID: UUID(),
            publicKey: Data([prefix, secondByte] + Array(repeating: UInt8(0), count: 30)),
            name: name,
            typeRawValue: ContactType.repeater.rawValue,
            lastHeard: lastHeard,
            lastAdvertTimestamp: lastAdvertTimestamp,
            latitude: latitude,
            longitude: longitude,
            outPathLength: 0,
            outPath: Data()
        )
    }

    @Test("prefers closest discovered node when location available")
    func prefersClosestDiscoveredNodeWithLocation() {
        let nodeA = createDiscoveredNode(
            prefix: 0x3F,
            secondByte: 0x01,
            name: "Near Node",
            lastAdvertTimestamp: 10,
            latitude: 37.0,
            longitude: -122.0
        )
        let nodeB = createDiscoveredNode(
            prefix: 0x3F,
            secondByte: 0x02,
            name: "Far Node",
            lastAdvertTimestamp: 200,
            latitude: 38.0,
            longitude: -123.0
        )

        let userLocation = CLLocation(latitude: 37.0005, longitude: -122.0005)
        let match = RepeaterResolver.bestMatch(for: Data([0x3F]), in: [nodeA, nodeB], userLocation: userLocation)

        #expect(match?.name == "Near Node")
    }

    @Test("prefers most recent discovered node without location")
    func prefersMostRecentDiscoveredNodeWithoutLocation() {
        let nodeA = createDiscoveredNode(
            prefix: 0x3F,
            secondByte: 0x01,
            name: "Older Node",
            lastAdvertTimestamp: 10,
            latitude: 0,
            longitude: 0
        )
        let nodeB = createDiscoveredNode(
            prefix: 0x3F,
            secondByte: 0x02,
            name: "Newer Node",
            lastAdvertTimestamp: 200,
            latitude: 0,
            longitude: 0
        )

        let match = RepeaterResolver.bestMatch(for: Data([0x3F]), in: [nodeA, nodeB], userLocation: nil)

        #expect(match?.name == "Newer Node")
    }

    @Test("exact match with full public key for discovered node PathHop variant")
    func exactMatchDiscoveredNodePathHop() {
        let nodeA = createDiscoveredNode(
            prefix: 0x3F,
            secondByte: 0x01,
            name: "Target Node",
            lastAdvertTimestamp: 10,
            latitude: 38.0,
            longitude: -123.0
        )
        let nodeB = createDiscoveredNode(
            prefix: 0x3F,
            secondByte: 0x02,
            name: "Closer and Newer",
            lastAdvertTimestamp: 200,
            latitude: 37.0,
            longitude: -122.0
        )

        let userLocation = CLLocation(latitude: 37.0005, longitude: -122.0005)
        let hop = PathHop(hashBytes: Data([0x3F]), publicKey: nodeA.publicKey, resolvedName: "Target Node")
        let match = RepeaterResolver.bestMatch(for: hop, in: [nodeA, nodeB], userLocation: userLocation)

        #expect(match?.name == "Target Node")
    }

    // MARK: - ContactDTO Tests

    @Test("prefers most recent when location unavailable")
    func prefersMostRecentWithoutLocation() {
        let repeaterA = createRepeater(
            prefix: 0x3F,
            secondByte: 0x01,
            name: "Older",
            lastAdvertTimestamp: 10,
            latitude: 0,
            longitude: 0
        )
        let repeaterB = createRepeater(
            prefix: 0x3F,
            secondByte: 0x02,
            name: "Newer",
            lastAdvertTimestamp: 200,
            latitude: 0,
            longitude: 0
        )

        let match = RepeaterResolver.bestMatch(for: Data([0x3F]), in: [repeaterA, repeaterB], userLocation: nil)

        #expect(match?.displayName == "Newer")
    }

    // MARK: - Anchor Location Tests

    @Test("anchor location overrides recency — prefers closer to anchor")
    func anchorOverridesRecency() {
        // NearAnchor is close to anchor but older, FarFromAnchor is far but newer
        let nearAnchor = createRepeater(
            prefix: 0x3F,
            secondByte: 0x01,
            name: "NearAnchor",
            lastAdvertTimestamp: 10,
            latitude: 37.001,
            longitude: -122.001
        )
        let farFromAnchor = createRepeater(
            prefix: 0x3F,
            secondByte: 0x02,
            name: "FarFromAnchor",
            lastAdvertTimestamp: 200,
            latitude: 39.0,
            longitude: -124.0
        )

        let anchorLocation = CLLocation(latitude: 37.0, longitude: -122.0)
        let match = RepeaterResolver.bestMatch(
            for: Data([0x3F]),
            in: [nearAnchor, farFromAnchor],
            userLocation: nil,
            anchorLocation: anchorLocation
        )

        #expect(match?.displayName == "NearAnchor")
    }

    @Test("without anchor, recency wins over proximity")
    func withoutAnchorRecencyWins() {
        // Same nodes but no anchor — newer node should win
        let nearUser = createRepeater(
            prefix: 0x3F,
            secondByte: 0x01,
            name: "NearButOlder",
            lastAdvertTimestamp: 10,
            latitude: 37.001,
            longitude: -122.001
        )
        let farButNewer = createRepeater(
            prefix: 0x3F,
            secondByte: 0x02,
            name: "FarButNewer",
            lastAdvertTimestamp: 200,
            latitude: 39.0,
            longitude: -124.0
        )

        let match = RepeaterResolver.bestMatch(
            for: Data([0x3F]),
            in: [nearUser, farButNewer],
            userLocation: nil,
            anchorLocation: nil
        )

        #expect(match?.displayName == "FarButNewer")
    }

    @Test("anchor prefers located node over unlocated node")
    func anchorPrefersLocatedOverUnlocated() {
        let located = createRepeater(
            prefix: 0x3F,
            secondByte: 0x01,
            name: "Located",
            lastAdvertTimestamp: 10,
            latitude: 37.001,
            longitude: -122.001
        )
        let unlocated = createRepeater(
            prefix: 0x3F,
            secondByte: 0x02,
            name: "Unlocated",
            lastAdvertTimestamp: 200,
            latitude: 0,
            longitude: 0
        )

        let anchorLocation = CLLocation(latitude: 37.0, longitude: -122.0)
        let match = RepeaterResolver.bestMatch(
            for: Data([0x3F]),
            in: [located, unlocated],
            userLocation: nil,
            anchorLocation: anchorLocation
        )

        #expect(match?.displayName == "Located")
    }

    // MARK: - Resolve / ResolverResult Tests

    @Test("resolve returns candidates sorted best-first")
    func resolveSortsCandidates() {
        let closer = createRepeater(
            prefix: 0x3F,
            secondByte: 0x01,
            name: "Closer",
            lastAdvertTimestamp: 10,
            latitude: 37.001,
            longitude: -122.001
        )
        let farther = createRepeater(
            prefix: 0x3F,
            secondByte: 0x02,
            name: "Farther",
            lastAdvertTimestamp: 200,
            latitude: 39.0,
            longitude: -124.0
        )

        let anchorLocation = CLLocation(latitude: 37.0, longitude: -122.0)
        let result = RepeaterResolver.resolve(
            for: Data([0x3F]),
            in: [closer, farther],
            userLocation: nil,
            anchorLocation: anchorLocation
        )

        #expect(result != nil)
        #expect(result?.best.displayName == "Closer")
        #expect(result?.candidates.count == 2)
        #expect(result?.isAmbiguous == true)
    }

    @Test("resolve returns non-ambiguous for single match")
    func resolveNonAmbiguousSingleMatch() {
        let only = createRepeater(
            prefix: 0x3F,
            secondByte: 0x01,
            name: "OnlyMatch",
            lastAdvertTimestamp: 10,
            latitude: 37.0,
            longitude: -122.0
        )

        let result = RepeaterResolver.resolve(
            for: Data([0x3F]),
            in: [only],
            userLocation: nil
        )

        #expect(result != nil)
        #expect(result?.isAmbiguous == false)
    }

    @Test("resolve returns nil when no candidates match")
    func resolveNilWhenNoMatch() {
        let node = createRepeater(
            prefix: 0xAA,
            secondByte: 0x01,
            name: "NoMatch",
            lastAdvertTimestamp: 10,
            latitude: 0,
            longitude: 0
        )

        let result = RepeaterResolver.resolve(
            for: Data([0x3F]),
            in: [node],
            userLocation: nil
        )

        #expect(result == nil)
    }

    @Test("alphabetical fallback when all else is equal")
    func alphabeticalFallback() {
        let alpha = createRepeater(
            prefix: 0x3F,
            secondByte: 0x01,
            name: "Alpha",
            lastAdvertTimestamp: 100,
            latitude: 0,
            longitude: 0
        )
        let beta = createRepeater(
            prefix: 0x3F,
            secondByte: 0x02,
            name: "Beta",
            lastAdvertTimestamp: 100,
            latitude: 0,
            longitude: 0
        )

        let match = RepeaterResolver.bestMatch(
            for: Data([0x3F]),
            in: [beta, alpha],
            userLocation: nil
        )

        #expect(match?.displayName == "Alpha")
    }
}
