import Foundation
@testable import MC1Services
import Testing

@Suite("SharedRoute properties")
struct SharedRoutePropertyTests {

  @Test("id is comma-joined hex IDs")
  func idIsCommaJoined() {
    let route = SharedRoute(hexIDs: ["80", "8F", "0C"], hopCount: 3, distanceText: nil)
    #expect(route.id == "80,8F,0C")
  }

  @Test("hashBytesPerHop converts 2-char hex to 1 byte")
  func hashBytes2Char() {
    let route = SharedRoute(hexIDs: ["A3"], hopCount: 1, distanceText: nil)
    #expect(route.hashBytesPerHop == [Data([0xA3])])
  }

  @Test("hashBytesPerHop converts 4-char hex to 2 bytes")
  func hashBytes4Char() {
    let route = SharedRoute(hexIDs: ["7F42"], hopCount: 1, distanceText: nil)
    #expect(route.hashBytesPerHop == [Data([0x7F, 0x42])])
  }

  @Test("hashBytesPerHop converts 6-char hex to 3 bytes")
  func hashBytes6Char() {
    let route = SharedRoute(hexIDs: ["A3B5C9"], hopCount: 1, distanceText: nil)
    #expect(route.hashBytesPerHop == [Data([0xA3, 0xB5, 0xC9])])
  }

  @Test("hashBytesPerHop handles multiple hops")
  func hashBytesMultiple() {
    let route = SharedRoute(hexIDs: ["80", "8F", "0C"], hopCount: 3, distanceText: nil)
    #expect(route.hashBytesPerHop == [Data([0x80]), Data([0x8F]), Data([0x0C])])
  }

  @Test("hashBytesPerHop drops an undecodable hop instead of truncating it")
  func hashBytesUndecodableHop() {
    let route = SharedRoute(hexIDs: ["80", "8FZZ"], hopCount: 2, distanceText: nil)
    #expect(route.hashBytesPerHop == [Data([0x80])])
  }

  @Test("hashBytesPerHop drops an odd-length hop instead of zero-extending it")
  func hashBytesOddLengthHop() {
    let route = SharedRoute(hexIDs: ["80", "80F"], hopCount: 2, distanceText: nil)
    #expect(route.hashBytesPerHop == [Data([0x80])])
  }

  @Test("hashBytesPerHop truncates a full public key to its 3-byte prefix")
  func hashBytesFullKeyTruncated() {
    let fullKey = "A3B5C9" + String(repeating: "0", count: 58)
    let route = SharedRoute(hexIDs: [fullKey], hopCount: 1, distanceText: nil)
    #expect(route.hashBytesPerHop == [Data([0xA3, 0xB5, 0xC9])])
  }
}

@Suite("SharedRouteParser.parse")
struct SharedRouteParserParseTests {

  @Test("parses standard 3-hop route")
  func standardThreeHopRoute() {
    let result = SharedRouteParser.parse("RX via 80,8F,0C. 3 hops 2.3 mi")
    #expect(result?.hexIDs == ["80", "8F", "0C"])
    #expect(result?.hopCount == 3)
    #expect(result?.distanceText == "2.3 mi")
  }

  @Test("parses single hop route")
  func singleHopRoute() {
    let result = SharedRouteParser.parse("RX via A3. 1 hop")
    #expect(result?.hexIDs == ["A3"])
    #expect(result?.hopCount == 1)
    #expect(result?.distanceText == nil)
  }

  @Test("parses route without distance")
  func routeWithoutDistance() {
    let result = SharedRouteParser.parse("RX via 80,8F. 2 hops")
    #expect(result?.hexIDs == ["80", "8F"])
    #expect(result?.hopCount == 2)
    #expect(result?.distanceText == nil)
  }

  @Test("parses route with km distance")
  func routeWithKmDistance() {
    let result = SharedRouteParser.parse("RX via A3,7F,42. 3 hops 12.5 km")
    #expect(result?.distanceText == "12.5 km")
  }

  @Test("parses route with ≥ prefix distance")
  func routeWithApproxDistance() {
    let result = SharedRouteParser.parse("RX via A3,7F. 2 hops ≥ 5.1 mi")
    #expect(result?.distanceText == "≥ 5.1 mi")
  }

  @Test("parses 4-char hex IDs")
  func fourCharHexIDs() {
    let result = SharedRouteParser.parse("RX via A3B5,C9DE. 2 hops")
    #expect(result?.hexIDs == ["A3B5", "C9DE"])
  }

  @Test("parses 6-char hex IDs")
  func sixCharHexIDs() {
    let result = SharedRouteParser.parse("RX via A3B5C9,DEADBE. 2 hops")
    #expect(result?.hexIDs == ["A3B5C9", "DEADBE"])
  }

  @Test("parses lowercase hex IDs")
  func lowercaseHexIDs() {
    let result = SharedRouteParser.parse("RX via a3,7f,0c. 3 hops")
    #expect(result?.hexIDs == ["a3", "7f", "0c"])
  }

  @Test("returns nil for text without RX via")
  func noRxViaReturnsNil() {
    #expect(SharedRouteParser.parse("just some text without route info") == nil)
  }

  @Test("returns nil for empty string")
  func emptyStringReturnsNil() {
    #expect(SharedRouteParser.parse("") == nil)
  }

  @Test("returns nil for malformed RX via")
  func malformedRxVia() {
    #expect(SharedRouteParser.parse("RX via oops not hex. 1 hop") == nil)
  }

  @Test("returns nil for an odd-length hex ID, which has no whole-byte reading")
  func oddLengthHexIDRejected() {
    #expect(SharedRouteParser.parse("RX via 80F,0C. 2 hops") == nil)
    #expect(SharedRouteParser.parse("RX via 80F. 1 hop") == nil)
  }

  @Test("parses route embedded in longer message")
  func routeInLongerMessage() {
    let text = "Hey check this out!\nRX via 80,8F,0C. 3 hops 2.3 mi\nPretty cool right?"
    let result = SharedRouteParser.parse(text)
    #expect(result?.hexIDs == ["80", "8F", "0C"])
    #expect(result?.distanceText == "2.3 mi")
  }

  @Test("distance tail stops at end of line")
  func distanceTailStopsAtNewline() {
    let result = SharedRouteParser.parse("RX via 80,8F. 2 hops 4.2 km\nsee you there")
    #expect(result?.distanceText == "4.2 km")
  }

  @Test("keeps the sender's stated hop count even when it disagrees")
  func statedHopCountPreserved() {
    let result = SharedRouteParser.parse("RX via 80,8F. 3 hops")
    #expect(result?.hexIDs == ["80", "8F"])
    #expect(result?.hopCount == 3)
  }
}

@Suite("SharedRouteParser.detectChain")
struct SharedRouteParserDetectChainTests {

  @Test("detects a pasted chain after a mention and emoji")
  func chainInChannelMessage() {
    let text = "@[KJ5DHR-Logan] 🫰 51fb,1776,e19e,1ee8,4216,b49f,da1c,42da"
    let result = SharedRouteParser.detectChain(text)
    #expect(result?.hexIDs == ["51FB", "1776", "E19E", "1EE8", "4216", "B49F", "DA1C", "42DA"])
    #expect(result?.hopCount == 8)
    #expect(result?.distanceText == nil)
  }

  @Test("detects a chain whose commas are followed by spaces")
  func spacedCommaChain() {
    let result = SharedRouteParser.detectChain("try A3, 7F, 42")
    #expect(result?.hexIDs == ["A3", "7F", "42"])
  }

  @Test("detects an arrow-separated chain after a mention")
  func arrowSeparatedChain() {
    let result = SharedRouteParser.detectChain("@[Digitaino] D0A0->DA1C->A3DD->7DD0->349D->5790->90E2")
    #expect(result?.hexIDs == ["D0A0", "DA1C", "A3DD", "7DD0", "349D", "5790", "90E2"])
    #expect(result?.hopCount == 7)
  }

  @Test("detects arrows with spaces around them")
  func spacedArrowChain() {
    let result = SharedRouteParser.detectChain("path was A3 -> 7F -> 42 today")
    #expect(result?.hexIDs == ["A3", "7F", "42"])
  }

  @Test("detects the app's own typographic arrow format")
  func typographicArrowChain() {
    let result = SharedRouteParser.detectChain("A3 → 7F → 42")
    #expect(result?.hexIDs == ["A3", "7F", "42"])
  }

  @Test("picks the longest run in the message")
  func longestRunWins() {
    let result = SharedRouteParser.detectChain("was A3,7F now via B1,C2,D3 instead")
    #expect(result?.hexIDs == ["B1", "C2", "D3"])
  }

  @Test("never fires on RX via text, which parse owns")
  func yieldsToReplyFormat() {
    #expect(SharedRouteParser.detectChain("RX via 80,8F. 2 hops") == nil)
  }

  @Test("a single token is too ambiguous")
  func singleTokenRejected() {
    #expect(SharedRouteParser.detectChain("node A3 is up") == nil)
  }

  @Test("an all-digit run is a number list, not a path")
  func allDigitRunRejected() {
    #expect(SharedRouteParser.detectChain("see you at 10,12") == nil)
    #expect(SharedRouteParser.detectChain("2024, 2025") == nil)
  }

  @Test("odd-length and non-hex tokens break a run")
  func invalidTokensBreakRun() {
    #expect(SharedRouteParser.detectChain("call ABC,DEF tonight") == nil)
    #expect(SharedRouteParser.detectChain("hello world") == nil)
  }

  @Test("plain sentences do not card")
  func plainTextRejected() {
    #expect(SharedRouteParser.detectChain("Testing from Liberty Hill") == nil)
    #expect(SharedRouteParser.detectChain("Amazing!") == nil)
  }

  @Test("hex-shaped words that are merely adjacent are prose, not a chain")
  func whitespaceAdjacencyRejected() {
    #expect(SharedRouteParser.detectChain("battery might be dead") == nil)
    #expect(SharedRouteParser.detectChain("uno de cada nodo") == nil)
    #expect(SharedRouteParser.detectChain("AC DC") == nil)
    #expect(SharedRouteParser.detectChain("dead beef") == nil)
    #expect(SharedRouteParser.detectChain("try A3 7F 42") == nil)
  }

  @Test("a separator re-joins hex words that whitespace alone would not")
  func separatorJoinsWhatWhitespaceDoesNot() {
    #expect(SharedRouteParser.detectChain("dead,beef")?.hexIDs == ["DEAD", "BEEF"])
    #expect(SharedRouteParser.detectChain("dead -> beef")?.hexIDs == ["DEAD", "BEEF"])
  }
}
