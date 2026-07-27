import MC1Services
import SwiftUI

/// Measures how well one repeater reaches its neighbours.
///
/// Pick a repeater to test through, pick the neighbours to reach, run a batch of trace
/// probes at each of them. Because the path goes out through the test repeater and back, one
/// probe measures both directions of the link — which is the whole reason the tool exists:
/// antenna work usually changes one leg far more than the other, and an average round trip
/// hides that entirely.
///
/// The run itself lives on `ServiceContainer`, so leaving this screen mid-batch does not
/// abandon it; coming back re-attaches to the run in progress.
struct RepeaterBenchmarkView: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme

  @State private var model = RepeaterBenchmarkModel()
  @State private var showHistory = false

  private var isConnected: Bool {
    appState.services?.session != nil
  }

  var body: some View {
    Group {
      if isConnected {
        content
      } else {
        ContentUnavailableView {
          Label(
            L10n.Tools.Tools.Benchmark.notConnected,
            systemImage: "antenna.radiowaves.left.and.right.slash"
          )
        } description: {
          Text(L10n.Tools.Tools.Benchmark.notConnectedDescription)
        }
      }
    }
    .navigationTitle(L10n.Tools.Tools.benchmark)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          showHistory = true
        } label: {
          Label(L10n.Tools.Tools.Benchmark.history, systemImage: "clock.arrow.circlepath")
        }
        .disabled(!isConnected)
      }
    }
    .sheet(isPresented: $showHistory) {
      NavigationStack {
        BenchmarkHistoryView(model: model)
      }
    }
    .errorAlert($model.errorMessage, title: L10n.Tools.Tools.Benchmark.errorTitle)
    .task(id: appState.servicesVersion) {
      guard let services = appState.services else {
        model.detach()
        return
      }
      await model.attach(
        engine: services.repeaterBenchmarkEngine,
        history: services.benchmarkHistoryStore,
        device: appState.connectedDevice
      )
      await reloadCandidates()
    }
  }

  private func reloadCandidates() async {
    await model.reloadCandidates(
      dataStore: appState.offlineDataStore,
      radioID: appState.connectedDevice?.radioID,
      signals: appState.repeaterSignals,
      pathHashMode: appState.connectedDevice?.pathHashMode ?? 0
    )
  }

  // MARK: - Content

  private var content: some View {
    List {
      setupSection
      runSection
      if model.isRunning {
        progressSection
      }
      if !model.results.isEmpty {
        resultsSection
        saveSection
      }
    }
    .themedCanvas(theme)
    .refreshable { await reloadCandidates() }
  }

  // MARK: - Setup

  private var setupSection: some View {
    Section {
      NavigationLink {
        RepeaterPickerView(
          mode: .single,
          candidates: model.candidates,
          selection: model.testRepeaterKeys,
          onToggle: { candidate in Task { await model.setTestRepeater(candidate) } }
        )
        .navigationTitle(L10n.Tools.Tools.Benchmark.testRepeater)
      } label: {
        LabeledContent(L10n.Tools.Tools.Benchmark.testRepeater) {
          Text(model.testRepeater?.displayName ?? L10n.Tools.Tools.Benchmark.selectPrompt)
            .foregroundStyle(.secondary)
        }
      }
      .disabled(model.isRunning)

      NavigationLink {
        RepeaterPickerView(
          mode: .multiple,
          candidates: model.selectableTargets,
          selection: model.selectedTargetKeys,
          onToggle: { candidate in Task { await model.toggleTarget(candidate) } }
        )
        .navigationTitle(L10n.Tools.Tools.Benchmark.targets)
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button {
              Task { await model.selectHeardTargets() }
            } label: {
              Label(
                L10n.Tools.Tools.Benchmark.selectHeard,
                systemImage: "antenna.radiowaves.left.and.right"
              )
            }
            .disabled(!model.selectableTargets.contains(where: \.isHeard))
          }
        }
      } label: {
        LabeledContent(L10n.Tools.Tools.Benchmark.targets) {
          Text(model.plan.targets.isEmpty
            ? L10n.Tools.Tools.Benchmark.selectPrompt
            : L10n.Tools.Tools.Benchmark.targetsSelected(model.plan.targets.count))
            .foregroundStyle(.secondary)
        }
      }
      .disabled(model.isRunning)

      Picker(L10n.Tools.Tools.Benchmark.tracesPerTarget, selection: Binding(
        get: { model.plan.tracesPerTarget },
        set: { count in Task { await model.setTracesPerTarget(count) } }
      )) {
        ForEach(RepeaterBenchmarkPolicy.traceCountOptions, id: \.self) { count in
          Text(count, format: .number).tag(count)
        }
      }
      .pickerStyle(.segmented)
      .disabled(model.isRunning)
    } header: {
      Text(L10n.Tools.Tools.Benchmark.setup)
    } footer: {
      Text(L10n.Tools.Tools.Benchmark.setupFooter)
    }
    .themedRowBackground(theme)
  }

  // MARK: - Run

  private var runSection: some View {
    Section {
      Button {
        if model.isRunning {
          Task { await model.cancel() }
        } else {
          Task { await model.run() }
        }
      } label: {
        HStack {
          Spacer()
          Label(
            model.isRunning ? L10n.Tools.Tools.Benchmark.cancel : L10n.Tools.Tools.Benchmark.run,
            systemImage: model.isRunning ? "stop.fill" : "play.fill"
          )
          .font(.headline)
          Spacer()
        }
      }
      .disabled(!model.canRun && !model.isRunning)
      .tint(model.isRunning ? .red : theme.accentColor)
    }
    .themedRowBackground(theme)
  }

  private var progressSection: some View {
    Section(L10n.Tools.Tools.Benchmark.progress) {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(L10n.Tools.Tools.Benchmark.targetProgress(
            model.snapshot.currentTargetIndex,
            model.snapshot.totalTargets
          ))
          .font(.subheadline)
          Spacer()
          Text(L10n.Tools.Tools.Benchmark.traceProgress(
            model.snapshot.currentTraceIndex,
            model.plan.tracesPerTarget
          ))
          .font(.subheadline)
          .foregroundStyle(.secondary)
        }
        ProgressView(value: model.snapshot.progressFraction)
          .tint(theme.accentColor)
      }
      .monospacedDigit()
      .padding(.vertical, 2)
    }
    .themedRowBackground(theme)
  }

  // MARK: - Results

  private var resultsSection: some View {
    Section(L10n.Tools.Tools.Benchmark.results) {
      ForEach(model.results) { result in
        BenchmarkTargetRow(
          testRepeaterName: model.plan.testRepeater?.name,
          result: result
        )
      }
    }
    .themedRowBackground(theme)
  }

  private var saveSection: some View {
    Section {
      TextField(L10n.Tools.Tools.Benchmark.notePlaceholder, text: $model.note)
        .disabled(model.isRunning)

      Button {
        Task { await model.saveResults() }
      } label: {
        HStack {
          Spacer()
          Label(
            model.isSaved ? L10n.Tools.Tools.Benchmark.saved : L10n.Tools.Tools.Benchmark.save,
            systemImage: model.isSaved ? "checkmark.circle.fill" : "square.and.arrow.down"
          )
          .font(.headline)
          Spacer()
        }
      }
      .disabled(!model.canSave)
      .tint(model.isSaved ? .green : theme.accentColor)
    } header: {
      Text(L10n.Tools.Tools.Benchmark.saveHeader)
    } footer: {
      Text(L10n.Tools.Tools.Benchmark.saveFooter)
    }
    .themedRowBackground(theme)
  }
}

#Preview {
  NavigationStack {
    RepeaterBenchmarkView()
  }
  .environment(\.appState, AppState())
}
