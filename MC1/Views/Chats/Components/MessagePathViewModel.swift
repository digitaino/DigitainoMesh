import CoreLocation
import OSLog
import MC1Services
import SwiftUI

/// Info about a resolved hop including ambiguity data.
struct ResolvedHop {
    let name: String
    let candidateCount: Int
    /// Location of the resolved repeater, if known. Used to chain anchor locations.
    let location: CLLocation?
    var isAmbiguous: Bool { candidateCount > 1 }
}

/// A candidate repeater for disambiguation, with location and metadata.
struct HopCandidate: Identifiable {
    let id = UUID()
    let name: String
    let latitude: Double
    let longitude: Double
    let hasLocation: Bool
    let distanceFromUser: Double?
    let lastHeard: String

    init(from node: some RepeaterResolvable, userLocation: CLLocation?) {
        self.name = node.resolvableName
        self.latitude = node.latitude
        self.longitude = node.longitude
        self.hasLocation = node.hasLocation
        if let userLocation, node.hasLocation {
            let nodeLoc = CLLocation(latitude: node.latitude, longitude: node.longitude)
            self.distanceFromUser = userLocation.distance(from: nodeLoc)
        } else {
            self.distanceFromUser = nil
        }
        let date = node.recencyDate
        if date.timeIntervalSince1970 > 0 {
            self.lastHeard = date.formatted(.relative(presentation: .named))
        } else {
            self.lastHeard = L10n.Chats.Chats.Path.Hop.unknown
        }
    }
}

@Observable
@MainActor
final class MessagePathViewModel {
    var contacts: [ContactDTO] = []
    var repeaters: [ContactDTO] = []
    var discoveredRepeaters: [DiscoveredNodeDTO] = []
    var isLoading = true

    /// User-chosen overrides for ambiguous hops, keyed by hop hash hex string.
    var hopOverrides: [String: String] = [:]

    /// In-memory persistence of hop overrides across view model instances.
    /// Keyed by message UUID → [hopHex: repeaterName].
    private static var persistedOverrides: [UUID: [String: String]] = [:]

    /// Retrieve persisted overrides for a message (used by uploadRouteToServer).
    static func overrides(for messageID: UUID) -> [String: String] {
        persistedOverrides[messageID] ?? [:]
    }

    // MARK: - Cached Resolution Results

    /// The resolved hops for the current message, in order.
    /// Populated by `resolveAllHops(message:userLocation:)`.
    private(set) var resolvedHops: [(hashBytes: Data, hex: String, resolved: ResolvedHop)] = []

    /// Quick lookup of resolved hop by hex key.
    private(set) var resolvedByHex: [String: ResolvedHop] = [:]

    /// Computed route distance using the resolved locations (single source of truth).
    private(set) var routeDistanceText: String?

    private let logger = Logger(subsystem: "com.mc1", category: "MessagePathViewModel")

    func loadContacts(services: ServiceContainer?, deviceID: UUID) async {
        isLoading = true
        guard let services else {
            isLoading = false
            return
        }

        do {
            let fetched = try await services.dataStore.fetchContacts(deviceID: deviceID)
            contacts = fetched
            repeaters = fetched.filter { $0.type == .repeater }
            let nodes = try await services.dataStore.fetchDiscoveredNodes(deviceID: deviceID)
            discoveredRepeaters = nodes.filter { $0.nodeType == .repeater }
        } catch {
            logger.error("Failed to load contacts: \(error.localizedDescription)")
            contacts = []
            repeaters = []
            discoveredRepeaters = []
        }

        isLoading = false
    }

    /// All contacts (used by details rows for distance calculation)
    var allContacts: [ContactDTO] { contacts }

    /// All discovered repeater nodes
    var allDiscoveredNodes: [DiscoveredNodeDTO] { discoveredRepeaters }

    // MARK: - Sender Info

    func senderName(for message: MessageDTO) -> String {
        if message.isChannelMessage, let nodeName = message.senderNodeName {
            return nodeName
        }

        if let keyPrefix = message.senderKeyPrefix,
           let match = contacts.first(where: { $0.publicKeyPrefix == keyPrefix }) {
            return match.displayName
        }

        return L10n.Chats.Chats.Path.Hop.unknown
    }

    func senderNodeID(for message: MessageDTO) -> String? {
        guard let keyPrefix = message.senderKeyPrefix,
              let firstByte = keyPrefix.first else { return nil }
        return String(format: "%02X", firstByte)
    }

    func senderLocation(for message: MessageDTO) -> CLLocation? {
        guard let keyPrefix = message.senderKeyPrefix,
              let match = contacts.first(where: { $0.publicKeyPrefix == keyPrefix }),
              match.hasLocation else { return nil }
        return CLLocation(latitude: match.latitude, longitude: match.longitude)
    }

    // MARK: - Resolve All Hops (Single Source of Truth)

    /// Resolves all hops in a message using bidirectional anchor chaining.
    /// This is the **single source of truth** for hop resolution. All consumers
    /// (path display, disambiguation sheet, distance, map) read from the results.
    ///
    /// Call this once after loading contacts, and again after any override change.
    func resolveAllHops(message: MessageDTO, userLocation: CLLocation?) {
        // Load persisted overrides for this message (supports fresh VM instances)
        if hopOverrides.isEmpty, let persisted = Self.persistedOverrides[message.id], !persisted.isEmpty {
            hopOverrides = persisted
        }

        let hops = parsePathHops(from: message)
        guard !hops.isEmpty else {
            resolvedHops = []
            resolvedByHex = [:]
            routeDistanceText = nil
            return
        }

        let senderLoc = senderLocation(for: message)

        // Centralized pool builder: filters stale discovered nodes and merges
        // with contacts. All resolution paths use this same method.
        let allNodes = RepeaterResolver.buildNodePool(
            repeaters: repeaters, discoveredNodes: discoveredRepeaters
        )

        // Forward pass: sender → receiver
        var forwardResults: [ResolvedHop] = []
        var forwardAnchor: CLLocation? = senderLoc
        var forwardHadAnchor: [Bool] = []

        for hop in hops {
            let hadAnchor = forwardAnchor != nil
            let resolved = resolveSingleHop(
                hashBytes: hop.data, in: allNodes,
                userLocation: userLocation, anchorLocation: forwardAnchor
            )
            forwardResults.append(resolved)
            forwardHadAnchor.append(hadAnchor)
            if let loc = resolved.location { forwardAnchor = loc }
        }

        // Backward pass: receiver → sender
        var backwardResults: [ResolvedHop] = []
        var backwardAnchor: CLLocation? = userLocation
        var backwardHadAnchor: [Bool] = []

        for hop in hops.reversed() {
            let hadAnchor = backwardAnchor != nil
            let resolved = resolveSingleHop(
                hashBytes: hop.data, in: allNodes,
                userLocation: userLocation, anchorLocation: backwardAnchor
            )
            backwardResults.append(resolved)
            backwardHadAnchor.append(hadAnchor)
            if let loc = resolved.location { backwardAnchor = loc }
        }
        backwardResults.reverse()
        backwardHadAnchor.reverse()

        // Merge: for each hop, pick the result from the closer end
        var results: [(hashBytes: Data, hex: String, resolved: ResolvedHop)] = []
        var lookup: [String: ResolvedHop] = [:]

        for i in hops.indices {
            let useBackward: Bool
            if forwardHadAnchor[i] && backwardHadAnchor[i] {
                let distFromSender = i
                let distFromReceiver = hops.count - 1 - i
                useBackward = distFromReceiver < distFromSender
            } else {
                useBackward = backwardHadAnchor[i] && !forwardHadAnchor[i]
            }
            let resolved = useBackward ? backwardResults[i] : forwardResults[i]
            results.append((hops[i].data, hops[i].hex, resolved))
            lookup[hops[i].hex] = resolved
        }

        resolvedHops = results
        resolvedByHex = lookup

        // Compute route distance from the resolved locations
        computeRouteDistance(message: message, userLocation: userLocation)

        // Persist overrides (including any stale cleanup from resolution)
        if !hopOverrides.isEmpty {
            Self.persistedOverrides[message.id] = hopOverrides
        } else {
            Self.persistedOverrides.removeValue(forKey: message.id)
        }
    }

    // MARK: - Single Hop Resolution (internal)

    /// Resolves a single hop against the merged node pool, respecting user overrides.
    private func resolveSingleHop(
        hashBytes: Data,
        in allNodes: [AnyResolvable],
        userLocation: CLLocation?,
        anchorLocation: CLLocation?
    ) -> ResolvedHop {
        let hexKey = hashBytes.hexString()
        let deduped = candidates(for: hashBytes, userLocation: userLocation)

        // Check for user override
        if let overrideName = hopOverrides[hexKey] {
            if let match = deduped.first(where: { $0.name == overrideName }) {
                let loc = match.hasLocation
                    ? CLLocation(latitude: match.latitude, longitude: match.longitude)
                    : nil
                return ResolvedHop(name: overrideName, candidateCount: deduped.count, location: loc)
            }
            // Override is stale — remove it
            hopOverrides.removeValue(forKey: hexKey)
        }

        if let result = RepeaterResolver.resolve(
            for: hashBytes, in: allNodes,
            userLocation: userLocation, anchorLocation: anchorLocation
        ) {
            let loc = result.best.hasLocation
                ? CLLocation(latitude: result.best.latitude, longitude: result.best.longitude)
                : nil
            return ResolvedHop(name: result.best.resolvableName, candidateCount: deduped.count, location: loc)
        }

        return ResolvedHop(name: L10n.Chats.Chats.Path.Hop.unknown, candidateCount: 0, location: nil)
    }

    // MARK: - Route Distance

    /// Computes route distance from the resolved hop locations (not re-resolving).
    private func computeRouteDistance(message: MessageDTO, userLocation: CLLocation?) {
        var coordinates: [CLLocationCoordinate2D] = []
        var hasGaps = false

        // Sender location
        if let senderLoc = senderLocation(for: message) {
            coordinates.append(senderLoc.coordinate)
        }

        // Intermediate hops from cached resolved results
        for entry in resolvedHops {
            if let loc = entry.resolved.location {
                coordinates.append(loc.coordinate)
            } else if entry.resolved.name != L10n.Chats.Chats.Path.Hop.unknown {
                // Known repeater but no location — this is a gap
                hasGaps = true
            }
        }

        // Receiver location
        if let userLocation {
            coordinates.append(userLocation.coordinate)
        }

        let totalMeters = RouteDistanceCalculator.chainDistance(between: coordinates)
        if totalMeters > 0 {
            routeDistanceText = RouteDistanceCalculator.formatTotal(totalMeters, hasGaps: hasGaps)
        } else {
            routeDistanceText = nil
        }
    }

    // MARK: - Path Parsing

    private func parsePathHops(from message: MessageDTO) -> [(data: Data, hex: String)] {
        guard let pathNodes = message.pathNodes else { return [] }
        let size = message.pathHashSize
        return stride(from: 0, to: pathNodes.count, by: size).map { start in
            let end = min(start + size, pathNodes.count)
            let chunk = Data(pathNodes[start..<end])
            return (chunk, chunk.hexString())
        }
    }

    // MARK: - Disambiguation

    /// Get all candidates for a hop (for the disambiguation UI).
    /// Deduplicates by name so the same repeater from contacts and discovered nodes
    /// only appears once (preferring the contact version which has richer data).
    /// Filters out very stale discovered nodes (>30 days) that are likely offline.
    func candidates(for hashBytes: Data, userLocation: CLLocation?) -> [HopCandidate] {
        let contactCandidates = RepeaterResolver.sortedCandidates(for: hashBytes, in: repeaters, userLocation: userLocation)
            .map { HopCandidate(from: $0, userLocation: userLocation) }

        // Use centralized stale filter for discovered nodes
        let freshDiscovered = RepeaterResolver.filterFresh(discoveredRepeaters)
        let discoveredCandidates = RepeaterResolver.sortedCandidates(for: hashBytes, in: freshDiscovered, userLocation: userLocation)
            .map { HopCandidate(from: $0, userLocation: userLocation) }

        // Deduplicate: keep contacts over discovered nodes for the same name
        var seenNames = Set<String>()
        var result: [HopCandidate] = []
        for candidate in contactCandidates + discoveredCandidates {
            if seenNames.insert(candidate.name).inserted {
                result.append(candidate)
            }
        }
        return result
    }

    /// Set a user override for an ambiguous hop, then re-resolve everything.
    func setOverride(for hashBytes: Data, name: String, message: MessageDTO, userLocation: CLLocation?) {
        hopOverrides[hashBytes.hexString()] = name
        Self.persistedOverrides[message.id] = hopOverrides
        resolveAllHops(message: message, userLocation: userLocation)
    }

    /// Clear a user override for a hop, then re-resolve everything.
    func clearOverride(for hashBytes: Data, message: MessageDTO, userLocation: CLLocation?) {
        hopOverrides.removeValue(forKey: hashBytes.hexString())
        if hopOverrides.isEmpty {
            Self.persistedOverrides.removeValue(forKey: message.id)
        } else {
            Self.persistedOverrides[message.id] = hopOverrides
        }
        resolveAllHops(message: message, userLocation: userLocation)
    }
}
