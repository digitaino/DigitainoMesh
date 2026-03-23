import SwiftUI
import CoreLocation

/// A floating directional arrow and distance display for route navigation guidance.
/// Shows the bearing to the current waypoint relative to the user's heading.
struct RouteGuidanceOverlay: View {
    let route: RoutePlanner.Route
    let userHeading: CLLocationDirection?
    let userLocation: CLLocationCoordinate2D?

    var body: some View {
        if let currentIndex = route.currentWaypointIndex {
            let waypoint = route.waypoints[currentIndex]

            HStack(spacing: 12) {
                // Direction arrow that rotates toward current waypoint
                Image(systemName: "location.north.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.blue)
                    .rotationEffect(arrowRotation(toward: waypoint.center))

                VStack(alignment: .leading, spacing: 2) {
                    // Distance to current waypoint
                    if let userLoc = userLocation {
                        let dist = RoutePlanner.distance(from: userLoc, to: waypoint.center)
                        Text(RoutePlanner.formatDistance(dist))
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                    }

                    // Waypoint number
                    Text("Next: #\(currentIndex + 1)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Helpers

    private func arrowRotation(toward target: CLLocationCoordinate2D) -> Angle {
        guard let userLoc = userLocation else {
            return .degrees(0)
        }

        let bearing = RoutePlanner.bearing(from: userLoc, to: target)
        let heading = userHeading ?? 0

        // Arrow points toward target: rotate by (bearing - heading)
        // so when the user faces the target, arrow points up
        return .degrees(bearing - heading)
    }
}
