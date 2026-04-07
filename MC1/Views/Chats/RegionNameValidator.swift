import Foundation

extension String {
    /// Whether this region name represents a private region (prefixed with "$")
    var isPrivateRegion: Bool { hasPrefix("$") }
}

/// Validates region names before adding them to the device's known regions list
enum RegionNameValidator {
    enum ValidationError {
        case empty
        case invalidCharacters
        case invalidPrefix
        case duplicate
    }

    private static let disallowedCharacters = CharacterSet.controlCharacters.union(.whitespaces)

    static func validate(_ name: String, existingRegions: [String]) -> ValidationError? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .empty }
        if trimmed.unicodeScalars.contains(where: { disallowedCharacters.contains($0) }) {
            return .invalidCharacters
        }
        if trimmed.isPrivateRegion || trimmed.hasPrefix("#") { return .invalidPrefix }
        if existingRegions.contains(trimmed) { return .duplicate }
        return nil
    }

    static func isValid(_ name: String, existingRegions: [String]) -> Bool {
        validate(name, existingRegions: existingRegions) == nil
    }
}
