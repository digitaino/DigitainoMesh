import Foundation
import Testing
@testable import MC1

// MARK: - SharedRoute Struct Tests

@Suite("SharedRoute Properties")
struct SharedRoutePropertyTests {

    @Test("id is comma-joined hex IDs")
    func idIsCommaJoined() {
        let route = SharedRoute(hexIDs: ["80", "8F", "0C"], hopCount: 3, distanceText: nil, shareURL: nil)
        #expect(route.id == "80,8F,0C")
    }

    @Test("hashBytesPerHop converts 2-char hex to 1 byte")
    func hashBytes2Char() {
        let route = SharedRoute(hexIDs: ["A3"], hopCount: 1, distanceText: nil, shareURL: nil)
        #expect(route.hashBytesPerHop == [Data([0xA3])])
    }

    @Test("hashBytesPerHop converts 4-char hex to 2 bytes")
    func hashBytes4Char() {
        let route = SharedRoute(hexIDs: ["7F42"], hopCount: 1, distanceText: nil, shareURL: nil)
        #expect(route.hashBytesPerHop == [Data([0x7F, 0x42])])
    }

    @Test("hashBytesPerHop converts 6-char hex to 3 bytes")
    func hashBytes6Char() {
        let route = SharedRoute(hexIDs: ["A3B5C9"], hopCount: 1, distanceText: nil, shareURL: nil)
        #expect(route.hashBytesPerHop == [Data([0xA3, 0xB5, 0xC9])])
    }

    @Test("hashBytesPerHop handles multiple hops")
    func hashBytesMultiple() {
        let route = SharedRoute(hexIDs: ["80", "8F", "0C"], hopCount: 3, distanceText: nil, shareURL: nil)
        #expect(route.hashBytesPerHop.count == 3)
        #expect(route.hashBytesPerHop[0] == Data([0x80]))
        #expect(route.hashBytesPerHop[1] == Data([0x8F]))
        #expect(route.hashBytesPerHop[2] == Data([0x0C]))
    }
}

// MARK: - SharedRouteParser.parse Tests

@Suite("SharedRouteParser.parse")
struct SharedRouteParserParseTests {

    @Test("parses standard 3-hop route")
    func standardThreeHopRoute() {
        let result = SharedRouteParser.parse("RX via 80,8F,0C. 3 hops 2.3 mi")
        #expect(result != nil)
        #expect(result?.hexIDs == ["80", "8F", "0C"])
        #expect(result?.hopCount == 3)
        #expect(result?.distanceText == "2.3 mi")
    }

    @Test("parses single hop route")
    func singleHopRoute() {
        let result = SharedRouteParser.parse("RX via A3. 1 hop")
        #expect(result != nil)
        #expect(result?.hexIDs == ["A3"])
        #expect(result?.hopCount == 1)
        #expect(result?.distanceText == nil)
    }

    @Test("parses route without distance")
    func routeWithoutDistance() {
        let result = SharedRouteParser.parse("RX via 80,8F. 2 hops")
        #expect(result != nil)
        #expect(result?.hexIDs == ["80", "8F"])
        #expect(result?.hopCount == 2)
        #expect(result?.distanceText == nil)
    }

    @Test("parses route with km distance")
    func routeWithKmDistance() {
        let result = SharedRouteParser.parse("RX via A3,7F,42. 3 hops 12.5 km")
        #expect(result != nil)
        #expect(result?.distanceText == "12.5 km")
    }

    @Test("parses route with ≥ prefix distance")
    func routeWithApproxDistance() {
        let result = SharedRouteParser.parse("RX via A3,7F. 2 hops ≥ 5.1 mi")
        #expect(result != nil)
        #expect(result?.distanceText == "≥ 5.1 mi")
    }

    @Test("parses 4-char hex IDs")
    func fourCharHexIDs() {
        let result = SharedRouteParser.parse("RX via A3B5,C9DE. 2 hops")
        #expect(result != nil)
        #expect(result?.hexIDs == ["A3B5", "C9DE"])
    }

    @Test("parses 6-char hex IDs")
    func sixCharHexIDs() {
        let result = SharedRouteParser.parse("RX via A3B5C9,DEADBE. 2 hops")
        #expect(result != nil)
        #expect(result?.hexIDs == ["A3B5C9", "DEADBE"])
    }

    @Test("parses lowercase hex IDs")
    func lowercaseHexIDs() {
        let result = SharedRouteParser.parse("RX via a3,7f,0c. 3 hops")
        #expect(result != nil)
        #expect(result?.hexIDs == ["a3", "7f", "0c"])
    }

    @Test("returns nil for text without RX via")
    func noRxViaReturnsNil() {
        let result = SharedRouteParser.parse("just some text without route info")
        #expect(result == nil)
    }

    @Test("returns nil for empty string")
    func emptyStringReturnsNil() {
        let result = SharedRouteParser.parse("")
        #expect(result == nil)
    }

    @Test("returns nil for malformed RX via")
    func malformedRxVia() {
        let result = SharedRouteParser.parse("RX via oops not hex. 1 hop")
        #expect(result == nil)
    }

    @Test("parses route embedded in longer message")
    func routeInLongerMessage() {
        let text = "Hey check this out!\nRX via 80,8F,0C. 3 hops 2.3 mi\nPretty cool right?"
        let result = SharedRouteParser.parse(text)
        #expect(result != nil)
        #expect(result?.hexIDs == ["80", "8F", "0C"])
    }

    @Test("detects accompanying route URL")
    func detectsAccompanyingURL() {
        let text = "RX via 80,8F. 2 hops\nhttps://mesh.digitaino.com/r/a3Kx9m"
        let result = SharedRouteParser.parse(text)
        #expect(result != nil)
        #expect(result?.shareURL?.absoluteString == "https://mesh.digitaino.com/r/a3Kx9m")
    }

    @Test("shareURL is nil when no URL in text")
    func shareURLIsNilWithoutURL() {
        let result = SharedRouteParser.parse("RX via 80,8F. 2 hops")
        #expect(result?.shareURL == nil)
    }
}

// MARK: - SharedRouteParser.parseRouteURL Tests

@Suite("SharedRouteParser.parseRouteURL")
struct SharedRouteParserRouteURLTests {

    @Test("extracts valid route URL")
    func validRouteURL() {
        let result = SharedRouteParser.parseRouteURL("Check this: https://mesh.digitaino.com/r/a3Kx9m")
        #expect(result != nil)
        #expect(result?.absoluteString == "https://mesh.digitaino.com/r/a3Kx9m")
    }

    @Test("extracts route URL from mixed text")
    func routeURLInMixedText() {
        let text = "Here is the route: https://mesh.digitaino.com/r/AbCdEf and some more text"
        let result = SharedRouteParser.parseRouteURL(text)
        #expect(result != nil)
        #expect(result?.absoluteString == "https://mesh.digitaino.com/r/AbCdEf")
    }

    @Test("returns nil when no route URL present")
    func noRouteURL() {
        let result = SharedRouteParser.parseRouteURL("no URLs here")
        #expect(result == nil)
    }

    @Test("returns nil for map URL (wrong path)")
    func mapURLNotMatched() {
        let result = SharedRouteParser.parseRouteURL("https://mesh.digitaino.com/m/a3Kx9m")
        #expect(result == nil)
    }

    @Test("returns nil for short ID (< 5 chars)")
    func shortIDNotMatched() {
        let result = SharedRouteParser.parseRouteURL("https://mesh.digitaino.com/r/abc")
        #expect(result == nil)
    }

    @Test("handles http scheme")
    func httpScheme() {
        let result = SharedRouteParser.parseRouteURL("http://mesh.digitaino.com/r/a3Kx9m")
        #expect(result != nil)
    }
}

// MARK: - SharedRouteParser.parseMapURL Tests

@Suite("SharedRouteParser.parseMapURL")
struct SharedRouteParserMapURLTests {

    @Test("extracts valid map URL")
    func validMapURL() {
        let result = SharedRouteParser.parseMapURL("Check this: https://mesh.digitaino.com/m/b7Xy2Q")
        #expect(result != nil)
        #expect(result?.absoluteString == "https://mesh.digitaino.com/m/b7Xy2Q")
    }

    @Test("returns nil when no map URL present")
    func noMapURL() {
        let result = SharedRouteParser.parseMapURL("no map links")
        #expect(result == nil)
    }

    @Test("returns nil for route URL (wrong path)")
    func routeURLNotMatched() {
        let result = SharedRouteParser.parseMapURL("https://mesh.digitaino.com/r/a3Kx9m")
        #expect(result == nil)
    }

    @Test("extracts map URL from mixed text")
    func mapURLInMixedText() {
        let text = "Here's the map https://mesh.digitaino.com/m/AbCdEf showing repeaters"
        let result = SharedRouteParser.parseMapURL(text)
        #expect(result != nil)
        #expect(result?.absoluteString == "https://mesh.digitaino.com/m/AbCdEf")
    }
}
