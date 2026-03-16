import Foundation

/// Time-based filter for the map view to show only recently heard nodes.
enum MapTimeFilter: String, CaseIterable, Identifiable {
    case allTime
    case days5
    case days3
    case day1
    case hours12
    case hour1

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .allTime: "All Time"
        case .days5: "5 Days"
        case .days3: "3 Days"
        case .day1: "1 Day"
        case .hours12: "12 Hours"
        case .hour1: "1 Hour"
        }
    }

    /// Maximum age in seconds, or nil for no limit.
    var maxAge: TimeInterval? {
        switch self {
        case .allTime: nil
        case .days5: 5 * 24 * 3600
        case .days3: 3 * 24 * 3600
        case .day1: 24 * 3600
        case .hours12: 12 * 3600
        case .hour1: 3600
        }
    }
}
