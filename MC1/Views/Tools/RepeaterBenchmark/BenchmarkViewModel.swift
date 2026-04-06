import Combine
import SwiftUI
import MeshCore
import MC1Services
import os.log

private let logger = Logger(subsystem: "com.mc1", category: "Benchmark")

// MARK: - Supporting Types

/// Aggregated results for a single benchmark target
struct BenchmarkTargetResult: Identifiable {
    let id = UUID()
    let target: ContactDTO
    var traceResults: [TraceResult]
    let savedPathID: UUID?
    /// Whether all traces have completed for this target
    var isComplete = false

    var successCount: Int { traceResults.filter(\.success).count }
    var totalCount: Int { traceResults.count }
    var successRate: Int {
        guard totalCount > 0 else { return 0 }
        return (successCount * 100) / totalCount
    }

    private var successfulResults: [TraceResult] { traceResults.filter(\.success) }

    var averageRTT: Int? {
        let rtts = successfulResults.map(\.durationMs)
        guard !rtts.isEmpty else { return nil }
        return rtts.reduce(0, +) / rtts.count
    }

    var minRTT: Int? { successfulResults.map(\.durationMs).min() }
    var maxRTT: Int? { successfulResults.map(\.durationMs).max() }

    /// TX SNR: how well the target hears the test repeater (outbound leg)
    /// Intermediate hop index 1 = target receiving from test repeater
    var txSNR: Double? {
        let snrs = successfulResults.compactMap { result -> Double? in
            let hops = result.hops.filter { !$0.isStartNode && !$0.isEndNode }
            guard hops.count >= 2 else { return nil }
            return hops[1].snr
        }
        guard !snrs.isEmpty else { return nil }
        return snrs.reduce(0, +) / Double(snrs.count)
    }

    /// RX SNR: how well the test repeater hears the target (return leg)
    /// Intermediate hop index 2 = test repeater receiving from target
    var rxSNR: Double? {
        let snrs = successfulResults.compactMap { result -> Double? in
            let hops = result.hops.filter { !$0.isStartNode && !$0.isEndNode }
            guard hops.count >= 3 else { return nil }
            return hops[2].snr
        }
        guard !snrs.isEmpty else { return nil }
        return snrs.reduce(0, +) / Double(snrs.count)
    }
}

// MARK: - View Model

@MainActor @Observable
final class BenchmarkViewModel {

    // MARK: - Setup State

    var testRepeater: ContactDTO?
    var targets: [ContactDTO] = []
    var batchSize = 5
    var includeNeighbors = false

    /// All available repeaters for selection
    var availableRepeaters: [ContactDTO] = []

    // MARK: - Execution State

    var isRunning = false
    var currentTargetIndex = 0
    var currentTraceIndex = 0
    var totalTargets: Int { targets.count }

    /// Live results populated as traces complete
    var targetResults: [BenchmarkTargetResult] = []

    /// Error message (auto-clearing)
    var errorMessage: String?
    private var errorAutoClearTask: Task<Void, Never>?

    // MARK: - Note & Save

    var note = ""
    var isSaved = false

    // MARK: - History

    var savedBenchmarkPaths: [SavedTracePathDTO] = []

    /// IDs selected for comparison (pick two, keyed by note)
    var selectedForComparison: Set<String> = []

    // MARK: - Neighbor Data (optional)

    var neighborResults: [NeighbourInfo] = []
    var isFetchingNeighbors = false

    // MARK: - Internal

    private var appState: AppState?
    private var cancellables = Set<AnyCancellable>()
    private var pendingTag: UInt32?
    private var pendingDeviceID: UUID?
    private var traceStartTime: Date?
    private var traceTask: Task<Void, Never>?
    private var traceContinuation: CheckedContinuation<Void, Never>?
    private var currentTraceResult: TraceResult?
    private var benchmarkCancelled = false

    /// Buffer between consecutive traces
    private static let interTraceBufferMs = 500

    // MARK: - Configuration

    func configure(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Data Loading

    func loadContacts(deviceID: UUID) async {
        guard let appState,
              let dataStore = appState.services?.dataStore else { return }
        do {
            let contacts = try await dataStore.fetchContacts(deviceID: deviceID)
            availableRepeaters = contacts.filter { $0.type == .repeater }
        } catch {
            logger.error("Failed to load contacts: \(error.localizedDescription)")
            availableRepeaters = []
        }
    }

    func loadHistory(deviceID: UUID) async {
        guard let dataStore = appState?.services?.dataStore else { return }
        do {
            let allPaths = try await dataStore.fetchSavedTracePaths(deviceID: deviceID)
            savedBenchmarkPaths = allPaths.filter { $0.name.hasPrefix("[Benchmark]") }
        } catch {
            logger.error("Failed to load benchmark history: \(error.localizedDescription)")
        }
    }

    // MARK: - Target Selection

    /// Repeaters available as targets (excludes the test repeater)
    var selectableTargets: [ContactDTO] {
        guard let testRepeater else { return availableRepeaters }
        return availableRepeaters.filter { $0.id != testRepeater.id }
    }

    func toggleTarget(_ contact: ContactDTO) {
        if let index = targets.firstIndex(where: { $0.id == contact.id }) {
            targets.remove(at: index)
        } else {
            targets.append(contact)
        }
    }

    func isTargetSelected(_ contact: ContactDTO) -> Bool {
        targets.contains(where: { $0.id == contact.id })
    }

    // MARK: - Benchmark Execution

    var canRun: Bool {
        testRepeater != nil && !targets.isEmpty && !isRunning
    }

    func startListening() {
        // Avoid duplicate subscriptions
        guard cancellables.isEmpty else { return }
        NotificationCenter.default.publisher(for: .traceDataReceived)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let traceInfo = notification.userInfo?["traceInfo"] as? TraceInfo else { return }
                let deviceID = notification.userInfo?["deviceID"] as? UUID
                self?.handleTraceResponse(traceInfo, deviceID: deviceID)
            }
            .store(in: &cancellables)
    }

    func stopListening() {
        // Don't remove the subscriber while a benchmark is running —
        // we need it to receive trace responses even when the view is off-screen
        guard !isRunning else { return }
        cancellables.removeAll()
    }

    func runBenchmark() async {
        guard let appState,
              let session = appState.services?.session,
              let testRepeater,
              !targets.isEmpty else { return }

        isRunning = true
        isSaved = false
        benchmarkCancelled = false
        targetResults = []
        neighborResults = []
        currentTargetIndex = 0

        let hashSize = appState.connectedDevice?.hashSize ?? 1

        // Run traces for each target sequentially
        for (targetIdx, target) in targets.enumerated() {
            if benchmarkCancelled { break }
            currentTargetIndex = targetIdx + 1
            currentTraceIndex = 0

            // Add target result immediately so it appears in the UI
            let liveResult = BenchmarkTargetResult(
                target: target,
                traceResults: [],
                savedPathID: nil
            )
            targetResults.append(liveResult)
            let resultIndex = targetResults.count - 1

            // Build path: testRepeater → target, with auto-return
            let testHash = Data(testRepeater.publicKey.prefix(hashSize))
            let targetHash = Data(target.publicKey.prefix(hashSize))
            let pathBytes = testHash + targetHash + testHash

            for traceIdx in 1...batchSize {
                if benchmarkCancelled { break }
                currentTraceIndex = traceIdx

                let result = await executeSingleTrace(
                    session: session,
                    appState: appState,
                    pathBytes: pathBytes,
                    hashSize: hashSize
                )
                // Update live — the view re-renders immediately
                targetResults[resultIndex].traceResults.append(result)

                // Buffer between traces
                if traceIdx < batchSize && !benchmarkCancelled {
                    try? await Task.sleep(for: .milliseconds(Self.interTraceBufferMs))
                }
            }

            targetResults[resultIndex].isComplete = true
        }

        // Optional: fetch neighbor table
        if includeNeighbors && !benchmarkCancelled {
            await fetchNeighborTable()
        }

        isRunning = false
        currentTargetIndex = 0
        currentTraceIndex = 0
    }

    func cancelBenchmark() {
        benchmarkCancelled = true
        traceTask?.cancel()
        traceTask = nil

        if let continuation = traceContinuation {
            traceContinuation = nil
            continuation.resume()
        }

        isRunning = false
        currentTargetIndex = 0
        currentTraceIndex = 0
        pendingTag = nil
        pendingDeviceID = nil
    }

    // MARK: - Single Trace Execution

    private func executeSingleTrace(
        session: MeshCoreSession,
        appState: AppState,
        pathBytes: Data,
        hashSize: Int
    ) async -> TraceResult {
        let tag = UInt32.random(in: 0...UInt32.max)
        pendingTag = tag
        pendingDeviceID = appState.connectedDevice?.id
        traceStartTime = Date()
        currentTraceResult = nil

        var timeoutSeconds = 15.0
        do {
            let sentInfo = try await session.sendTrace(
                tag: tag,
                authCode: 0,
                flags: UInt8(appState.connectedDevice?.pathHashMode ?? 0),
                path: pathBytes
            )
            timeoutSeconds = Double(sentInfo.suggestedTimeoutMs) / 1000.0 * 1.2
            logger.info("Benchmark trace \(self.currentTargetIndex)/\(self.totalTargets) #\(self.currentTraceIndex)/\(self.batchSize) tag=\(tag)")
        } catch {
            logger.error("Failed to send benchmark trace: \(error.localizedDescription)")
            pendingTag = nil
            return TraceResult.sendFailed("Send failed", attemptedPath: Array(pathBytes), hashSize: hashSize)
        }

        // Wait for response with timeout via continuation
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            traceContinuation = continuation

            traceTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: .seconds(timeoutSeconds))

                    if traceContinuation != nil && pendingTag == tag {
                        logger.warning("Benchmark trace timeout tag=\(tag)")
                        currentTraceResult = TraceResult.timeout(
                            attemptedPath: Array(pathBytes),
                            hashSize: hashSize
                        )
                        pendingTag = nil

                        if let cont = traceContinuation {
                            traceContinuation = nil
                            cont.resume()
                        }
                    }
                } catch {
                    // Cancelled — response received
                }
            }
        }

        return currentTraceResult ?? TraceResult.timeout(attemptedPath: Array(pathBytes), hashSize: hashSize)
    }

    // MARK: - Trace Response Handling

    private func handleTraceResponse(_ traceInfo: TraceInfo, deviceID: UUID?) {
        guard traceInfo.tag == pendingTag else { return }

        if let pending = pendingDeviceID, let received = deviceID, pending != received { return }

        traceTask?.cancel()
        traceTask = nil

        let durationMs: Int
        if let startTime = traceStartTime {
            durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
        } else {
            durationMs = 0
        }

        // Build hops from trace response
        var hops: [TraceHop] = []
        let deviceName = appState?.connectedDevice?.nodeName ?? "My Device"
        let path = traceInfo.path

        let deviceLat: Double?
        let deviceLon: Double?
        if let gpsLocation = appState?.locationService.currentLocation {
            deviceLat = gpsLocation.coordinate.latitude
            deviceLon = gpsLocation.coordinate.longitude
        } else if let device = appState?.connectedDevice,
                  device.latitude != 0 || device.longitude != 0 {
            deviceLat = device.latitude
            deviceLon = device.longitude
        } else {
            deviceLat = nil
            deviceLon = nil
        }

        // Start node
        hops.append(TraceHop(
            hashBytes: nil,
            resolvedName: deviceName,
            snr: 0,
            isStartNode: true,
            isEndNode: false,
            latitude: deviceLat,
            longitude: deviceLon
        ))

        // Intermediate hops
        for node in path where node.hashBytes != nil {
            let match = resolveNode(for: node.hashBytes ?? Data())
            hops.append(TraceHop(
                hashBytes: node.hashBytes,
                resolvedName: match?.resolvableName,
                snr: node.snr,
                isStartNode: false,
                isEndNode: false,
                latitude: match?.hasLocation == true ? match?.latitude : nil,
                longitude: match?.hasLocation == true ? match?.longitude : nil
            ))
        }

        // End node
        let endSnr = path.last?.snr ?? 0
        hops.append(TraceHop(
            hashBytes: nil,
            resolvedName: deviceName,
            snr: endSnr,
            isStartNode: false,
            isEndNode: true,
            latitude: deviceLat,
            longitude: deviceLon
        ))

        let hashSize = appState?.connectedDevice?.hashSize ?? 1
        currentTraceResult = TraceResult(
            hops: hops,
            durationMs: durationMs,
            success: true,
            errorMessage: nil,
            tracedPathBytes: [],
            hashSize: hashSize
        )

        pendingTag = nil
        pendingDeviceID = nil
        traceStartTime = nil

        // Resume continuation
        if let continuation = traceContinuation {
            traceContinuation = nil
            traceTask?.cancel()
            continuation.resume()
        }
    }

    // MARK: - Node Resolution

    private func resolveNode(for hashBytes: Data) -> ContactDTO? {
        availableRepeaters.first { contact in
            let hashSize = appState?.connectedDevice?.hashSize ?? 1
            return Data(contact.publicKey.prefix(hashSize)) == hashBytes
        }
    }

    // MARK: - Neighbor Fetch (Optional)

    /// Session ID for the test repeater's admin session (set externally if available)
    var adminSessionID: UUID?

    private func fetchNeighborTable() async {
        guard let adminService = appState?.services?.repeaterAdminService,
              let sessionID = adminSessionID else {
            logger.info("No admin session for neighbor fetch — skipping")
            return
        }

        isFetchingNeighbors = true
        defer { isFetchingNeighbors = false }

        do {
            let response = try await adminService.fetchAllNeighbors(
                sessionID: sessionID,
                orderBy: .strongestFirst
            )
            neighborResults = response.neighbours
            logger.info("Fetched \(response.neighbours.count) neighbors for benchmark")
        } catch {
            logger.error("Failed to fetch neighbors: \(error.localizedDescription)")
        }
    }

    // MARK: - Save Results

    func saveResults() async {
        guard let appState,
              let testRepeater,
              let deviceID = appState.connectedDevice?.id,
              let dataStore = appState.services?.dataStore else { return }

        let hashSize = appState.connectedDevice?.hashSize ?? 1
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)

        for targetResult in targetResults {
            let name = "[Benchmark] \(testRepeater.resolvableName) → \(targetResult.target.resolvableName)"
            let testHash = Data(testRepeater.publicKey.prefix(hashSize))
            let targetHash = Data(targetResult.target.publicKey.prefix(hashSize))
            let pathBytes = testHash + targetHash + testHash

            do {
                // Create initial run from first result
                guard let firstResult = targetResult.traceResults.first else { continue }
                let firstHopsSNR = firstResult.hops
                    .filter { !$0.isStartNode && !$0.isEndNode }
                    .map(\.snr)
                let initialRun = TracePathRunDTO(
                    id: UUID(),
                    date: Date(),
                    success: firstResult.success,
                    roundTripMs: firstResult.durationMs,
                    hopsSNR: firstHopsSNR,
                    note: trimmedNote.isEmpty ? nil : trimmedNote
                )

                let savedPath = try await dataStore.createSavedTracePath(
                    deviceID: deviceID,
                    name: name,
                    pathBytes: pathBytes,
                    hashSize: hashSize,
                    initialRun: initialRun
                )

                // Append remaining runs
                for (index, result) in targetResult.traceResults.enumerated() {
                    if index == 0 { continue }
                    let hopsSNR = result.hops
                        .filter { !$0.isStartNode && !$0.isEndNode }
                        .map(\.snr)
                    let runDTO = TracePathRunDTO(
                        id: UUID(),
                        date: Date().addingTimeInterval(Double(index)),
                        success: result.success,
                        roundTripMs: result.durationMs,
                        hopsSNR: hopsSNR,
                        note: trimmedNote.isEmpty ? nil : trimmedNote
                    )
                    try await dataStore.appendTracePathRun(pathID: savedPath.id, run: runDTO)
                }

                logger.info("Saved benchmark path: \(name)")
            } catch {
                logger.error("Failed to save benchmark path: \(error.localizedDescription)")
            }
        }

        isSaved = true

        // Refresh history
        if let deviceID = appState.connectedDevice?.id {
            await loadHistory(deviceID: deviceID)
        }
    }

    // MARK: - Repeat from History

    /// Loads a saved benchmark run group's test repeater and targets into the setup fields
    func loadFromRunGroup(_ group: BenchmarkRunGroup) {
        guard let appState else { return }
        let hashSize = appState.connectedDevice?.hashSize ?? 1

        // Extract test repeater and targets from saved path bytes
        // Path format: testHash + targetHash + testHash (each hashSize bytes)
        var resolvedTest: ContactDTO?
        var resolvedTargets: [ContactDTO] = []

        for path in group.paths {
            guard path.pathBytes.count >= hashSize * 2 else { continue }
            let testHash = path.pathBytes.prefix(hashSize)
            let targetHash = path.pathBytes.dropFirst(hashSize).prefix(hashSize)

            // Resolve test repeater (same for all paths in the group)
            if resolvedTest == nil {
                resolvedTest = availableRepeaters.first {
                    Data($0.publicKey.prefix(hashSize)) == Data(testHash)
                }
            }

            // Resolve target
            if let target = availableRepeaters.first(where: {
                Data($0.publicKey.prefix(hashSize)) == Data(targetHash)
            }) {
                if !resolvedTargets.contains(where: { $0.id == target.id }) {
                    resolvedTargets.append(target)
                }
            }
        }

        if let test = resolvedTest {
            testRepeater = test
        }
        targets = resolvedTargets
        // Clear previous results
        targetResults = []
        isSaved = false
        note = ""
    }

    // MARK: - Error Handling

    func setError(_ message: String) {
        errorAutoClearTask?.cancel()
        errorMessage = message
        errorAutoClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.errorMessage = nil
        }
    }

    func clearError() {
        errorAutoClearTask?.cancel()
        errorMessage = nil
    }
}
