import MapperRawLog
import MC1Services
import SwiftUI

// MARK: - Options

/// The export's date window (docs/SIGNAL_MAPPER_V3.md §5, mockup screen 5).
///
/// Windows rather than a date picker: the question a rider asks of this table is "today's
/// ride", "this week", "everything", and two calendar wheels to express that would be four
/// taps for the common case and a wrong answer whenever the end date is off by a day.
enum MapperExportDateRange: String, CaseIterable, Identifiable, Sendable {
  case last24Hours
  case last7Days
  case last30Days
  case last90Days
  case everything

  var id: String {
    rawValue
  }

  /// Hours back from the anchor, or nil for "everything inside retention".
  private var hours: Double? {
    switch self {
    case .last24Hours: 24
    case .last7Days: 24 * 7
    case .last30Days: 24 * 30
    case .last90Days: 24 * 90
    case .everything: nil
    }
  }

  /// The window's lower bound, measured from an anchor the screen holds still.
  ///
  /// An anchor rather than `Date()`: the filter is a value the count task is keyed on, and a
  /// `since` recomputed on every body evaluation would restart that task forever. It also
  /// makes the exported file cover exactly the window whose row count the button promised.
  func since(from anchor: Date) -> Date? {
    hours.map { anchor.addingTimeInterval(-$0 * 3600) }
  }

  var name: String {
    switch self {
    case .last24Hours: L10n.Settings.SignalMapperData.Range.last24Hours
    case .last7Days: L10n.Settings.SignalMapperData.Range.last7Days
    case .last30Days: L10n.Settings.SignalMapperData.Range.last30Days
    case .last90Days: L10n.Settings.SignalMapperData.Range.last90Days
    case .everything: L10n.Settings.SignalMapperData.Range.everything
    }
  }
}

/// Which hexagons the export covers.
///
/// Deliberately **not** a hexagon picker: an H3 index typed or pasted by hand is a string
/// nobody can verify, and the two scopes a rider actually wants are "all of it" and "the ride
/// I just finished".
enum MapperExportHexagonScope: String, CaseIterable, Identifiable, Sendable {
  case all
  case thisRide

  var id: String {
    rawValue
  }

  var name: String {
    switch self {
    case .all: L10n.Settings.SignalMapperData.Hexagons.all
    case .thisRide: L10n.Settings.SignalMapperData.Hexagons.thisRide
    }
  }
}

/// The kind filter's rows: ``MapperRawSampleKind`` grouped into the ten things a person would
/// say out loud.
///
/// The enum's thirteen cases include three pairs that are one idea with two spellings — a
/// trace reply and a discover reply are both "a repeater answered", a lost probe and an
/// abandoned one are both "no reply came", a link up and a link down are both "the radio
/// connection changed". The *file* keeps the thirteen names apart (``MapperRideExport``'s
/// `kindName` is an exhaustive switch); only the filter groups them, because a picker with
/// `probeAbandoned` in it asks the user to know what the recorder was doing.
enum MapperExportKindGroup: String, CaseIterable, Identifiable, Sendable {
  case heard
  case echo
  case probeSent
  case probeReply
  case probeLost
  case ack
  case sent
  case observer
  case breadcrumb
  case radioLink

  var id: String {
    rawValue
  }

  var kinds: Set<MapperRawSampleKind> {
    switch self {
    case .heard: [.passiveRx]
    case .echo: [.txHeard]
    case .probeSent: [.probeAttempt]
    case .probeReply: [.probeTraceReply, .probeDiscoverResponse]
    case .probeLost: [.probeLost, .probeAbandoned]
    case .ack: [.ackResolved]
    case .sent: [.sent]
    case .observer: [.observerSighting]
    case .breadcrumb: [.breadcrumb]
    case .radioLink: [.radioLinkDown, .radioLinkUp]
    }
  }

  /// The card's own kind vocabulary, reused rather than restated: a row the detail list calls
  /// "echo of your message" must not be called something else one screen away.
  var name: String {
    switch self {
    case .heard: L10n.Tools.Tools.SignalMapper.Detail.Kind.heard
    case .echo: L10n.Tools.Tools.SignalMapper.Detail.Kind.echo
    case .probeSent: L10n.Tools.Tools.SignalMapper.Detail.Kind.probeSent
    case .probeReply: L10n.Tools.Tools.SignalMapper.Detail.Kind.probeReply
    case .probeLost: L10n.Tools.Tools.SignalMapper.Detail.Kind.probeLost
    case .ack: L10n.Tools.Tools.SignalMapper.Detail.Kind.delivered
    case .sent: L10n.Tools.Tools.SignalMapper.Detail.Kind.sent
    case .observer: L10n.Tools.Tools.SignalMapper.Detail.Kind.observer
    case .breadcrumb: L10n.Tools.Tools.SignalMapper.Detail.Kind.breadcrumb
    case .radioLink: L10n.Tools.Tools.SignalMapper.Detail.Kind.radioLink
    }
  }
}

/// The delete affordance's four steps, oldest-first (§5, "a delete rows older than control").
enum MapperDataDeleteScope: String, CaseIterable, Identifiable, Sendable {
  case olderThan24Hours
  case olderThan7Days
  case olderThan30Days
  case everything

  var id: String {
    rawValue
  }

  /// The cutoff rows must be *older* than, or nil for "everything, whatever its age".
  func cutoff(from anchor: Date) -> Date? {
    switch self {
    case .olderThan24Hours: anchor.addingTimeInterval(-24 * 3600)
    case .olderThan7Days: anchor.addingTimeInterval(-7 * 24 * 3600)
    case .olderThan30Days: anchor.addingTimeInterval(-30 * 24 * 3600)
    case .everything: nil
    }
  }

  var name: String {
    switch self {
    case .olderThan24Hours: L10n.Settings.SignalMapperData.Delete.olderThan24Hours
    case .olderThan7Days: L10n.Settings.SignalMapperData.Delete.olderThan7Days
    case .olderThan30Days: L10n.Settings.SignalMapperData.Delete.olderThan30Days
    case .everything: L10n.Settings.SignalMapperData.Delete.everything
    }
  }
}

/// One repeater the window heard, as the picker lists it.
struct MapperExportRepeaterOption: Identifiable, Equatable, Sendable {
  let hexID: String
  /// Resolved from the contact list at read time; empty when nothing answers to this hash.
  let name: String

  var id: String {
    hexID
  }

  var label: String {
    name.isEmpty ? hexID : L10n.Settings.SignalMapperData.Repeater.named(name, hexID)
  }
}

// MARK: - Screen

/// Settings › Signal Mapper › Data (docs/SIGNAL_MAPPER_V3.md §5, mockup screen 5).
///
/// What the observation table costs, how long it is kept, an export of any slice of it, the
/// publish switch that stays off until the Austin CoreScope instance is ready for it (§9), and
/// the user's own hand on the retention lever.
///
/// Every figure on this screen is a query, never a cached total: the row count, the size, the
/// oldest row, the export's row count and the four delete counts are all read from the store on
/// appear and again after every action, because the one thing a data screen must never do is
/// tell somebody they deleted 12 000 rows and then keep showing 41 208.
struct SignalMapperDataView: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme

  private let tuningStore = MapperTuningStore()

  /// The instant every window on this screen is measured from. Held still so the export's
  /// filter is a stable value — see ``MapperExportDateRange/since(from:)``.
  @State private var anchor = Date()
  @State private var summary: StorageSummary?
  @State private var retentionDays = MapperTuning.defaults.rawRetentionDays

  @State private var dateRange = MapperExportDateRange.last30Days
  @State private var hexagonScope = MapperExportHexagonScope.all
  @State private var repeaterHexID: String?
  @State private var selectedKinds = Set(MapperExportKindGroup.allCases)
  @State private var format = MapperObservationExportFormat.csv

  @State private var repeaters: [MapperExportRepeaterOption] = []
  /// The newest ride, or nil when no ride was ever recorded — which is what hides the "This
  /// ride" scope rather than offering a choice that selects nothing.
  @State private var latestRunID: UUID?
  @State private var matchingRows: Int?
  @State private var deleteCounts: [MapperDataDeleteScope: Int] = [:]

  @State private var isExporting = false
  @State private var exportedFile: ExportedLogFile?
  @State private var exportFailed = false
  @State private var pendingDelete: MapperDataDeleteScope?

  /// Publishing is drawn and disabled, not hidden (§9): the switch is the honest place to say
  /// that nothing leaves this phone yet, and a screen with no mention of it would leave a
  /// reader wondering.
  private let isPublishEnabled = false

  var body: some View {
    List {
      observationsSection
      exportSection
      sharingSection
      deleteSection
    }
    .themedCanvas(theme)
    .navigationTitle(L10n.Settings.SignalMapperData.title)
    .navigationBarTitleDisplayMode(.inline)
    .task { await refresh() }
    // Debounced: the count is a `fetchCount` over up to 90 days of rows and the filters are
    // pickers, so a user walking down the menu would otherwise fire one query per highlighted
    // row. The task is keyed on the filter value itself, so an edit that lands back on the
    // previous selection costs nothing at all.
    .task(id: filter) {
      do {
        try await Task.sleep(for: .milliseconds(250))
      } catch {
        return
      }
      await recount()
    }
    .sheet(item: $exportedFile) { file in
      ActivityView(activityItems: [file.url])
    }
    // The file is a full-precision copy of the most sensitive table in the app; it exists for
    // exactly as long as the share does, the same contract the ride export keeps.
    .onDisappear { MapperRideExport.deleteExports() }
    .alert(
      L10n.Settings.SignalMapperData.Export.failed,
      isPresented: $exportFailed
    ) {
      Button(L10n.Localizable.Common.ok, role: .cancel) {}
    }
    .confirmationDialog(
      deleteConfirmationTitle,
      isPresented: deleteConfirmationBinding,
      titleVisibility: .visible
    ) {
      if let pendingDelete {
        Button(L10n.Settings.SignalMapperData.Delete.confirm, role: .destructive) {
          delete(pendingDelete)
        }
      }
    } message: {
      Text(L10n.Settings.SignalMapperData.Delete.confirmMessage)
    }
  }

  // MARK: - Observations

  private var observationsSection: some View {
    Section {
      LabeledContent(
        L10n.Settings.SignalMapperData.observations,
        value: summary.map {
          L10n.Settings.SignalMapperData.rows(
            $0.rowCount.formatted(.number),
            Int64($0.approximateBytes).formatted(.byteCount(style: .file))
          )
        } ?? "—"
      )

      LabeledContent(
        L10n.Settings.SignalMapperData.oldestKept,
        value: summary?.oldest.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—"
      )

      Picker(L10n.Settings.SignalMapperData.keepFor, selection: $retentionDays) {
        ForEach(retentionOptions, id: \.self) { days in
          Text(L10n.Settings.SignalMapperData.days(days)).tag(days)
        }
      }
      .onChange(of: retentionDays) { _, newValue in
        var tuning = tuningStore.tuning
        tuning.rawRetentionDays = newValue
        tuningStore.save(tuning)
      }
    } header: {
      Text(L10n.Settings.SignalMapperData.subtitle)
    } footer: {
      Text(L10n.Settings.SignalMapperData.retentionFooter)
    }
    .themedRowBackground(theme)
  }

  /// The four offered windows, plus whatever the debug panel's free-form stepper has already
  /// stored — a picker with no tag matching the stored value renders blank and would silently
  /// rewrite the setting on the first touch.
  private var retentionOptions: [Int] {
    Set([30, 90, 180, 365, retentionDays]).sorted()
  }

  // MARK: - Export

  private var exportSection: some View {
    Section {
      Picker(L10n.Settings.SignalMapperData.Export.dates, selection: $dateRange) {
        ForEach(MapperExportDateRange.allCases) { range in
          Text(range.name).tag(range)
        }
      }

      if latestRunID != nil {
        Picker(L10n.Settings.SignalMapperData.Export.hexagons, selection: $hexagonScope) {
          ForEach(MapperExportHexagonScope.allCases) { scope in
            Text(scope.name).tag(scope)
          }
        }
      }

      Picker(L10n.Settings.SignalMapperData.Export.repeater, selection: $repeaterHexID) {
        Text(L10n.Settings.SignalMapperData.Repeater.any).tag(String?.none)
        ForEach(repeaters) { option in
          Text(option.label).tag(String?.some(option.hexID))
        }
      }

      NavigationLink {
        MapperExportKindsPicker(selection: $selectedKinds)
      } label: {
        LabeledContent(L10n.Settings.SignalMapperData.Export.kinds, value: kindsSummary)
      }

      Picker(L10n.Settings.SignalMapperData.Export.format, selection: $format) {
        ForEach(MapperObservationExportFormat.allCases) { option in
          Text(option.displayName).tag(option)
        }
      }

      Button(action: runExport) {
        HStack {
          Text(L10n.Settings.SignalMapperData.Export.run((matchingRows ?? 0).formatted(.number)))
          Spacer()
          if isExporting {
            ProgressView()
          }
        }
      }
      .disabled(isExporting || (matchingRows ?? 0) == 0)
    } header: {
      Text(L10n.Settings.SignalMapperData.Export.header)
    } footer: {
      Text(L10n.Settings.SignalMapperData.Export.footer)
    }
    .themedRowBackground(theme)
  }

  private var kindsSummary: String {
    if selectedKinds.count == MapperExportKindGroup.allCases.count {
      return L10n.Settings.SignalMapperData.Kinds.all
    }
    if selectedKinds.isEmpty {
      return L10n.Settings.SignalMapperData.Kinds.noneSelected
    }
    return MapperExportKindGroup.allCases
      .filter(selectedKinds.contains)
      .map(\.name)
      .joined(separator: " · ")
  }

  /// What the count, the export and nothing else read. A computed value rather than state, so
  /// the debounced count task and the export can never disagree about what is being exported.
  private var filter: MapperSampleFilter {
    MapperSampleFilter(
      since: dateRange.since(from: anchor),
      // "This ride" is the ride's *rows*, not its hexagons: a row the ride recorded with no
      // fix belongs to the ride and to no hexagon, and scoping by cell would drop it.
      runID: hexagonScope == .thisRide ? latestRunID : nil,
      repeaterHexID: repeaterHexID,
      // All ten groups selected means *no* kind clause, not a list of the thirteen kinds this
      // build knows: a row written by a future build with a kind this one cannot name is still
      // the user's data and still belongs in an unfiltered export.
      kinds: selectedKinds.count == MapperExportKindGroup.allCases.count
        ? nil
        : Set(selectedKinds.flatMap(\.kinds))
    )
  }

  // MARK: - Sharing

  private var sharingSection: some View {
    Section {
      Toggle(isOn: .constant(isPublishEnabled)) {
        TintedLabel(
          L10n.Settings.SignalMapperData.Sharing.publish,
          systemImage: "antenna.radiowaves.left.and.right"
        )
      }
      .disabled(true)
    } header: {
      Text(L10n.Settings.SignalMapperData.Sharing.header)
    } footer: {
      Text(L10n.Settings.SignalMapperData.Sharing.footer)
    }
    .themedRowBackground(theme)
  }

  // MARK: - Delete

  private var deleteSection: some View {
    Section {
      Menu {
        ForEach(MapperDataDeleteScope.allCases) { scope in
          Button(scope.name, role: .destructive) { pendingDelete = scope }
            .disabled((deleteCounts[scope] ?? 0) == 0)
        }
      } label: {
        Text(L10n.Settings.SignalMapperData.Delete.button)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(.rect)
      }
    }
    .themedRowBackground(theme)
  }

  /// `.confirmationDialog(isPresented:)` rather than `item:` so the title can name the row
  /// count, which is the whole point of confirming: "Delete 12 940 rows?" is a decision,
  /// "Are you sure?" is not.
  private var deleteConfirmationBinding: Binding<Bool> {
    Binding(
      get: { pendingDelete != nil },
      set: { if !$0 { pendingDelete = nil } }
    )
  }

  private var deleteConfirmationTitle: String {
    let count = pendingDelete.flatMap { deleteCounts[$0] } ?? 0
    return L10n.Settings.SignalMapperData.Delete.confirmTitle(count.formatted(.number))
  }

  // MARK: - Loading

  private struct StorageSummary: Equatable {
    let rowCount: Int
    let oldest: Date?
    let approximateBytes: Int
  }

  /// Section 1, the pickers' contents and the delete counts, in one pass.
  ///
  /// Every query is an `await` onto the store actor, so the counting and the chunked walks
  /// happen there and only the results land back here.
  private func refresh() async {
    retentionDays = tuningStore.tuning.rawRetentionDays
    anchor = Date()
    guard let store = await appState.resolveMapperRawLogStore() else { return }

    if let read = try? await store.storageSummary() {
      summary = StorageSummary(
        rowCount: read.rowCount,
        oldest: read.oldest,
        approximateBytes: read.approximateBytes
      )
    }

    await loadRepeaters(store: store)
    await loadLatestRun(store: store)
    await loadDeleteCounts(store: store)
    await recount()
  }

  /// The picker's repeaters, named through the same resolver the cell card uses so a repeater
  /// reads identically on the map, on the card and in the file.
  private func loadRepeaters(store: MapperRawLogStore) async {
    guard let hexIDs = try? await store.distinctRepeaterHexIDs(since: nil) else { return }
    let candidates = await resolutionCandidates()
    let now = anchor
    let names = MapperObservationExport.repeaterNames(for: hexIDs, candidates: candidates, now: now)
    repeaters = hexIDs
      .map { MapperExportRepeaterOption(hexID: $0, name: names[$0] ?? "") }
      .sorted { lhs, rhs in
        // Named repeaters first and alphabetically, then the bare hashes: a picker that led
        // with `0C13` would bury the three the user can actually recognise.
        switch (lhs.name.isEmpty, rhs.name.isEmpty) {
        case (false, true): true
        case (true, false): false
        default: lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
      }
    // A repeater that aged out of retention between two visits must not stay selected, or the
    // export would silently be of nothing.
    if let repeaterHexID, !hexIDs.contains(repeaterHexID) { self.repeaterHexID = nil }
  }

  private func loadLatestRun(store: MapperRawLogStore) async {
    latestRunID = try? await store.latestRunID()
    // A ride that aged out of retention between two visits takes the scope with it, rather
    // than leaving a selection that now matches nothing.
    if latestRunID == nil { hexagonScope = .all }
  }

  private func loadDeleteCounts(store: MapperRawLogStore) async {
    var counts: [MapperDataDeleteScope: Int] = [:]
    for scope in MapperDataDeleteScope.allCases {
      let scopeFilter = MapperSampleFilter(until: scope.cutoff(from: anchor))
      counts[scope] = await (try? store.countSamples(matching: scopeFilter)) ?? 0
    }
    deleteCounts = counts
  }

  private func recount() async {
    guard let store = await appState.resolveMapperRawLogStore() else { return }
    matchingRows = try? await store.countSamples(matching: filter)
  }

  /// The pool repeater hashes resolve names against: contacts and discovered nodes alike — the
  /// same two sources `SignalMapperCoverageModel.resolutionCandidates` draws on.
  private func resolutionCandidates() async -> [AnyResolvableNode] {
    guard let dataStore = appState.services?.dataStore,
          let radioID = appState.currentRadioID else { return [] }
    let contacts = await (try? dataStore.fetchContacts(radioID: radioID)) ?? []
    let discovered = await (try? dataStore.fetchDiscoveredNodes(radioID: radioID)) ?? []
    return contacts.map(AnyResolvableNode.init) + discovered.map(AnyResolvableNode.init)
  }

  // MARK: - Actions

  private func runExport() {
    isExporting = true
    let exportFilter = filter
    let exportFormat = format
    let day = anchor
    Task {
      defer { isExporting = false }
      guard let store = await appState.resolveMapperRawLogStore() else {
        exportFailed = true
        return
      }
      let hexIDs = await (try? store.distinctRepeaterHexIDs(since: exportFilter.since)) ?? []
      let candidates = await resolutionCandidates()
      let names = MapperObservationExport.repeaterNames(
        for: hexIDs,
        candidates: candidates,
        now: day
      )
      do {
        let url = try await MapperObservationExport.export(
          matching: exportFilter,
          format: exportFormat,
          repeaterNames: names,
          store: store,
          day: day
        )
        exportedFile = ExportedLogFile(url: url)
      } catch {
        exportFailed = true
      }
    }
  }

  private func delete(_ scope: MapperDataDeleteScope) {
    pendingDelete = nil
    Task {
      guard let store = await appState.resolveMapperRawLogStore() else { return }
      if let cutoff = scope.cutoff(from: anchor) {
        _ = try? await store.deleteSamples(olderThan: cutoff)
      } else {
        try? await store.deleteAll()
      }
      await refresh()
    }
  }
}

// MARK: - Kinds picker

/// The kind multi-select, pushed rather than folded into a menu: ten toggles do not fit a
/// menu without becoming a list of checkmarks nobody can scan, and a `Picker` has no
/// multi-selection form.
private struct MapperExportKindsPicker: View {
  @Environment(\.appTheme) private var theme
  @Binding var selection: Set<MapperExportKindGroup>

  var body: some View {
    List {
      Section {
        ForEach(MapperExportKindGroup.allCases) { group in
          Toggle(group.name, isOn: binding(for: group))
        }
      } footer: {
        Text(L10n.Settings.SignalMapperData.Kinds.footer)
      }
      .themedRowBackground(theme)
    }
    .themedCanvas(theme)
    .navigationTitle(L10n.Settings.SignalMapperData.Export.kinds)
    .navigationBarTitleDisplayMode(.inline)
  }

  private func binding(for group: MapperExportKindGroup) -> Binding<Bool> {
    Binding(
      get: { selection.contains(group) },
      set: { isOn in
        if isOn {
          selection.insert(group)
        } else {
          selection.remove(group)
        }
      }
    )
  }
}

#Preview {
  NavigationStack {
    SignalMapperDataView()
  }
}
