import Fluent
import SQLKit

/// One-time migration to consolidate duplicate repeater_locations entries.
///
/// The problem: the same physical repeater (e.g. "Digitaino Central") could appear
/// multiple times with different hex IDs (e.g. 0C07, 0C13, 0C37) because:
/// - Different MeshCore hash modes produce different-length path hashes
/// - Reflashed devices generate new key pairs but keep the same name
/// - Survey uploads didn't include the full public key, so the server couldn't match
///
/// This migration groups repeaters by (name, approximate location) and keeps only the
/// one with the newest data, deleting the rest and updating cell_repeaters references.
struct ConsolidateDuplicateRepeaters: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            database.logger.warning("ConsolidateDuplicateRepeaters: skipping (not SQL database)")
            return
        }

        // Load all repeater locations
        let allRepeaters = try await RepeaterLocation.query(on: database).all()
        guard allRepeaters.count > 1 else { return }

        // Group by normalized name
        var byName: [String: [RepeaterLocation]] = [:]
        for repeater in allRepeaters {
            let key = repeater.name.trimmingCharacters(in: .whitespaces).lowercased()
            byName[key, default: []].append(repeater)
        }

        var totalDeleted = 0
        var totalRefsUpdated = 0

        for (name, group) in byName {
            guard group.count > 1 else { continue }

            // Within each name group, cluster by proximity (1km)
            var clusters: [[RepeaterLocation]] = []
            var assigned = Set<Int>()

            for (i, repeater) in group.enumerated() {
                guard !assigned.contains(i) else { continue }
                var cluster = [repeater]
                assigned.insert(i)

                for (j, other) in group.enumerated() where j > i && !assigned.contains(j) {
                    let dist = approxDistanceMeters(
                        lat1: repeater.latitude, lon1: repeater.longitude,
                        lat2: other.latitude, lon2: other.longitude
                    )
                    if dist < 1000 { // 1km
                        cluster.append(other)
                        assigned.insert(j)
                    }
                }

                if cluster.count > 1 {
                    clusters.append(cluster)
                }
            }

            for cluster in clusters {
                // Pick the "best" record to keep:
                // Prefer the one with a public key, then the newest lastUpdated
                let keeper = cluster.sorted { a, b in
                    // Prefer one with public key
                    if (a.publicKey != nil) != (b.publicKey != nil) {
                        return a.publicKey != nil
                    }
                    // Prefer newest lastUpdated
                    return (a.lastUpdated) > (b.lastUpdated)
                }.first!

                let duplicates = cluster.filter { $0.id != keeper.id }
                guard !duplicates.isEmpty else { continue }

                let keeperHexID = keeper.hexID
                let duplicateIDs = duplicates.compactMap(\.id)
                let duplicateHexIDs = duplicates.map(\.hexID)

                database.logger.info("Consolidating '\(name)': keeping \(keeperHexID), removing \(duplicateHexIDs.joined(separator: ", "))")

                // Update cell_repeaters references: point duplicate hex IDs to the keeper
                for dupHexID in duplicateHexIDs {
                    // Check if the keeper already has an entry for this cell
                    // If so, just delete the duplicate reference; if not, update it
                    let updateQuery = SQLQueryString("""
                        UPDATE cell_repeaters
                        SET repeater_hex_id = \(bind: keeperHexID)
                        WHERE repeater_hex_id = \(bind: dupHexID)
                        AND cell_id NOT IN (
                            SELECT cell_id FROM cell_repeaters WHERE repeater_hex_id = \(bind: keeperHexID)
                        )
                    """)
                    try await sql.raw(updateQuery).run()

                    // Delete any remaining duplicate cell_repeater rows (where the cell already
                    // had the keeper hex ID, so the UPDATE above was a no-op for those)
                    let deleteRefsQuery = SQLQueryString("""
                        DELETE FROM cell_repeaters
                        WHERE repeater_hex_id = \(bind: dupHexID)
                    """)
                    try await sql.raw(deleteRefsQuery).run()
                    totalRefsUpdated += 1
                }

                // Delete the duplicate repeater_locations entries
                for dupID in duplicateIDs {
                    let deleteQuery = SQLQueryString("""
                        DELETE FROM repeater_locations WHERE id = \(bind: dupID)
                    """)
                    try await sql.raw(deleteQuery).run()
                    totalDeleted += 1
                }
            }
        }

        database.logger.info("ConsolidateDuplicateRepeaters: deleted \(totalDeleted) duplicates, updated \(totalRefsUpdated) cell_repeater references")
    }

    func revert(on database: Database) async throws {
        // One-way migration — duplicates cannot be meaningfully restored
        database.logger.warning("ConsolidateDuplicateRepeaters: revert is a no-op")
    }

    // MARK: - Helpers

    private func approxDistanceMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let R = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) +
                 cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) *
                 sin(dLon / 2) * sin(dLon / 2)
        return R * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}
