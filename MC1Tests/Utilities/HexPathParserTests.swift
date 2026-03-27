import Foundation
import Testing
@testable import MC1

// MARK: - HexPath Struct Tests

@Suite("HexPath Properties")
struct HexPathPropertyTests {

    @Test("hopCount matches hexIDs count")
    func hopCountMatchesIDCount() {
        let path = HexPath(hexIDs: ["A3", "7F42", "B5C9"], shareURL: nil)
        #expect(path.hopCount == 3)
    }

    @Test("id is comma-joined hex IDs")
    func idIsCommaJoined() {
        let path = HexPath(hexIDs: ["A3", "7F", "42"], shareURL: nil)
        #expect(path.id == "A3,7F,42")
    }

    @Test("hashBytesPerHop converts 2-char hex to 1 byte")
    func hashBytes2Char() {
        let path = HexPath(hexIDs: ["A3"], shareURL: nil)
        #expect(path.hashBytesPerHop == [Data([0xA3])])
    }

    @Test("hashBytesPerHop converts 4-char hex to 2 bytes")
    func hashBytes4Char() {
        let path = HexPath(hexIDs: ["7F42"], shareURL: nil)
        #expect(path.hashBytesPerHop == [Data([0x7F, 0x42])])
    }

    @Test("hashBytesPerHop converts 6-char hex to 3 bytes")
    func hashBytes6Char() {
        let path = HexPath(hexIDs: ["A3B5C9"], shareURL: nil)
        #expect(path.hashBytesPerHop == [Data([0xA3, 0xB5, 0xC9])])
    }

    @Test("hashBytesPerHop truncates 64-char key to 3 bytes")
    func hashBytes64Char() {
        let fullKey = "A3B5C9" + String(repeating: "00", count: 29) // 64 hex chars
        let path = HexPath(hexIDs: [fullKey], shareURL: nil)
        #expect(path.hashBytesPerHop == [Data([0xA3, 0xB5, 0xC9])])
    }

    @Test("hashBytesPerHop handles multiple hops")
    func hashBytesMultipleHops() {
        let path = HexPath(hexIDs: ["A3", "7F42", "B5C9DE"], shareURL: nil)
        #expect(path.hashBytesPerHop.count == 3)
        #expect(path.hashBytesPerHop[0] == Data([0xA3]))
        #expect(path.hashBytesPerHop[1] == Data([0x7F, 0x42]))
        #expect(path.hashBytesPerHop[2] == Data([0xB5, 0xC9, 0xDE]))
    }

    @Test("asSharedRoute converts correctly")
    func asSharedRouteConversion() {
        let url = URL(string: "https://mesh.digitaino.com/p/abc123")!
        let path = HexPath(hexIDs: ["A3", "7F"], shareURL: url)
        let route = path.asSharedRoute
        #expect(route.hexIDs == ["A3", "7F"])
        #expect(route.hopCount == 2)
        #expect(route.distanceText == nil)
        #expect(route.shareURL == url)
    }
}

// MARK: - HexPathParser.parse Tests

@Suite("HexPathParser.parse")
struct HexPathParserParseTests {

    @Test("parses comma-separated hex IDs")
    func commaSeparated() {
        let result = HexPathParser.parse("A3, 7F, 42")
        #expect(result != nil)
        #expect(result?.hexIDs == ["A3", "7F", "42"])
    }

    @Test("parses space-separated hex IDs")
    func spaceSeparated() {
        let result = HexPathParser.parse("A3 7F 42")
        #expect(result != nil)
        #expect(result?.hexIDs == ["A3", "7F", "42"])
    }

    @Test("parses comma-only separated hex IDs")
    func commaOnly() {
        let result = HexPathParser.parse("A3,7F,42")
        #expect(result != nil)
        #expect(result?.hexIDs == ["A3", "7F", "42"])
    }

    @Test("parses mixed delimiters")
    func mixedDelimiters() {
        let result = HexPathParser.parse("A3, 7F 42\tB5")
        #expect(result != nil)
        #expect(result?.hexIDs == ["A3", "7F", "42", "B5"])
    }

    @Test("parses 4-char hex tokens")
    func fourCharTokens() {
        let result = HexPathParser.parse("A3B5, C9DE")
        #expect(result != nil)
        #expect(result?.hexIDs == ["A3B5", "C9DE"])
    }

    @Test("parses 6-char hex tokens")
    func sixCharTokens() {
        let result = HexPathParser.parse("A3B5C9, DEADBE")
        #expect(result != nil)
        #expect(result?.hexIDs == ["A3B5C9", "DEADBE"])
    }

    @Test("parses 64-char full key tokens")
    func fullKeyTokens() {
        let key1 = String(repeating: "AB", count: 32) // 64 hex chars
        let key2 = String(repeating: "CD", count: 32)
        let result = HexPathParser.parse("\(key1) \(key2)")
        #expect(result != nil)
        #expect(result?.hexIDs.count == 2)
    }

    @Test("uppercases all hex IDs")
    func uppercasesIDs() {
        let result = HexPathParser.parse("a3, 7f, b5")
        #expect(result != nil)
        #expect(result?.hexIDs == ["A3", "7F", "B5"])
    }

    @Test("returns nil for single token")
    func singleTokenReturnsNil() {
        let result = HexPathParser.parse("A3")
        #expect(result == nil)
    }

    @Test("returns nil for empty string")
    func emptyStringReturnsNil() {
        let result = HexPathParser.parse("")
        #expect(result == nil)
    }

    @Test("returns nil for whitespace-only string")
    func whitespaceOnlyReturnsNil() {
        let result = HexPathParser.parse("   \t  \n  ")
        #expect(result == nil)
    }

    @Test("returns nil when any token has invalid hex chars")
    func invalidHexCharsReturnsNil() {
        let result = HexPathParser.parse("A3, GG, 7F")
        #expect(result == nil)
    }

    @Test("returns nil for 3-char hex tokens (invalid length)")
    func threeCharTokenReturnsNil() {
        let result = HexPathParser.parse("A3B, C9D")
        #expect(result == nil)
    }

    @Test("returns nil for 5-char hex tokens (invalid length)")
    func fiveCharTokenReturnsNil() {
        let result = HexPathParser.parse("A3B5C, DEADB")
        #expect(result == nil)
    }

    @Test("returns nil for mixed valid and invalid length tokens")
    func mixedValidInvalidLengthReturnsNil() {
        let result = HexPathParser.parse("A3, ABC, 7F")
        #expect(result == nil)
    }

    @Test("parses exactly 2 valid tokens (minimum)")
    func minimumTwoTokens() {
        let result = HexPathParser.parse("A3, 7F")
        #expect(result != nil)
        #expect(result?.hexIDs == ["A3", "7F"])
    }

    @Test("handles newline delimiters")
    func newlineDelimiters() {
        let result = HexPathParser.parse("A3\n7F\n42")
        #expect(result != nil)
        #expect(result?.hexIDs == ["A3", "7F", "42"])
    }

    @Test("shareURL is nil from parse")
    func shareURLIsNil() {
        let result = HexPathParser.parse("A3, 7F")
        #expect(result?.shareURL == nil)
    }
}

// MARK: - HexPathParser.detectInMessage Tests

@Suite("HexPathParser.detectInMessage")
struct HexPathParserDetectTests {

    @Test("detects 3 consecutive hex tokens in message")
    func detectsThreeTokens() {
        let result = HexPathParser.detectInMessage("the path was A3 7F 42 yesterday")
        #expect(result != nil)
        #expect(result?.hexIDs == ["A3", "7F", "42"])
    }

    @Test("detects comma-separated hex in message")
    func detectsCommaSeparated() {
        let result = HexPathParser.detectInMessage("route: A3,7F,42,B5")
        #expect(result != nil)
        #expect(result?.hexIDs == ["A3", "7F", "42", "B5"])
    }

    @Test("returns longest run of hex tokens")
    func longestRun() {
        let result = HexPathParser.detectInMessage("AB CD hello A3 7F 42 B5 end")
        #expect(result != nil)
        #expect(result?.hexIDs == ["A3", "7F", "42", "B5"])
    }

    @Test("returns nil for fewer than 3 hex tokens")
    func fewerThanThreeReturnsNil() {
        let result = HexPathParser.detectInMessage("just A3 7F in text")
        #expect(result == nil)
    }

    @Test("returns nil for message containing 'RX via'")
    func rxViaReturnsNil() {
        let result = HexPathParser.detectInMessage("RX via A3,7F,42. 3 hops")
        #expect(result == nil)
    }

    @Test("returns nil for no hex tokens")
    func noHexTokensReturnsNil() {
        let result = HexPathParser.detectInMessage("just a regular message")
        #expect(result == nil)
    }

    @Test("returns nil for empty message")
    func emptyMessageReturnsNil() {
        let result = HexPathParser.detectInMessage("")
        #expect(result == nil)
    }

    @Test("non-hex words break the run")
    func nonHexWordsBreakRun() {
        let result = HexPathParser.detectInMessage("A3 7F hello 42 B5 C9")
        // "A3 7F" is 2 tokens (too short), "42 B5 C9" is 3 tokens
        #expect(result != nil)
        #expect(result?.hexIDs == ["42", "B5", "C9"])
    }

    @Test("uppercases detected hex IDs")
    func uppercasesDetected() {
        let result = HexPathParser.detectInMessage("path: a3 7f 42")
        #expect(result != nil)
        #expect(result?.hexIDs == ["A3", "7F", "42"])
    }

    @Test("detects 4-char hex tokens in message")
    func fourCharTokensInMessage() {
        let result = HexPathParser.detectInMessage("via A3B5 C9DE FFAA")
        #expect(result != nil)
        #expect(result?.hexIDs == ["A3B5", "C9DE", "FFAA"])
    }

    @Test("detects mixed-length hex tokens")
    func mixedLengthTokens() {
        let result = HexPathParser.detectInMessage("path: A3 7F42 B5C9DE")
        #expect(result != nil)
        #expect(result?.hexIDs == ["A3", "7F42", "B5C9DE"])
    }
}
