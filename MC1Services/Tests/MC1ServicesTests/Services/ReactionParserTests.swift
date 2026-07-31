import Foundation
@testable import MC1Services
import Testing

@Suite("ReactionParser Tests")
struct ReactionParserTests {
  // MARK: - Valid Format Tests

  @Test
  func `Parses simple reaction with thumbs up`() {
    let text = "👍@[AlphaNode]\n7f3a9c12"
    let result = ReactionParser.parse(text)

    #expect(result != nil)
    #expect(result?.emoji == "👍")
    #expect(result?.targetSender == "AlphaNode")
    #expect(result?.messageHash == "7f3a9c12")
  }

  @Test
  func `Parses reaction with heart emoji`() {
    let text = "❤️@[BetaNode]\ne4d8b1a0"
    let result = ReactionParser.parse(text)

    #expect(result != nil)
    #expect(result?.emoji == "❤️")
    #expect(result?.targetSender == "BetaNode")
    #expect(result?.messageHash == "e4d8b1a0")
  }

  @Test
  func `Parses reaction with uppercase identifier and normalizes to lowercase`() {
    let text = "👍@[Node]\nABCDEF12"
    let result = ReactionParser.parse(text)

    #expect(result != nil)
    #expect(result?.messageHash == "abcdef12")
  }

  @Test
  func `Parses reaction with mixed case identifier`() {
    let text = "👍@[Node]\nAbCdEf12"
    let result = ReactionParser.parse(text)

    #expect(result != nil)
    #expect(result?.messageHash == "abcdef12")
  }

  // MARK: - Crockford Base32 Identifier Tests

  @Test
  func `Generates 8-character Crockford Base32 identifier`() {
    let hash = ReactionParser.generateMessageHash(text: "Hello", timestamp: 1_704_067_200)
    #expect(hash.count == 8)
    // Verify all characters are valid Crockford Base32 (lowercase)
    let validChars = CharacterSet(charactersIn: "0123456789abcdefghjkmnpqrstvwxyz")
    #expect(hash.unicodeScalars.allSatisfy { validChars.contains($0) })
  }

  @Test
  func `Same input produces same identifier`() {
    let hash1 = ReactionParser.generateMessageHash(text: "Hello", timestamp: 1_704_067_200)
    let hash2 = ReactionParser.generateMessageHash(text: "Hello", timestamp: 1_704_067_200)
    #expect(hash1 == hash2)
  }

  @Test
  func `Different text produces different identifier`() {
    let hash1 = ReactionParser.generateMessageHash(text: "Hello", timestamp: 1_704_067_200)
    let hash2 = ReactionParser.generateMessageHash(text: "World", timestamp: 1_704_067_200)
    #expect(hash1 != hash2)
  }

  @Test
  func `Different timestamp produces different identifier`() {
    let hash1 = ReactionParser.generateMessageHash(text: "Hello", timestamp: 1_704_067_200)
    let hash2 = ReactionParser.generateMessageHash(text: "Hello", timestamp: 1_704_067_201)
    #expect(hash1 != hash2)
  }

  @Test
  func `Crockford O is decoded as 0`() {
    let text = "👍@[Node]\nOOOOOOOO"
    let result = ReactionParser.parse(text)

    #expect(result != nil)
    #expect(result?.messageHash == "00000000")
  }

  @Test
  func `Crockford I/L are decoded as 1`() {
    let textI = "👍@[Node]\niiiiiiii"
    let resultI = ReactionParser.parse(textI)
    #expect(resultI?.messageHash == "11111111")

    let textL = "👍@[Node]\nLLLLLLLL"
    let resultL = ReactionParser.parse(textL)
    #expect(resultL?.messageHash == "11111111")
  }

  // MARK: - Edge Cases

  @Test
  func `Parses sender name containing colon`() {
    let text = "👍@[Node:Alpha]\na1b2c3d4"
    let result = ReactionParser.parse(text)

    #expect(result != nil)
    #expect(result?.targetSender == "Node:Alpha")
  }

  // MARK: - Invalid Format Tests

  @Test
  func `Returns nil for plain text message`() {
    let text = "Just a normal message"
    #expect(ReactionParser.parse(text) == nil)
  }

  @Test
  func `Returns nil for missing identifier`() {
    let text = "👍@[Node]"
    #expect(ReactionParser.parse(text) == nil)
  }

  @Test
  func `Returns nil for missing @ symbol`() {
    let text = "👍 [Node]\na1b2c3d4"
    #expect(ReactionParser.parse(text) == nil)
  }

  @Test
  func `Returns nil for missing brackets around sender`() {
    let text = "👍@Node\na1b2c3d4"
    #expect(ReactionParser.parse(text) == nil)
  }

  @Test
  func `Returns nil for invalid identifier length`() {
    let text = "👍@[Node]\nabc"
    #expect(ReactionParser.parse(text) == nil)
  }

  @Test
  func `Returns nil for invalid Crockford characters (U)`() {
    let text = "👍@[Node]\nuuuuuuuu"
    #expect(ReactionParser.parse(text) == nil)
  }

  @Test
  func `Returns nil for empty sender`() {
    let text = "👍@[]\na1b2c3d4"
    #expect(ReactionParser.parse(text) == nil)
  }

  @Test
  func `Returns nil for text not starting with emoji`() {
    let text = "A@[Node]\na1b2c3d4"
    #expect(ReactionParser.parse(text) == nil)
  }

  // MARK: - ZWJ Emoji Tests

  @Test
  func `Parses reaction with skin tone modifier`() {
    let text = "👍🏽@[Node]\na1b2c3d4"
    let result = ReactionParser.parse(text)

    #expect(result != nil)
    #expect(result?.emoji == "👍🏽")
  }

  @Test
  func `Parses reaction with family ZWJ emoji`() {
    let text = "👨‍👩‍👧@[Node]\na1b2c3d4"
    let result = ReactionParser.parse(text)

    #expect(result != nil)
    #expect(result?.emoji == "👨‍👩‍👧")
  }

  @Test
  func `Parses reaction with flag emoji`() {
    let text = "🇺🇸@[Node]\na1b2c3d4"
    let result = ReactionParser.parse(text)

    #expect(result != nil)
    #expect(result?.emoji == "🇺🇸")
  }

  // MARK: - Summary Cache Tests

  @Test
  func `Builds summary from reactions`() {
    let reactions = [
      ("👍", 3),
      ("❤️", 2),
      ("😂", 1)
    ]
    let summary = ReactionParser.buildSummary(from: reactions)
    #expect(summary == "👍:3,❤️:2,😂:1")
  }

  @Test
  func `Parses summary string`() {
    let summary = "👍:3,❤️:2,😂:1"
    let parsed = ReactionParser.parseSummary(summary)

    #expect(parsed.count == 3)
    #expect(parsed[0] == ("👍", 3))
    #expect(parsed[1] == ("❤️", 2))
    #expect(parsed[2] == ("😂", 1))
  }

  @Test
  func `Parses empty summary`() {
    let parsed = ReactionParser.parseSummary(nil)
    #expect(parsed.isEmpty)
  }

  @Test
  func `Summary parsing drops pairs that are not one emoji and a positive count`() {
    // A cache written before the emoji field was validated on receive can hold the
    // summary's own delimiters; those pairs must not keep rendering badges.
    let parsed = ReactionParser.parseSummary("👍:3,9:2,x:1,❤️:0,😂:-4,👎:1")
    #expect(parsed.count == 2)
    #expect(parsed[0] == ("👍", 3))
    #expect(parsed[1] == ("👎", 1))
  }

  @Test
  func `Sorts summary by count descending`() {
    let reactions = [
      ("😂", 1),
      ("👍", 5),
      ("❤️", 3)
    ]
    let summary = ReactionParser.buildSummary(from: reactions)
    #expect(summary == "👍:5,❤️:3,😂:1")
  }

  // MARK: - ReactionDTO DM Support Tests

  @Test
  func `ReactionDTO can be created with contactID for DMs`() {
    let contactID = UUID()
    let radioID = UUID()
    let messageID = UUID()

    let dto = ReactionDTO(
      messageID: messageID,
      emoji: "👍",
      senderName: "TestNode",
      messageHash: "a1b2c3d4",
      rawText: "👍@[TestNode]\na1b2c3d4",
      contactID: contactID,
      radioID: radioID
    )

    #expect(dto.contactID == contactID)
    #expect(dto.channelIndex == nil)
  }

  @Test
  func `ReactionDTO can be created with channelIndex for channels`() {
    let radioID = UUID()
    let messageID = UUID()

    let dto = ReactionDTO(
      messageID: messageID,
      emoji: "👍",
      senderName: "TestNode",
      messageHash: "a1b2c3d4",
      rawText: "👍@[TestNode]\na1b2c3d4",
      channelIndex: 5,
      radioID: radioID
    )

    #expect(dto.channelIndex == 5)
    #expect(dto.contactID == nil)
  }

  // MARK: - DM Reaction Format Tests

  @Test
  func `Parses DM reaction format without sender`() {
    let text = "👍\n7f3a9c12"
    let result = ReactionParser.parseDM(text)

    #expect(result != nil)
    #expect(result?.emoji == "👍")
    #expect(result?.messageHash == "7f3a9c12")
  }

  @Test
  func `Parses DM reaction with heart emoji`() {
    let text = "❤️\ne4d8b1a0"
    let result = ReactionParser.parseDM(text)

    #expect(result != nil)
    #expect(result?.emoji == "❤️")
  }

  @Test
  func `Returns nil for DM format missing hash`() {
    let text = "👍"
    #expect(ReactionParser.parseDM(text) == nil)
  }

  @Test
  func `DM parser rejects channel format`() {
    let text = "👍@[Node]\nabcd1234"
    #expect(ReactionParser.parseDM(text) == nil)
  }

  @Test
  func `Builds DM reaction text in piggyback format`() {
    let hash = ReactionParser.generateMessageHash(text: "Hello world", timestamp: 1_704_067_200)
    let text = ReactionParser.buildDMReactionText(
      emoji: "👍",
      targetText: "Hello world",
      targetTimestamp: 1_704_067_200
    )
    #expect(text == "👍 reacted to \"Hello world\"\n\(hash)")
  }

  @Test
  func `Parses DM reaction with uppercase hash and normalizes to lowercase`() {
    let text = "👍\nABCDEF12"
    let result = ReactionParser.parseDM(text)

    #expect(result != nil)
    #expect(result?.messageHash == "abcdef12")
  }

  @Test
  func `DM parser rejects invalid Crockford characters`() {
    let text = "👍\nuuuuuuuu"
    #expect(ReactionParser.parseDM(text) == nil)
  }

  @Test
  func `DM parser rejects non-emoji start`() {
    let text = "A\na1b2c3d4"
    #expect(ReactionParser.parseDM(text) == nil)
  }

  @Test
  func `DM parser handles skin tone modifier emoji`() {
    let text = "👍🏽\na1b2c3d4"
    let result = ReactionParser.parseDM(text)

    #expect(result != nil)
    #expect(result?.emoji == "👍🏽")
  }

  @Test
  func `DM round-trip: build then parse produces same emoji and hash`() {
    let originalEmoji = "👍"
    let targetText = "Hello world"
    let timestamp: UInt32 = 1_704_067_200

    let text = ReactionParser.buildDMReactionText(
      emoji: originalEmoji,
      targetText: targetText,
      targetTimestamp: timestamp
    )

    let parsed = ReactionParser.parseDM(text)
    #expect(parsed != nil)
    #expect(parsed?.emoji == originalEmoji)

    let expectedHash = ReactionParser.generateMessageHash(text: targetText, timestamp: timestamp)
    #expect(parsed?.messageHash == expectedHash)
  }

  // MARK: - Human-Readable Channel Format Tests

  @Test
  func `Parses human-readable channel reaction`() {
    let hash = ReactionParser.generateMessageHash(text: "Hello", timestamp: 1_704_067_200)
    let text = "👍 reacted to [AlphaNode]: \"Hello\" (\(hash))"
    let result = ReactionParser.parse(text)

    #expect(result != nil)
    #expect(result?.emoji == "👍")
    #expect(result?.targetSender == "AlphaNode")
    #expect(result?.messageHash == hash)
  }

  @Test
  func `Parses human-readable channel reaction with skin tone emoji`() {
    let text = "👍🏽 reacted to [Node]: \"Hi\" (a1b2c3d4)"
    let result = ReactionParser.parse(text)

    #expect(result != nil)
    #expect(result?.emoji == "👍🏽")
    #expect(result?.targetSender == "Node")
  }

  @Test
  func `Parses human-readable channel reaction with quotes in snippet`() {
    let hash = ReactionParser.generateMessageHash(text: "She said \"hello\"", timestamp: 100)
    let text = "❤️ reacted to [Bob]: \"She said \"hello\"\" (\(hash))"
    let result = ReactionParser.parse(text)

    #expect(result != nil)
    #expect(result?.emoji == "❤️")
    #expect(result?.targetSender == "Bob")
    #expect(result?.messageHash == hash)
  }

  @Test
  func `Parses human-readable channel reaction with truncated snippet`() {
    let text = "👍 reacted to [Node]: \"This is a very long...\" (a1b2c3d4)"
    let result = ReactionParser.parse(text)

    #expect(result != nil)
    #expect(result?.emoji == "👍")
    #expect(result?.targetSender == "Node")
    #expect(result?.messageHash == "a1b2c3d4")
  }

  @Test
  func `Human-readable channel rejects plain text`() {
    #expect(ReactionParser.parse("Just a normal message") == nil)
  }

  @Test
  func `Human-readable channel rejects missing hash`() {
    #expect(ReactionParser.parse("👍 reacted to [Node]: \"Hello\"") == nil)
  }

  // MARK: - Human-Readable DM Format Tests

  @Test
  func `Parses human-readable DM reaction`() {
    let hash = ReactionParser.generateMessageHash(text: "Hello", timestamp: 1_704_067_200)
    let text = "👍 reacted to: \"Hello\" (\(hash))"
    let result = ReactionParser.parseDM(text)

    #expect(result != nil)
    #expect(result?.emoji == "👍")
    #expect(result?.messageHash == hash)
  }

  @Test
  func `Human-readable DM rejects channel format`() {
    let text = "👍 reacted to [Node]: \"Hello\" (a1b2c3d4)"
    #expect(ReactionParser.parseDM(text) == nil)
  }

  @Test
  func `Human-readable DM with heart emoji`() {
    let text = "❤️ reacted to: \"Thanks!\" (e4d8b1a0)"
    let result = ReactionParser.parseDM(text)

    #expect(result != nil)
    #expect(result?.emoji == "❤️")
    #expect(result?.messageHash == "e4d8b1a0")
  }

  // MARK: - Build + Round-Trip Tests

  @Test
  func `Builds channel reaction text in piggyback format`() {
    let hash = ReactionParser.generateMessageHash(text: "Hello world", timestamp: 1_704_067_200)
    let text = ReactionParser.buildChannelReactionText(
      emoji: "👍",
      targetSender: "AlphaNode",
      targetText: "Hello world",
      targetTimestamp: 1_704_067_200,
      localNodeNameByteCount: "Me".utf8.count
    )
    #expect(text == "👍 reacted to \"Hello world\" @[AlphaNode]\n\(hash)")
  }

  @Test
  func `Reactors with different node-name lengths emit byte-identical channel reactions`() {
    // Upstream MC1 groups badge counts by the full phrase string, so the snippet
    // truncation must not depend on the reactor's own node-name length.
    let variants = [0, 2, 12, 31].map { nodeNameBytes in
      ReactionParser.buildChannelReactionText(
        emoji: "👍",
        targetSender: "AlphaNode",
        targetText: String(repeating: "long message ", count: 20),
        targetTimestamp: 100,
        localNodeNameByteCount: nodeNameBytes
      )
    }
    #expect(Set(variants).count == 1)
  }

  @Test
  func `Channel round-trip: build then parse produces same emoji, sender, and hash`() {
    let emoji = "❤️"
    let sender = "TestNode"
    let targetText = "How's the signal?"
    let timestamp: UInt32 = 1_704_067_200

    let text = ReactionParser.buildChannelReactionText(
      emoji: emoji,
      targetSender: sender,
      targetText: targetText,
      targetTimestamp: timestamp,
      localNodeNameByteCount: "Me".utf8.count
    )

    let parsed = ReactionParser.parse(text)
    #expect(parsed != nil)
    #expect(parsed?.emoji == emoji)
    #expect(parsed?.targetSender == sender)

    let expectedHash = ReactionParser.generateMessageHash(text: targetText, timestamp: timestamp)
    #expect(parsed?.messageHash == expectedHash)
  }

  @Test
  func `DM round-trip with piggyback format`() {
    let emoji = "🔥"
    let targetText = "Great coverage here"
    let timestamp: UInt32 = 1_704_067_200

    let text = ReactionParser.buildDMReactionText(
      emoji: emoji,
      targetText: targetText,
      targetTimestamp: timestamp
    )

    let parsed = ReactionParser.parseDM(text)
    #expect(parsed != nil)
    #expect(parsed?.emoji == emoji)

    let expectedHash = ReactionParser.generateMessageHash(text: targetText, timestamp: timestamp)
    #expect(parsed?.messageHash == expectedHash)
  }

  // MARK: - isReactionText with Human-Readable Format

  @Test
  func `isReactionText recognizes human-readable channel format`() {
    let text = "👍 reacted to [Node]: \"Hello\" (a1b2c3d4)"
    #expect(ReactionParser.isReactionText(text, isDM: false) == true)
  }

  @Test
  func `isReactionText recognizes human-readable DM format`() {
    let text = "👍 reacted to: \"Hello\" (a1b2c3d4)"
    #expect(ReactionParser.isReactionText(text, isDM: true) == true)
  }

  // MARK: - Truncation Tests

  @Test
  func `Channel reaction truncates long messages`() {
    let longText = String(repeating: "a", count: 200)
    let localNodeName = "MyNode"
    let text = ReactionParser.buildChannelReactionText(
      emoji: "👍",
      targetSender: "Node",
      targetText: longText,
      targetTimestamp: 100,
      localNodeNameByteCount: localNodeName.utf8.count
    )
    // Must fit within the per-node-name channel budget so the firmware-prepended
    // "{NodeName}: " plus the reaction stays within maxChannelMessageTotalLength.
    let budget = ProtocolLimits.maxChannelMessageLength(
      nodeNameByteCount: localNodeName.utf8.count
    )
    #expect(text.utf8.count <= budget)
    #expect(text.contains("..."))

    // Must still round-trip parse
    let parsed = ReactionParser.parse(text)
    #expect(parsed != nil)
    #expect(parsed?.emoji == "👍")
    #expect(parsed?.targetSender == "Node")
  }

  @Test
  func `Channel reaction respects longer node name budgets`() {
    let longText = String(repeating: "a", count: 200)
    // A 31-byte node name is the maximum usable length; this exercises the
    // tightest budget where the snippet has the least room.
    let localNodeName = String(repeating: "x", count: 31)
    let text = ReactionParser.buildChannelReactionText(
      emoji: "👍",
      targetSender: "Node",
      targetText: longText,
      targetTimestamp: 100,
      localNodeNameByteCount: localNodeName.utf8.count
    )
    let budget = ProtocolLimits.maxChannelMessageLength(
      nodeNameByteCount: localNodeName.utf8.count
    )
    #expect(text.utf8.count <= budget)

    // Hash suffix must always be preserved.
    let parsed = ReactionParser.parse(text)
    #expect(parsed != nil)
  }

  @Test
  func `Channel reaction reserves the safety margin below the budget`() {
    let longText = String(repeating: "a", count: 200)
    let localNodeName = "MyNode"
    let text = ReactionParser.buildChannelReactionText(
      emoji: "👍",
      targetSender: "Node",
      targetText: longText,
      targetTimestamp: 100,
      localNodeNameByteCount: localNodeName.utf8.count
    )
    let budget = ProtocolLimits.maxChannelMessageLength(
      nodeNameByteCount: localNodeName.utf8.count
    )
    #expect(text.utf8.count <= budget - ReactionParser.reactionByteMargin)
  }

  @Test
  func `DM reaction truncates long messages`() {
    let longText = String(repeating: "b", count: 200)
    let text = ReactionParser.buildDMReactionText(
      emoji: "👍",
      targetText: longText,
      targetTimestamp: 100
    )
    // Must fit within the DM ceiling, with the safety margin reserved.
    #expect(text.utf8.count <= ProtocolLimits.maxDirectMessageLength - ReactionParser.reactionByteMargin)
    #expect(text.contains("..."))

    // Must still round-trip parse
    let parsed = ReactionParser.parseDM(text)
    #expect(parsed != nil)
    #expect(parsed?.emoji == "👍")
  }

  @Test
  func `Truncation respects multi-byte character boundaries`() {
    // Each emoji is 4 bytes — truncation should not split one
    let emojiText = String(repeating: "🎉", count: 50) // 200 bytes
    let text = ReactionParser.buildDMReactionText(
      emoji: "👍",
      targetText: emojiText,
      targetTimestamp: 100
    )
    #expect(text.utf8.count <= ProtocolLimits.maxDirectMessageLength)

    // The truncated snippet should not contain broken UTF-8
    let parsed = ReactionParser.parseDM(text)
    #expect(parsed != nil)
  }

  // MARK: - Emoji Field Validation

  @Test
  func `Rejects an emoji field carrying the summary delimiters in every format`() {
    // `👍:9,👎` would round-trip through buildSummary/parseSummary as ten fabricated
    // reactions. Rejected, the text stays a plain message — what a client with no
    // reactions support shows anyway.
    #expect(ReactionParser.parse("👍:9,👎 reacted to [Alpha]: \"hi\" (a1b2c3d4)") == nil)
    #expect(ReactionParser.parseDM("👍:9,👎 reacted to: \"hi\" (a1b2c3d4)") == nil)
    #expect(ReactionParser.parse("👍:9,👎@[Alpha]\na1b2c3d4") == nil)
    #expect(ReactionParser.parseDM("👍:9,👎\na1b2c3d4") == nil)
  }

  @Test
  func `Rejects an emoji field holding more than one emoji`() {
    #expect(ReactionParser.parse("👍👎@[Alpha]\na1b2c3d4") == nil)
    #expect(ReactionParser.parseDM("👍👎\na1b2c3d4") == nil)
    #expect(ReactionParser.parse("👍👎 reacted to [Alpha]: \"hi\" (a1b2c3d4)") == nil)
    #expect(ReactionParser.parseDM("👍👎 reacted to: \"hi\" (a1b2c3d4)") == nil)
  }

  @Test
  func `Rejects an emoji field padded with text or whitespace`() {
    #expect(ReactionParser.parse("👍 @[Alpha]\na1b2c3d4") == nil)
    #expect(ReactionParser.parse("👍!@[Alpha]\na1b2c3d4") == nil)
    #expect(ReactionParser.parseDM("👍 \na1b2c3d4") == nil)
  }

  @Test
  func `Accepts the composed emoji forms real clients send`() {
    // Single grapheme clusters built from joiners, variation selectors, skin-tone
    // modifiers, regional indicators, keycap marks and flag tag characters.
    for emoji in ["👍", "❤️", "👍🏽", "👨‍👩‍👧", "🇺🇸", "1️⃣", "🏴󠁧󠁢󠁳󠁣󠁴󠁿", "❤️‍🔥"] {
      #expect(
        ReactionParser.parse("\(emoji)@[Alpha]\na1b2c3d4")?.emoji == emoji,
        "\(emoji) is a legitimate reaction"
      )
      #expect(ReactionParser.parseDM("\(emoji)\na1b2c3d4")?.emoji == emoji)
    }
  }

  @Test
  func `isReactionText ignores a meshcore-open v1 string with an injected emoji field`() {
    // meshcore-open v1 carries a free-text emoji field; the receive handlers reject an
    // invalid one, and this classifier has to agree or the text would be dropped from
    // the reaction index while still displaying as a plain message.
    #expect(ReactionParser.isReactionText("r:1704067200000_123_456:👍", isDM: true))
    #expect(!ReactionParser.isReactionText("r:1704067200000_123_456:👍,9", isDM: true))
  }

  // MARK: - Snippet Sanitization

  @Test
  func `Snippet neutralizes an echoed at-bracket so the structural one stays first`() {
    let targetText = "ping @[AlphaNode] when you arrive"
    let text = ReactionParser.buildChannelReactionText(
      emoji: "👍",
      targetSender: "AlphaNode",
      targetText: targetText,
      targetTimestamp: 100,
      localNodeNameByteCount: "Me".utf8.count
    )
    let parsed = ReactionParser.parse(text)

    #expect(parsed?.emoji == "👍")
    #expect(parsed?.targetSender == "AlphaNode")
    #expect(parsed?.messageHash == ReactionParser.generateMessageHash(
      text: targetText,
      timestamp: 100
    ))
    // The echoed `@[` is split with a no-break space — invisible in display, but no
    // first-match parser (ours or upstream's) can mistake it for the sender field.
    #expect(text.contains("@\u{00A0}[AlphaNode] when"))
  }

  @Test
  func `Snippet replaces the summary-cache delimiters and line breaks with spaces`() {
    // `:` and `,` land verbatim in upstream MC1's `{emoji}:{count}` summary cache if
    // they survive into the phrase; line breaks would sit above the trailing hash line.
    let targetText = "meet at 5:30,\nbring snacks"
    let text = ReactionParser.buildDMReactionText(
      emoji: "👍",
      targetText: targetText,
      targetTimestamp: 100
    )

    #expect(text.contains("\"meet at 5 30 bring snacks\""))
    let parsed = ReactionParser.parseDM(text)
    #expect(parsed?.emoji == "👍")
    #expect(parsed?.messageHash == ReactionParser.generateMessageHash(
      text: targetText,
      timestamp: 100
    ))
  }

  @Test
  func `DM reaction round-trips when the target text contains the channel marker`() {
    // The v3 phrase check is positional, so a snippet may echo any marker verbatim.
    let targetText = "who reacted to [that] anyway"
    let text = ReactionParser.buildDMReactionText(
      emoji: "👍",
      targetText: targetText,
      targetTimestamp: 1_704_067_200
    )
    let parsed = ReactionParser.parseDM(text)

    #expect(parsed?.emoji == "👍")
    #expect(parsed?.messageHash == ReactionParser.generateMessageHash(
      text: targetText,
      timestamp: 1_704_067_200
    ))
  }

  @Test
  func `An unsanitized peer DM whose snippet quotes the channel marker still parses`() {
    // Old builds emit the snippet verbatim. The format check is positional — everything
    // before the first marker must be the emoji — so an embedded marker no longer
    // disqualifies the whole string.
    let text = "👍 reacted to: \"who reacted to [that] anyway\" (a1b2c3d4)"
    let parsed = ReactionParser.parseDM(text)

    #expect(parsed?.emoji == "👍")
    #expect(parsed?.messageHash == "a1b2c3d4")
  }

  @Test
  func `DM parsing still rejects a channel-format string whose snippet quotes the DM marker`() {
    #expect(ReactionParser.parseDM("👍 reacted to [Alpha]: \"he reacted to: hi\" (a1b2c3d4)") == nil)
  }

  // MARK: - Total Budget Clamp

  @Test
  func `A hostile target sender yields the brackets rather than the hash`() {
    // 200 bytes of sender against the tightest budget (31-byte node name): the sender is
    // display data, the trailing hash is identity, so the sender is what gets cut.
    let localNodeName = String(repeating: "x", count: 31)
    let text = ReactionParser.buildChannelReactionText(
      emoji: "👍",
      targetSender: String(repeating: "s", count: 200),
      targetText: "Hello world",
      targetTimestamp: 100,
      localNodeNameByteCount: localNodeName.utf8.count
    )
    let budget = ProtocolLimits.maxChannelMessageLength(
      nodeNameByteCount: localNodeName.utf8.count
    )

    #expect(text.utf8.count <= budget - ReactionParser.reactionByteMargin)
    let parsed = ReactionParser.parse(text)
    #expect(parsed?.emoji == "👍")
    #expect(parsed?.messageHash == ReactionParser.generateMessageHash(
      text: "Hello world",
      timestamp: 100
    ))
  }

  @Test
  func `A hostile sender and a long target text still leave the hash intact`() {
    for nodeNameBytes in [2, 12, 31] {
      let text = ReactionParser.buildChannelReactionText(
        emoji: "👨‍👩‍👧",
        targetSender: String(repeating: "é", count: 80), // 160 UTF-8 bytes
        targetText: String(repeating: "a", count: 200),
        targetTimestamp: 100,
        localNodeNameByteCount: nodeNameBytes
      )
      let budget = ProtocolLimits.maxChannelMessageLength(nodeNameByteCount: nodeNameBytes)

      #expect(text.utf8.count <= budget - ReactionParser.reactionByteMargin,
              "must fit the \(nodeNameBytes)-byte-node-name budget")
      #expect(ReactionParser.parse(text) != nil, "the hash must survive the clamp")
    }
  }

  // MARK: - Piggyback (v3) Format Tests

  @Test
  func `Parses piggyback channel reaction`() {
    let text = "👍 reacted to \"Hello\" @[AlphaNode]\na1b2c3d4"
    let result = ReactionParser.parse(text)

    #expect(result?.emoji == "👍")
    #expect(result?.targetSender == "AlphaNode")
    #expect(result?.messageHash == "a1b2c3d4")
  }

  @Test
  func `Parses piggyback DM reaction`() {
    let text = "👍 reacted to \"Hello\"\na1b2c3d4"
    let result = ReactionParser.parseDM(text)

    #expect(result?.emoji == "👍")
    #expect(result?.messageHash == "a1b2c3d4")
  }

  @Test
  func `Piggyback hash is normalized to lowercase`() {
    let result = ReactionParser.parse("👍 reacted to \"Hello\" @[Node]\nABCDEF12")
    #expect(result?.messageHash == "abcdef12")
  }

  @Test
  func `Piggyback channel rejects a phrase without the marker`() {
    #expect(ReactionParser.parse("👍 hello there @[Node]\na1b2c3d4") == nil)
  }

  @Test
  func `Piggyback requires an emoji-led phrase`() {
    #expect(ReactionParser.parse("A reacted to \"hi\" @[Node]\na1b2c3d4") == nil)
    #expect(ReactionParser.parseDM("A reacted to \"hi\"\na1b2c3d4") == nil)
  }

  @Test
  func `Piggyback rejects a multi-emoji phrase lead`() {
    #expect(ReactionParser.parse("👍👎 reacted to \"hi\" @[Node]\na1b2c3d4") == nil)
    #expect(ReactionParser.parseDM("👍👎 reacted to \"hi\"\na1b2c3d4") == nil)
  }

  @Test
  func `Piggyback DM parser rejects the channel form`() {
    #expect(ReactionParser.parseDM("👍 reacted to \"Hello\" @[AlphaNode]\na1b2c3d4") == nil)
  }

  @Test
  func `isReactionText recognizes the piggyback formats`() {
    #expect(ReactionParser.isReactionText("👍 reacted to \"Hello\" @[Node]\na1b2c3d4", isDM: false))
    #expect(ReactionParser.isReactionText("👍 reacted to \"Hello\"\na1b2c3d4", isDM: true))
  }

  // MARK: - Upstream MC1 v1-Parser Compatibility

  /// Reimplements stock upstream MC1 v1.3.0's reaction parsing semantics (v1-only
  /// grammar: hash after the last newline, first `@[` starts the sender, emoji field
  /// merely has to *start* with an emoji). Emit changes are checked against this so
  /// the piggyback format keeps parsing as a reaction on the app fielded users run.
  private enum UpstreamV1Parser {
    static func parse(_ text: String) -> (emojiField: String, sender: String, hash: String)? {
      guard let newlineIndex = text.lastIndex(of: "\n") else { return nil }
      let rawHash = String(text[text.index(after: newlineIndex)...])
      guard rawHash.count == 8 else { return nil }
      let withoutHash = String(text[..<newlineIndex])
      guard let atBracket = withoutHash.range(of: "@[") else { return nil }
      let emojiField = String(withoutHash[..<atBracket.lowerBound])
      guard !emojiField.isEmpty, emojiField.first?.isEmoji == true else { return nil }
      let afterAtBracket = withoutHash[atBracket.upperBound...]
      guard afterAtBracket.hasSuffix("]") else { return nil }
      let sender = String(afterAtBracket.dropLast())
      guard !sender.isEmpty else { return nil }
      return (emojiField, sender, rawHash.lowercased())
    }

    static func parseDM(_ text: String) -> (emojiField: String, hash: String)? {
      if text.contains("@[") { return nil }
      guard let newlineIndex = text.lastIndex(of: "\n") else { return nil }
      let rawHash = String(text[text.index(after: newlineIndex)...])
      guard rawHash.count == 8 else { return nil }
      let emojiField = String(text[..<newlineIndex])
      guard !emojiField.isEmpty, emojiField.first?.isEmoji == true else { return nil }
      return (emojiField, rawHash.lowercased())
    }
  }

  @Test
  func `Channel piggyback parses on stock upstream MC1 with exact sender and hash`() {
    let targetText = "see you at the meetup"
    let expectedHash = ReactionParser.generateMessageHash(text: targetText, timestamp: 100)
    let text = ReactionParser.buildChannelReactionText(
      emoji: "👍",
      targetSender: "AlphaNode",
      targetText: targetText,
      targetTimestamp: 100,
      localNodeNameByteCount: 12
    )
    let upstream = UpstreamV1Parser.parse(text)

    #expect(upstream?.sender == "AlphaNode")
    #expect(upstream?.hash == expectedHash)
    #expect(upstream?.emojiField.first == "👍")
  }

  @Test
  func `DM piggyback parses on stock upstream MC1 with exact hash`() {
    let targetText = "see you at the meetup"
    let expectedHash = ReactionParser.generateMessageHash(text: targetText, timestamp: 100)
    let text = ReactionParser.buildDMReactionText(
      emoji: "❤️",
      targetText: targetText,
      targetTimestamp: 100
    )
    let upstream = UpstreamV1Parser.parseDM(text)

    #expect(upstream?.hash == expectedHash)
    #expect(upstream?.emojiField.first == "❤️")
  }

  @Test
  func `Piggyback phrase never carries upstream's summary-cache delimiters`() {
    // Upstream stores the whole phrase as its emoji field and caches it as
    // `{emoji}:{count}` pairs joined by `,` — a `:` or `,` in the phrase corrupts
    // every badge on the message, so the built phrase must never contain one.
    let hostileText = "5:30, at the @[old] spot,\nbring: snacks"

    let channel = ReactionParser.buildChannelReactionText(
      emoji: "👍",
      targetSender: "Alpha",
      targetText: hostileText,
      targetTimestamp: 100,
      localNodeNameByteCount: 2
    )
    let channelPhrase = UpstreamV1Parser.parse(channel)?.emojiField
    #expect(channelPhrase != nil)
    #expect(channelPhrase?.contains(":") == false)
    #expect(channelPhrase?.contains(",") == false)
    #expect(UpstreamV1Parser.parse(channel)?.sender == "Alpha")

    let dm = ReactionParser.buildDMReactionText(
      emoji: "👍",
      targetText: hostileText,
      targetTimestamp: 100
    )
    let dmPhrase = UpstreamV1Parser.parseDM(dm)?.emojiField
    #expect(dmPhrase != nil)
    #expect(dmPhrase?.contains(":") == false)
    #expect(dmPhrase?.contains(",") == false)
  }

  @Test
  func `An upstream badge-tap echo of the piggyback phrase parses back as a clean tapback`() {
    // Stock MC1 stores the whole phrase as the emoji and rebuilds
    // `{emoji}@[{sender}]\n{hash}` when its user taps the badge — which reproduces
    // the piggyback string byte-for-byte, so the echo lands here as a tapback too.
    let text = ReactionParser.buildChannelReactionText(
      emoji: "👍",
      targetSender: "AlphaNode",
      targetText: "see you at the meetup",
      targetTimestamp: 100,
      localNodeNameByteCount: 12
    )
    guard let upstream = UpstreamV1Parser.parse(text) else {
      Issue.record("upstream parse must succeed")
      return
    }
    let echoed = "\(upstream.emojiField)@[\(upstream.sender)]\n\(upstream.hash)"

    #expect(echoed == text)
    #expect(ReactionParser.parse(echoed)?.emoji == "👍")
    #expect(ReactionParser.parse(echoed)?.targetSender == "AlphaNode")
  }

  // MARK: - Legacy (v1) Compatibility on Receive

  @Test
  func `Legacy v1 channel format still parses after v3 became canonical`() {
    let result = ReactionParser.parse("👍@[AlphaNode]\n7f3a9c12")
    #expect(result?.emoji == "👍")
    #expect(result?.targetSender == "AlphaNode")
    #expect(result?.messageHash == "7f3a9c12")
  }

  @Test
  func `Legacy v1 DM format still parses after v3 became canonical`() {
    let result = ReactionParser.parseDM("👍\n7f3a9c12")
    #expect(result?.emoji == "👍")
    #expect(result?.messageHash == "7f3a9c12")
  }
}
