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
  func `Builds DM reaction text in human-readable format`() {
    let text = ReactionParser.buildDMReactionText(
      emoji: "👍",
      targetText: "Hello world",
      targetTimestamp: 1_704_067_200
    )
    #expect(text.hasPrefix("👍 reacted to: \"Hello world\""))
    #expect(text.hasSuffix(")"))
    #expect(!text.contains("@["))
    #expect(!text.contains("\n"))
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

  // MARK: - Human-Readable Build + Round-Trip Tests

  @Test
  func `Builds channel reaction text in human-readable format`() {
    let text = ReactionParser.buildChannelReactionText(
      emoji: "👍",
      targetSender: "AlphaNode",
      targetText: "Hello world",
      targetTimestamp: 1_704_067_200,
      localNodeNameByteCount: "Me".utf8.count
    )
    #expect(text.hasPrefix("👍 reacted to [AlphaNode]: \"Hello world\""))
    #expect(text.hasSuffix(")"))
    #expect(!text.contains("\n"))
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
  func `DM round-trip with human-readable format`() {
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

  // MARK: - Legacy (v1) Compatibility on Receive

  @Test
  func `Legacy v1 channel format still parses after v2 became canonical`() {
    let result = ReactionParser.parse("👍@[AlphaNode]\n7f3a9c12")
    #expect(result?.emoji == "👍")
    #expect(result?.targetSender == "AlphaNode")
    #expect(result?.messageHash == "7f3a9c12")
  }

  @Test
  func `Legacy v1 DM format still parses after v2 became canonical`() {
    let result = ReactionParser.parseDM("👍\n7f3a9c12")
    #expect(result?.emoji == "👍")
    #expect(result?.messageHash == "7f3a9c12")
  }
}
