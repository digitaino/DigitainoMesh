import Testing
@testable import MC1

@Suite("RegionNameValidator")
struct RegionNameValidatorTests {

    // MARK: - Valid Names

    @Test("accepts standard region names", arguments: [
        "Europe", "UK", "France", "sample-city", "region-1"
    ])
    func validNames(name: String) {
        #expect(RegionNameValidator.isValid(name, existingRegions: []))
    }

    @Test("accepts unicode region names")
    func unicodeRegionName() {
        #expect(RegionNameValidator.isValid("Île-de-France", existingRegions: []))
    }

    // MARK: - Invalid Names

    @Test("rejects empty name")
    func emptyNameIsInvalid() {
        #expect(RegionNameValidator.validate("", existingRegions: []) == .empty)
    }

    @Test("rejects whitespace-only name")
    func whitespaceOnlyIsInvalid() {
        #expect(RegionNameValidator.validate("   ", existingRegions: []) == .empty)
    }

    @Test("rejects name with spaces")
    func spacesInNameAreInvalid() {
        #expect(RegionNameValidator.validate("my region", existingRegions: []) == .invalidCharacters)
    }

    @Test("rejects hash prefix")
    func hashPrefixIsInvalid() {
        #expect(RegionNameValidator.validate("#Europe", existingRegions: []) == .invalidPrefix)
    }

    @Test("rejects dollar prefix")
    func dollarPrefixIsInvalid() {
        #expect(RegionNameValidator.validate("$secret", existingRegions: []) == .invalidPrefix)
    }

    // MARK: - Duplicates

    @Test("rejects duplicate region name")
    func duplicateIsInvalid() {
        #expect(RegionNameValidator.validate("Europe", existingRegions: ["Europe"]) == .duplicate)
    }

    @Test("duplicate check is case-sensitive")
    func caseSensitiveDuplicateCheck() {
        #expect(RegionNameValidator.isValid("europe", existingRegions: ["Europe"]))
    }

    // MARK: - isValid convenience

    @Test("isValid returns true for valid name")
    func isValidReturnsTrue() {
        #expect(RegionNameValidator.isValid("Europe", existingRegions: []))
    }

    @Test("isValid returns false for invalid name")
    func isValidReturnsFalse() {
        #expect(!RegionNameValidator.isValid("", existingRegions: []))
    }
}
