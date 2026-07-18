import Foundation

/// Helpers for working with repeater hex IDs shared across map and survey views.
enum RepeaterHexID {

    /// Consolidates hex IDs that are prefixes of each other, keeping the longest version.
    /// Delegates to the canonical implementation in SurveyExportService.
    static func consolidate(_ hexIDs: [String]) -> [String] {
        SurveyExportService.consolidateHexIDs(hexIDs)
    }
}
