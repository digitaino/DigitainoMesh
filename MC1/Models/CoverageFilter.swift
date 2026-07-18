/// Coverage filter for community survey data (all / active / passive).
/// Shared by the survey map and the main map's community overlay.
enum CoverageFilter: String, CaseIterable {
    case all = "All"
    case active = "Active"
    case passive = "Passive"
}
