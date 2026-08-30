#if DEBUG
  import MapperRawLog
import MC1Services
  import SwiftUI

  /// Debug-only control panel for the signal mapper's capture core
  /// (docs/SIGNAL_MAPPER_V2.md §2.5, §7 "M0").
  ///
  /// The design doc is explicit that the §2.5 constants are "beta-tunable defaults, not
  /// decisions" and that debug/TestFlight builds expose every one of them for live
  /// adjustment in the field. This is that panel. It is deliberately plain and
  /// unlocalized, matching the existing `#if DEBUG` settings section — no string ever
  /// shipped from here reaches a released build.
  ///
  /// Capture defaults **off**. Turning it on starts a purely passive engine: it folds the
  /// RX packets the app already receives into H3 cells and transmits nothing on the mesh.
  struct SignalMapperDebugView: View {
    @Environment(\.appState) private var appState
    @Environment(\.appTheme) private var theme

    private let store = MapperTuningStore()

    @State private var isCaptureEnabled = false
    @State private var tuning = MapperTuning.defaults
    @State private var status: SignalMapperCaptureEngine.Snapshot?
    @State private var storedCellCount = 0
    @State private var showingDeleteConfirmation = false

    var body: some View {
      List {
        captureSection
        statusSection
        anchorStatusSection
        fixSection
        anchorTuningSection
        flushSection
        probeSection
        rawRideLogSection
        uploadSection
        maintenanceSection
      }
      .themedCanvas(theme)
      .navigationTitle("Signal Mapper (debug)")
      .navigationBarTitleDisplayMode(.inline)
      .onAppear(perform: load)
      // A 1 Hz poll is plenty for a status readout and keeps the engine free of a
      // publish path that exists only for this screen.
      .task {
        while !Task.isCancelled {
          await refreshStatus()
          try? await Task.sleep(for: .seconds(1))
        }
      }
    }

    // MARK: - Capture

    private var captureSection: some View {
      Section {
        Toggle("Capture (debug)", isOn: $isCaptureEnabled)
          .onChange(of: isCaptureEnabled) { _, newValue in
            store.setCaptureEnabled(newValue)
            appState.applySignalMapperCaptureSetting()
          }
      } header: {
        Text("Capture")
      } footer: {
        Text("The same setting the Signal Mapper tool exposes. Passive only: folds received packets, heard repeats and delivery ACKs into H3 res-9 cells using cached one-shot fixes. Never transmits. Nothing is uploaded yet.")
      }
      .themedRowBackground(theme)
    }

    private var statusSection: some View {
      Section {
        LabeledContent("Engine", value: status?.isRunning == true ? "Running" : "Stopped")
        LabeledContent("Samples captured", value: "\(status?.sampleCount ?? 0)")
        LabeledContent("  RX packets", value: "\(status?.rxSampleCount ?? 0)")
        LabeledContent("  TX heard", value: "\(status?.txHeardSampleCount ?? 0)")
        LabeledContent("  ACKs", value: "\(status?.ackSampleCount ?? 0)")
        LabeledContent("Cells buffered", value: "\(status?.pendingCellCount ?? 0)")
        LabeledContent("Cells stored", value: "\(storedCellCount)")
        LabeledContent("Dropped (no fix)", value: "\(status?.droppedNoFixCount ?? 0)")
        LabeledContent("Dropped (stale fix)", value: "\(status?.droppedStaleFixCount ?? 0)")
        LabeledContent("Dropped (inaccurate)", value: "\(status?.droppedInaccurateFixCount ?? 0)")
        LabeledContent("Dropped (moved since fix)", value: "\(status?.droppedMovedSinceFixCount ?? 0)")
        LabeledContent("Dropped (anchor)", value: "\(status?.droppedAnchorCount ?? 0)")
        LabeledContent("Duplicates", value: "\(status?.duplicateCount ?? 0)")
        LabeledContent("Last flush", value: lastFlushText)
      } header: {
        Text("Status")
      }
      .themedRowBackground(theme)
    }

    /// What the anchor exclusion is doing right now. Deliberately counts only: the disc
    /// centres and radii are never displayed, because an offset that protects a home only
    /// protects it while nobody can read it off a screen.
    private var anchorStatusSection: some View {
      Section {
        LabeledContent("Anchor cells", value: "\(status?.anchorCount ?? 0)")
        LabeledContent("Cells excluded", value: "\(status?.excludedCellCount ?? 0)")
        LabeledContent("Cells purged", value: "\(status?.purgedCellCount ?? 0)")
        LabeledContent("Last recompute", value: lastAnchorRecomputeText)

        Button("Recompute anchors now") {
          Task {
            await appState.signalMapperEngine?.recomputeAnchors()
            await refreshStatus()
          }
        }
        .disabled(status?.isRunning != true)
      } header: {
        Text("Anchor exclusion")
      } footer: {
        Text("Cells you dwell in are detected locally and excluded from capture; anything already stored inside an exclusion is deleted when the anchor is found. Disc geometry is never shown, exported or uploaded.")
      }
      .themedRowBackground(theme)
    }

    private var lastFlushText: String {
      guard let lastFlush = status?.lastFlushAt else { return "—" }
      return lastFlush.formatted(date: .omitted, time: .standard)
    }

    private var lastAnchorRecomputeText: String {
      guard let at = status?.lastAnchorRecomputeAt else { return "—" }
      return at.formatted(date: .omitted, time: .standard)
    }

    // MARK: - Tuning

    private var fixSection: some View {
      Section {
        stepper("Max fix age", value: $tuning.fixMaxAgeSeconds, step: 15, range: 15...600, unit: "s")
        stepper("Max inaccuracy", value: $tuning.fixMaxAccuracyMeters, step: 10, range: 10...500, unit: "m")
        stepper("Max displacement", value: $tuning.fixMaxDisplacementMeters, step: 25, range: 25...1000, unit: "m")
      } header: {
        Text("Fix policy")
      } footer: {
        Text("A packet whose fix fails any test is dropped, never queued. Max displacement caps speed × age: a stationary phone keeps the full max age, a moving one gets proportionally less.")
      }
      .themedRowBackground(theme)
    }

    private var anchorTuningSection: some View {
      Section {
        stepper("Min distinct days", value: $tuning.anchorMinDistinctDays, step: 1, range: 1...60, unit: " d")
        percentStepper("Stationary share", value: $tuning.anchorStationaryShare)
        stepper("Observation count", value: $tuning.anchorObservationCount, step: 250, range: 50...20000, unit: "")
        stepper("Offset min", value: $tuning.anchorOffsetMinMeters, step: 50, range: 0...2000, unit: "m")
        stepper("Offset max", value: $tuning.anchorOffsetMaxMeters, step: 50, range: 0...2000, unit: "m")
        stepper("Radius min", value: $tuning.anchorRadiusMinMeters, step: 100, range: 100...5000, unit: "m")
        stepper("Radius max", value: $tuning.anchorRadiusMaxMeters, step: 100, range: 100...5000, unit: "m")
        stepper("Recompute every", value: $tuning.anchorRecomputeFlushCount, step: 5, range: 1...200, unit: " flushes")
      } header: {
        Text("Anchor detection")
      } footer: {
        Text("A cell is an anchor when it is seen on enough distinct days with a high enough stationary share, or when it passes the observation count alone. ")
          + Text("Offset and radius are drawn once per install from a stored seed and never change — a disc that moved between runs would leak more than it hides.")
      }
      .themedRowBackground(theme)
    }

    private var flushSection: some View {
      Section {
        stepper("Flush interval", value: $tuning.flushIntervalSeconds, step: 10, range: 5...600, unit: "s")
        stepper("Flush after", value: $tuning.flushEntryCount, step: 10, range: 5...500, unit: " entries")
      } header: {
        Text("Flush policy")
      } footer: {
        Text("Whichever comes first.")
      }
      .themedRowBackground(theme)
    }

    private var probeSection: some View {
      Section {
        stepper("Probe interval", value: $tuning.probeIntervalSeconds, step: 1, range: 1...120, unit: "s")
        stepper("Probe burst", value: $tuning.probeBurst, step: 1, range: 1...10, unit: "")
        stepper("Samples per cell", value: $tuning.samplesPerCellPerSession, step: 1, range: 1...50, unit: "")
        stepper("Community-fresh window", value: $tuning.communityFreshnessDays, step: 1, range: 1...90, unit: " d")
        stepper("Focus probe interval", value: $tuning.focusProbeIntervalSeconds, step: 2, range: 4...120, unit: "s")
      } header: {
        Text("Probe discipline (M3)")
      } footer: {
        Text("Survey sessions never send flood-routed packets — that is a design rule, not a knob here. ")
          + Text("Focus probe interval is the healthy-link cadence for a locked-on target; the engine's loss-streak ladder shortens it at the coverage edge and stretches it once a link is gone, and focus traces spend their own budget, never the novelty one.")
      }
      .themedRowBackground(theme)
    }

    private var rawRideLogSection: some View {
      Section {
        stepper("Sample cap per ride", value: $tuning.rawSampleCapPerSession, step: 10_000, range: 10_000...200_000, unit: "")
        stepper("Retention", value: $tuning.rawRetentionDays, step: 5, range: 0...365, unit: " d")
        Toggle("Keep screen awake", isOn: $tuning.rideKeepsScreenAwake)
          .onChange(of: tuning.rideKeepsScreenAwake) { _, _ in persist() }
        // The FULL-fidelity export lives here and only here (ACTIVE_SURVEY_M3_5.md §2.8):
        // exact coordinates, full repeater keys, radio config, gate outcomes. The share
        // sheet in the completion summary gets the scrubbed tier; this file's name says
        // what it is.
        if let exportURL = rawExportURL {
          ShareLink(item: exportURL) {
            Label("Share RAW-PRIVATE ride file", systemImage: "square.and.arrow.up.trianglebadge.exclamationmark")
          }
        } else {
          Button {
            confirmingRawExport = true
          } label: {
            Label("Export latest run (full raw)", systemImage: "doc.badge.arrow.up")
          }
          .disabled(isExportingRaw)
          .confirmationDialog(
            "Export the full raw log?",
            isPresented: $confirmingRawExport,
            titleVisibility: .visible
          ) {
            Button("Export exact positions, keys and radio config", role: .destructive) {
              exportLatestRunRaw()
            }
          } message: {
            Text("The file contains your exact GPS track (including home), full repeater public keys, your radio configuration, and timestamps. Share it with nobody you would not hand your location history to.")
          }
        }
      } header: {
        Text("Raw ride log")
      } footer: {
        Text("Every probe, reply, loss and breadcrumb of a survey run, kept at full detail in its own backup-excluded store. Retention 0 means keep forever — an explicit choice, not the default: a precise movement log's value decays in weeks while its exposure does not. ")
          + Text("Screen awake applies while a run is active and the app is foreground; a bar-mounted phone that sleeps mid-ride ends the ride.")
      }
      .themedRowBackground(theme)
    }

    private var uploadSection: some View {
      Section {
        stepper("Batch min cells", value: $tuning.uploadBatchMinCells, step: 5, range: 1...500, unit: "")
        stepper("Batch max age", value: $tuning.uploadBatchMaxAgeSeconds, step: 3600, range: 3600...604_800, unit: " s")
        stepper("Upload jitter", value: $tuning.uploadJitterSeconds, step: 1800, range: 0...86400, unit: " s")
      } header: {
        Text("Upload batching (M2)")
      } footer: {
        Text("Defined now, consumed by the wire v3 uploader.")
      }
      .themedRowBackground(theme)
    }

    @State private var rawExportURL: URL?
    @State private var isExportingRaw = false
    @State private var confirmingRawExport = false

    private func exportLatestRunRaw() {
      isExportingRaw = true
      Task {
        defer { isExportingRaw = false }
        guard let store = try? await resolveRawLogStore(),
              let run = try? await store.fetchRuns().first else { return }
        rawExportURL = try? await MapperRideExport.fullExport(run: run, store: store)
      }
    }

    /// The app-lifetime store when a run already opened it, else a direct open.
    private func resolveRawLogStore() async throws -> MapperRawLogStore {
      if let store = appState.mapperRawLogStore { return store }
      let store = try MapperRawLogStore.live()
      appState.mapperRawLogStore = store
      return store
    }

    private var maintenanceSection: some View {
      Section {
        Button("Reset tuning to defaults") {
          store.resetToDefaults()
          tuning = store.tuning
        }

        Button("Flush now") {
          Task {
            await appState.signalMapperEngine?.flushNow()
            await refreshStatus()
          }
        }
        .disabled(status?.isRunning != true)

        Button("Delete all captured cells", role: .destructive) {
          showingDeleteConfirmation = true
        }
      } header: {
        Text("Maintenance")
      }
      .themedRowBackground(theme)
      .alert("Delete captured cells?", isPresented: $showingDeleteConfirmation) {
        Button("Cancel", role: .cancel) {}
        Button("Delete", role: .destructive) { deleteAll() }
      } message: {
        Text("Removes every stored cell-day observation. Build 40 survey data is a separate table and is not touched.")
      }
    }

    // MARK: - Controls

    private func stepper(
      _ title: String,
      value: Binding<Double>,
      step: Double,
      range: ClosedRange<Double>,
      unit: String
    ) -> some View {
      Stepper(value: value, in: range, step: step, onEditingChanged: { editing in
        if !editing { persist() }
      }) {
        LabeledContent(title, value: "\(Int(value.wrappedValue))\(unit)")
      }
    }

    private func stepper(
      _ title: String,
      value: Binding<Int>,
      step: Int,
      range: ClosedRange<Int>,
      unit: String
    ) -> some View {
      Stepper(value: value, in: range, step: step, onEditingChanged: { editing in
        if !editing { persist() }
      }) {
        LabeledContent(title, value: "\(value.wrappedValue)\(unit)")
      }
    }

    /// A 0…1 share, stepped and shown as whole percent — nobody dials in 0.65 on a stepper.
    private func percentStepper(_ title: String, value: Binding<Double>) -> some View {
      Stepper(value: value, in: 0...1, step: 0.05, onEditingChanged: { editing in
        if !editing { persist() }
      }) {
        LabeledContent(title, value: "\(Int((value.wrappedValue * 100).rounded()))%")
      }
    }

    // MARK: - State

    private func load() {
      isCaptureEnabled = store.isCaptureEnabled
      tuning = store.tuning
    }

    /// Written on step-end rather than on every tick, so holding a stepper does not write
    /// a defaults key per repeat.
    private func persist() {
      store.save(tuning)
    }

    private func refreshStatus() async {
      status = await appState.signalMapperEngine?.snapshot()
      if let dataStore = appState.services?.dataStore,
         let count = try? await dataStore.countMapperCellObservations() {
        storedCellCount = count
      }
    }

    private func deleteAll() {
      guard let dataStore = appState.services?.dataStore else { return }
      Task {
        try? await dataStore.deleteAllMapperCellObservations()
        await refreshStatus()
      }
    }
  }
#endif
