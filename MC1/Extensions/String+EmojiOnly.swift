import Foundation

extension String {
    /// Maximum number of emoji for the large rendering style.
    /// Messages with more emoji than this render at normal size.
    static let maxLargeEmojiCount = 3

    /// Regex matching strings composed entirely of emoji.
    ///
    /// Uses `\p{Extended_Pictographic}` — the Unicode standard category for ALL
    /// pictographic emoji (☕, 🍳, 😀, 🐦‍⬛, etc.) regardless of default presentation.
    /// Combined with joiners, modifiers, and regional indicators for compound emoji.
    private static let emojiOnlyRegex: NSRegularExpression? = {
        let pattern = [
            "^[",
            "\\p{Extended_Pictographic}",  // All pictographic emoji
            "\\p{Emoji_Modifier}",          // Skin tone modifiers
            "\\p{Regional_Indicator}",      // Flag components
            "\\x{FE0E}\\x{FE0F}",          // Variation selectors
            "\\x{200D}",                    // Zero-width joiner
            "\\x{20E3}",                    // Combining enclosing keycap
            "\\x{E0020}-\\x{E007F}",        // Tag characters (subdivision flags)
            "]+$",
        ].joined()
        return try? NSRegularExpression(pattern: pattern, options: [])
    }()

    /// Characters to strip before emoji detection.
    /// Wire-decoded messages (AES-128 ECB) may contain invisible characters
    /// between the text and null padding that aren't removed by whitespace trimming.
    /// NOTE: Does NOT use `.controlCharacters` because Foundation includes ZWJ (U+200D)
    /// and tag characters (U+E0020-E007F) in that set, which are needed for emoji sequences.
    private static let invisibleStripSet: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        // C0 controls (U+0000-U+001F) — NUL, SOH, etc.
        set.insert(charactersIn: Unicode.Scalar(0)!...Unicode.Scalar(0x1F)!)
        // DEL + C1 controls (U+007F-U+009F)
        set.insert(charactersIn: Unicode.Scalar(0x7F)!...Unicode.Scalar(0x9F)!)
        set.insert(Unicode.Scalar(0xFEFF)!)     // BOM
        set.insert(Unicode.Scalar(0x200B)!)     // Zero-Width Space
        set.insert(Unicode.Scalar(0x200C)!)     // ZWNJ (not used in emoji, unlike ZWJ)
        set.insert(Unicode.Scalar(0x00AD)!)     // Soft Hyphen
        set.insert(Unicode.Scalar(0x2060)!)     // Word Joiner
        return set
    }()

    /// Returns the string with invisible/control characters removed.
    /// Used for display and emoji detection of wire-decoded text.
    var strippingInvisibleCharacters: String {
        String(unicodeScalars.filter { !Self.invisibleStripSet.contains($0) })
    }

    /// Whether this message should render as large emoji (emoji-only, up to 3 emoji).
    /// Strips invisible characters that may be injected by the wire protocol before checking.
    var isLargeEmoji: Bool {
        // Filter out invisible characters (preserves ZWJ U+200D needed for compound emoji)
        let cleaned = strippingInvisibleCharacters
        guard !cleaned.isEmpty else { return false }
        // cleaned.count = grapheme clusters = visible emoji count
        guard cleaned.count <= Self.maxLargeEmojiCount else { return false }
        // Verify the entire string is emoji using Unicode regex
        guard let regex = Self.emojiOnlyRegex else { return false }
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        return regex.firstMatch(in: cleaned, range: range) != nil
    }
}

