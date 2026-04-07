import SwiftUI
import MC1Services

struct BenchmarkView: View {
    @Environment(\.appState) private var appState
    @State private var viewModel: BenchmarkViewModel
    @State private var showHistory = false

    init(viewModel: BenchmarkViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    private var isConnected: Bool {
        appState.services?.session != nil
    }

    var body: some View {
        Group {
            if !isConnected {
                ContentUnavailableView(
                    "Radio Required",
                    systemImage: "antenna.radiowaves.left.and.right.slash",
                    description: Text("Connect a radio to run benchmarks.")
                )
            } else {
                benchmarkContent
            }
        }
        .navigationTitle("Repeater Benchmark")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showHistory = true
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
            }
        }
        .sheet(isPresented: $showHistory) {
            NavigationStack {
                BenchmarkHistoryView(viewModel: viewModel)
            }
        }
        .task(id: appState.servicesVersion) {
            viewModel.configure(appState: appState)
            if let deviceID = appState.connectedDevice?.id {
                await viewModel.loadContacts(deviceID: deviceID)
                await viewModel.loadHistory(deviceID: deviceID)
            }
            viewModel.startListening()
        }
        .onDisappear {
            // Keep the benchmark running — just stop the listener
            // It will be reconnected on next onAppear via .task
            viewModel.stopListening()
        }
    }

    // MARK: - Main Content

    private var benchmarkContent: some View {
        List {
            // Setup
            Section {
                testRepeaterRow
                targetRow
                batchSizePicker
            } header: {
                Text("Setup")
            }

            // Run Button
            Section {
                runButton
            }

            // Progress
            if viewModel.isRunning {
                Section("Progress") {
                    progressContent
                }
            }

            // Results
            if !viewModel.targetResults.isEmpty {
                Section("Results") {
                    resultsContent
                }

                // Save
                Section {
                    TextField("Note (e.g., \"stock whip antenna\")", text: $viewModel.note)

                    saveButton
                } header: {
                    Text("Save")
                } footer: {
                    Text("Results are saved as trace paths tagged with your note for comparison.")
                }
            }
        }
    }

    // MARK: - Setup Rows

    private var testRepeaterRow: some View {
        NavigationLink {
            RepeaterPickerView(
                repeaters: viewModel.availableRepeaters,
                selected: viewModel.testRepeater,
                onSelect: { viewModel.testRepeater = $0 }
            )
            .navigationTitle("Test Repeater")
        } label: {
            HStack {
                Text("Test Repeater")
                Spacer()
                Text(viewModel.testRepeater?.resolvableName ?? "Select...")
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(viewModel.isRunning)
    }

    private var targetRow: some View {
        NavigationLink {
            TargetPickerView(viewModel: viewModel)
        } label: {
            HStack {
                Text("Targets")
                Spacer()
                if viewModel.targets.isEmpty {
                    Text("Select...")
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(viewModel.targets.count) selected")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(viewModel.isRunning)
    }

    private var batchSizePicker: some View {
        Picker("Traces per target", selection: $viewModel.batchSize) {
            Text("1").tag(1)
            Text("3").tag(3)
            Text("5").tag(5)
            Text("10").tag(10)
        }
        .pickerStyle(.segmented)
        .disabled(viewModel.isRunning)
    }

    // MARK: - Run Button

    private var runButton: some View {
        Button {
            if viewModel.isRunning {
                viewModel.cancelBenchmark()
            } else {
                Task { await viewModel.runBenchmark() }
            }
        } label: {
            HStack {
                Spacer()
                Label(
                    viewModel.isRunning ? "Cancel" : "Run Benchmark",
                    systemImage: viewModel.isRunning ? "stop.fill" : "play.fill"
                )
                .font(.headline)
                Spacer()
            }
        }
        .disabled(!viewModel.canRun && !viewModel.isRunning)
        .tint(viewModel.isRunning ? .red : .accentColor)
    }

    // MARK: - Progress

    @ViewBuilder
    private var progressContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Target \(viewModel.currentTargetIndex) of \(viewModel.totalTargets)")
                    .font(.subheadline)
                Spacer()
                Text("Trace \(viewModel.currentTraceIndex) of \(viewModel.batchSize)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ProgressView(
                value: Double(max(0, viewModel.currentTargetIndex - 1) * viewModel.batchSize + viewModel.currentTraceIndex),
                total: Double(viewModel.totalTargets * viewModel.batchSize)
            )
        }

    }

    // MARK: - Results

    @ViewBuilder
    private var resultsContent: some View {
        ForEach(viewModel.targetResults) { targetResult in
            BenchmarkTargetRow(
                testRepeater: viewModel.testRepeater,
                targetResult: targetResult
            )
        }

    }

    // MARK: - Save

    private var saveButton: some View {
        Button {
            Task { await viewModel.saveResults() }
        } label: {
            HStack {
                Spacer()
                Label(
                    viewModel.isSaved ? "Saved" : "Save Results",
                    systemImage: viewModel.isSaved ? "checkmark.circle.fill" : "square.and.arrow.down"
                )
                .font(.headline)
                Spacer()
            }
        }
        .disabled(viewModel.isSaved || viewModel.isRunning)
        .tint(viewModel.isSaved ? .green : .accentColor)
    }
}

// MARK: - Target Result Row

private struct BenchmarkTargetRow: View {
    let testRepeater: ContactDTO?
    let targetResult: BenchmarkTargetResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: target name + success count
            HStack {
                Text("\(testRepeater?.resolvableName ?? "?") → \(targetResult.target.resolvableName)")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if targetResult.totalCount > 0 {
                    Text("\(targetResult.successCount)/\(targetResult.totalCount)")
                        .font(.caption.monospaced())
                        .foregroundStyle(successColor)
                }
                if !targetResult.isComplete {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            // Summary stats (only when we have results)
            if targetResult.totalCount > 0 {
                HStack(spacing: 16) {
                    if let avg = targetResult.averageRTT {
                        StatLabel(title: "avg", value: "\(avg)ms")
                    }
                    if let min = targetResult.minRTT {
                        StatLabel(title: "min", value: "\(min)ms")
                    }
                    if let max = targetResult.maxRTT {
                        StatLabel(title: "max", value: "\(max)ms")
                    }
                }
                .font(.caption)

                // TX/RX signal quality
                HStack(spacing: 16) {
                    if let tx = targetResult.txSNR {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.circle.fill")
                                .foregroundStyle(TraceHop.signalColor(for: tx))
                            StatLabel(
                                title: "TX",
                                value: String(format: "%.1f dB", tx),
                                color: TraceHop.signalColor(for: tx)
                            )
                        }
                    }
                    if let rx = targetResult.rxSNR {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundStyle(TraceHop.signalColor(for: rx))
                            StatLabel(
                                title: "RX",
                                value: String(format: "%.1f dB", rx),
                                color: TraceHop.signalColor(for: rx)
                            )
                        }
                    }
                }
                .font(.caption)
            }

            // Per-trace detail log
            if !targetResult.traceResults.isEmpty {
                DisclosureGroup("Traces (\(targetResult.traceResults.count))") {
                    ForEach(Array(targetResult.traceResults.enumerated()), id: \.offset) { idx, trace in
                        traceDetailRow(index: idx + 1, trace: trace)
                    }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    private func traceDetailRow(index: Int, trace: TraceResult) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // Trace header: #N, status, RTT
            HStack(spacing: 6) {
                Text("#\(index)")
                    .font(.caption.monospaced().weight(.medium))
                    .foregroundStyle(.secondary)
                if trace.success {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                    Text("\(trace.durationMs)ms")
                        .font(.caption.monospaced())
                } else {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                    Text(trace.errorMessage ?? "timeout")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
            }

            // Hop-by-hop detail for successful traces
            if trace.success {
                HStack(spacing: 0) {
                    ForEach(Array(trace.hops.enumerated()), id: \.offset) { hopIdx, hop in
                        if hopIdx > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 7))
                                .foregroundStyle(.quaternary)
                                .padding(.horizontal, 2)
                        }
                        hopPill(hop)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func hopPill(_ hop: TraceHop) -> some View {
        VStack(spacing: 1) {
            Text(hop.resolvedName ?? hop.hashBytes?.prefix(2).map { String(format: "%02X", $0) }.joined() ?? "?")
                .font(.system(size: 9, design: .monospaced))
                .lineLimit(1)
            if !hop.isStartNode && !hop.isEndNode {
                Text(String(format: "%.1f", hop.snr))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(TraceHop.signalColor(for: hop.snr))
            }
        }
    }

    private var successColor: Color {
        if targetResult.successRate >= 80 { return .green }
        if targetResult.successRate >= 50 { return .yellow }
        return .red
    }
}

private struct StatLabel: View {
    let title: String
    let value: String
    var color: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .foregroundStyle(.tertiary)
            Text(value)
                .foregroundStyle(color)
        }
    }
}

// MARK: - Repeater Picker (Single Select)

private struct RepeaterPickerView: View {
    let repeaters: [ContactDTO]
    let selected: ContactDTO?
    let onSelect: (ContactDTO) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filtered: [ContactDTO] {
        let sorted = repeaters.sorted { a, b in
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            return a.lastModified > b.lastModified
        }
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return sorted }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let hexQuery = query.uppercased()
        let looksLikeHex = hexQuery.allSatisfy { $0.isHexDigit }
        return sorted.filter { contact in
            if contact.displayName.localizedStandardContains(query) { return true }
            if looksLikeHex { return contact.publicKeyHex.contains(hexQuery) }
            return false
        }
    }

    var body: some View {
        List {
            ForEach(filtered) { repeater in
                repeaterRow(repeater)
            }
        }
        .searchable(text: $searchText, prompt: "Name or hex prefix")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func repeaterRow(_ repeater: ContactDTO) -> some View {
        Button {
            onSelect(repeater)
            dismiss()
        } label: {
            repeaterLabel(repeater)
        }
        .tint(.primary)
    }

    private func repeaterLabel(_ repeater: ContactDTO) -> some View {
        let hexCode = repeater.publicKey.prefix(3).map { String(format: "%02X", $0) }.joined()
        return HStack {
            if repeater.isFavorite {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            }
            VStack(alignment: .leading) {
                Text(repeater.resolvableName)
                HStack(spacing: 6) {
                    Text(hexCode)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if repeater.lastModified > 0 {
                        RelativeTimestampText(timestamp: repeater.lastModified)
                    }
                }
            }
            Spacer()
            if selected?.id == repeater.id {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
            }
        }
    }
}

// MARK: - Target Picker (Multi-Select)

private struct TargetPickerView: View {
    var viewModel: BenchmarkViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filtered: [ContactDTO] {
        let sorted = viewModel.selectableTargets.sorted { a, b in
            // Neighbors first, then favorites, then by recency
            let aNeighbor = viewModel.isNeighbor(a)
            let bNeighbor = viewModel.isNeighbor(b)
            if aNeighbor != bNeighbor { return aNeighbor }
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            return a.lastModified > b.lastModified
        }
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return sorted }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let hexQuery = query.uppercased()
        let looksLikeHex = hexQuery.allSatisfy { $0.isHexDigit }
        return sorted.filter { contact in
            if contact.displayName.localizedStandardContains(query) { return true }
            if looksLikeHex { return contact.publicKeyHex.contains(hexQuery) }
            return false
        }
    }

    private var hasNeighbors: Bool {
        viewModel.selectableTargets.contains { viewModel.isNeighbor($0) }
    }

    var body: some View {
        List {
            ForEach(filtered) { repeater in
                targetRow(repeater)
            }
        }
        .searchable(text: $searchText, prompt: "Name or hex prefix")
        .navigationTitle("Target Repeaters")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if hasNeighbors {
                    Button {
                        viewModel.selectAllNeighbors()
                    } label: {
                        Label("Select Neighbors", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.subheadline)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func targetRow(_ repeater: ContactDTO) -> some View {
        Button {
            viewModel.toggleTarget(repeater)
        } label: {
            RepeaterPickerRow(
                contact: repeater,
                isSelected: viewModel.isTargetSelected(repeater),
                badge: viewModel.isNeighbor(repeater) ? "RX" : nil,
                badgeColor: .green
            )
        }
        .tint(.primary)
    }
}

#Preview {
    NavigationStack {
        BenchmarkView(viewModel: BenchmarkViewModel())
    }
    .environment(\.appState, AppState())
}
