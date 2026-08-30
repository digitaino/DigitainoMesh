import CoreLocation
import MC1Services
import SwiftUI

/// The lock-on picker: choose up to three repeaters whose live two-leg signal the ride
/// tracks (docs/ACTIVE_SURVEY_M3_5.md §2.7).
///
/// The list is organized around what the session already knows, not the raw table order
/// the first field test rightly called sloppy: repeaters that answered **this session**
/// lead (with their live signal), then everything with a known position sorted by
/// **distance from here** (distance shown), then the rest — with search across all of
/// it. Candidates need a full public key, because a directed trace is addressed with
/// leading key bytes; position and name are captured into the session's display
/// metadata — the engine deliberately learns neither.
struct SignalMapperFocusPickerView: View {
  /// True when this picker IS the start flow: confirming starts the run with the
  /// selection (possibly empty), and the confirm button says so.
  var startsSurvey = false
  /// Pre-fills the search field — set when the picker is opened from a repeater chip on
  /// the cell card, so the repeater the rider just tapped is the row in front of them.
  var initialSearch = ""
  let onApply: ([MapperProbeTarget], [NodeHexID: SignalMapperRideSession.FocusMeta]) -> Void

  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss

  @State private var candidates: [Candidate] = []
  @State private var liveSignals: [String: LiveSignal] = [:]
  @State private var selectedHexIDs: Set<String> = []
  @State private var searchText = ""
  @State private var isLoading = true

  /// What "we can hear this one right now" looks like, from whichever system knows.
  ///
  /// Before a run there is no probe engine, and this section used to be empty on the one
  /// screen whose entire question is "who can I hear from here" — while the signal-bars
  /// table, which had the answer, was never asked. The two systems already share every
  /// wire-parsing rule; this is the other half of sharing them (Rafael, 2026-08-30).
  struct LiveSignal {
    var rxSnr: Double?
    var txSnr: Double?
    var lastHeard: Date?
  }

  /// How recently a repeater must have been heard to count as "heard now".
  private static let liveHeardWindow: TimeInterval = 300

  struct Candidate: Identifiable {
    let id: NodeHexID
    let publicKey: Data
    let name: String?
    let lastHeard: Date?
    let latitude: Double?
    let longitude: Double?
    var distanceMeters: Double?

    var displayName: String {
      name ?? id.hex
    }
  }

  var body: some View {
    NavigationStack {
      List {
        if isLoading {
          ProgressView()
            .frame(maxWidth: .infinity)
        } else if candidates.isEmpty {
          Text(L10n.Tools.Tools.SignalMapper.Focus.empty)
            .foregroundStyle(.secondary)
        } else if !searchText.isEmpty {
          Section {
            ForEach(searchResults) { row(for: $0) }
          } footer: {
            footer
          }
        } else {
          sections
        }

        if startsSurvey, !isLoading {
          Section {
            Button(L10n.Tools.Tools.SignalMapper.Focus.startWithout) {
              selectedHexIDs = []
              apply()
              dismiss()
            }
          }
        }
      }
      .searchable(
        text: $searchText,
        placement: .navigationBarDrawer(displayMode: .always),
        prompt: L10n.Tools.Tools.SignalMapper.Focus.search
      )
      .navigationTitle(L10n.Tools.Tools.SignalMapper.Ride.lockOn)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.Localizable.Common.cancel) { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(
            startsSurvey
              ? L10n.Tools.Tools.SignalMapper.Survey.start
              : L10n.Tools.Tools.SignalMapper.Focus.apply
          ) {
            apply()
            dismiss()
          }
          .fontWeight(.semibold)
        }
      }
      .task {
        searchText = initialSearch
        await loadCandidates()
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }

  // MARK: - Sections

  /// Heard this session → nearby by distance → the rest. Each candidate appears once,
  /// in the best section it qualifies for.
  @ViewBuilder
  private var sections: some View {
    let heard = candidates.filter { liveSignals[$0.id.hex] != nil }
      .sorted { heardAt($0) > heardAt($1) }
    let nearby = candidates.filter { liveSignals[$0.id.hex] == nil && $0.distanceMeters != nil }
      .sorted { ($0.distanceMeters ?? .infinity) < ($1.distanceMeters ?? .infinity) }
    let other = candidates.filter { liveSignals[$0.id.hex] == nil && $0.distanceMeters == nil }
      .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

    if !heard.isEmpty {
      Section(L10n.Tools.Tools.SignalMapper.Focus.sectionHeard) {
        ForEach(heard) { row(for: $0) }
      }
    }
    if !nearby.isEmpty {
      Section(L10n.Tools.Tools.SignalMapper.Focus.sectionNearby) {
        ForEach(nearby) { row(for: $0) }
      }
    }
    if !other.isEmpty {
      Section {
        ForEach(other) { row(for: $0) }
      } header: {
        // The header only earns its ink when there is something above it to
        // distinguish from.
        if !heard.isEmpty || !nearby.isEmpty {
          Text(L10n.Tools.Tools.SignalMapper.Focus.sectionOther)
        }
      } footer: {
        footer
      }
    } else if !heard.isEmpty || !nearby.isEmpty {
      Section {} footer: { footer }
    }
  }

  private var footer: some View {
    Text(L10n.Tools.Tools.SignalMapper.Focus.footer(SignalMapperProbeEngine.maxFocusTargets))
  }

  private var searchResults: [Candidate] {
    candidates
      .filter { $0.displayName.localizedCaseInsensitiveContains(searchText) || $0.id.hex.localizedCaseInsensitiveContains(searchText) }
      .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
  }

  private func heardAt(_ candidate: Candidate) -> Date {
    liveSignals[candidate.id.hex]?.lastHeard ?? .distantPast
  }

  // MARK: - Row

  private func row(for candidate: Candidate) -> some View {
    Button {
      toggle(candidate)
    } label: {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text(candidate.displayName)
            .foregroundStyle(.primary)
          Text(subtitle(for: candidate))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer()
        if let live = liveSignals[candidate.id.hex] {
          liveSignal(live)
        }
        Image(
          systemName: selectedHexIDs.contains(candidate.id.hex)
            ? "checkmark.circle.fill"
            : "circle"
        )
        .foregroundStyle(selectedHexIDs.contains(candidate.id.hex) ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
        .imageScale(.large)
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
  }

  /// Distance first when known — "how far is this repeater" is the ride's organizing
  /// question — then recency.
  private func subtitle(for candidate: Candidate) -> String {
    var parts: [String] = []
    if let distance = candidate.distanceMeters {
      parts.append(
        distance >= 1000
          ? String(format: "%.1f km", distance / 1000)
          : String(format: "%.0f m", distance)
      )
    }
    if let live = liveSignals[candidate.id.hex], let heard = live.lastHeard {
      parts.append(heard.formatted(.relative(presentation: .named)))
    } else if let lastHeard = candidate.lastHeard {
      parts.append(lastHeard.formatted(.relative(presentation: .named)))
    }
    return parts.isEmpty ? candidate.id.hex : parts.joined(separator: " · ")
  }

  /// The live two-leg readout for a repeater this session has heard: ▲ their reading
  /// of us, ▼ ours of them — the same glyph language the ride blocks use.
  private func liveSignal(_ live: LiveSignal) -> some View {
    VStack(alignment: .trailing, spacing: 0) {
      if let txSnr = live.txSnr {
        Text(String(format: "▲%.0f", txSnr))
      }
      if let rxSnr = live.rxSnr {
        Text(String(format: "▼%.0f", rxSnr))
      }
    }
    .font(.caption.weight(.semibold))
    .monospacedDigit()
    .foregroundStyle(.secondary)
  }

  // MARK: - Actions

  private func toggle(_ candidate: Candidate) {
    if selectedHexIDs.contains(candidate.id.hex) {
      selectedHexIDs.remove(candidate.id.hex)
    } else if selectedHexIDs.count < SignalMapperProbeEngine.maxFocusTargets {
      selectedHexIDs.insert(candidate.id.hex)
    }
  }

  private func apply() {
    let selected = candidates.filter { selectedHexIDs.contains($0.id.hex) }
    let targets = selected.map {
      MapperProbeTarget(id: $0.id, publicKey: $0.publicKey, lastHeard: $0.lastHeard)
    }
    var meta: [NodeHexID: SignalMapperRideSession.FocusMeta] = [:]
    for candidate in selected {
      meta[candidate.id] = SignalMapperRideSession.FocusMeta(
        name: candidate.name,
        latitude: candidate.latitude,
        longitude: candidate.longitude
      )
    }
    onApply(targets, meta)
  }

  // MARK: - Loading

  private func loadCandidates() async {
    defer { isLoading = false }
    guard let dataStore = appState.services?.dataStore,
          let radioID = appState.currentRadioID else { return }
    // Trace paths are addressed at the device's hash width; targets derive their identity
    // the same way so the blocks and the engine agree on who is who.
    let width = min(3, Int(appState.connectedDevice?.pathHashMode ?? 0) + 1)
    let here = appState.locationService.currentLocation

    var byHex: [String: Candidate] = [:]
    if let contacts = try? await dataStore.fetchContacts(radioID: radioID) {
      for contact in contacts where contact.type == .repeater {
        guard let id = NodeHexID(data: contact.publicKey.prefix(width)) else { continue }
        byHex[id.hex] = Candidate(
          id: id,
          publicKey: contact.publicKey,
          name: contact.name,
          lastHeard: contact.lastHeardTimestamp.map { Date(timeIntervalSince1970: Double($0)) },
          latitude: contact.hasLocation ? contact.latitude : nil,
          longitude: contact.hasLocation ? contact.longitude : nil
        )
      }
    }
    if let discovered = try? await dataStore.fetchDiscoveredNodes(radioID: radioID) {
      for node in discovered where node.nodeType == .repeater {
        guard let id = NodeHexID(data: node.publicKey.prefix(width)),
              byHex[id.hex] == nil else { continue }
        byHex[id.hex] = Candidate(
          id: id,
          publicKey: node.publicKey,
          name: node.name,
          lastHeard: node.lastHeard,
          latitude: node.hasLocation ? node.latitude : nil,
          longitude: node.hasLocation ? node.longitude : nil
        )
      }
    }

    // Distance from the freshest fix, when both ends are known.
    if let here {
      for (hex, candidate) in byHex {
        guard let latitude = candidate.latitude, let longitude = candidate.longitude else { continue }
        var updated = candidate
        updated.distanceMeters = here.distance(
          from: CLLocation(latitude: latitude, longitude: longitude)
        )
        byHex[hex] = updated
      }
    }

    // Who we can hear right now. During a run the probe engine is authoritative — it is
    // the thing actually sending the probes. Outside one, the signal-bars table already
    // knows, and asking it is what makes this section useful in the start flow.
    // The bars table hides rows only at 15 minutes, and "Heard This Session" has to mean
    // heard, not "seen this quarter hour" — a stale row would outrank a genuinely nearby
    // candidate and show a stale SNR next to it.
    let heardCutoff = Date().addingTimeInterval(-Self.liveHeardWindow)
    var live: [String: LiveSignal] = [:]
    for repeater in appState.repeaterSignals.displayRepeaters
    where repeater.lastHeard >= heardCutoff {
      live[repeater.id.hex] = LiveSignal(
        rxSnr: repeater.rxSnr,
        txSnr: repeater.txSnr,
        lastHeard: repeater.lastHeard
      )
      // A repeater the bars table has a key for but the stores do not is still a valid
      // lock-on target — a directed trace only needs the leading key bytes.
      if byHex[repeater.id.hex] == nil, let key = repeater.publicKey {
        byHex[repeater.id.hex] = Candidate(
          id: repeater.id,
          publicKey: key,
          name: repeater.name,
          lastHeard: repeater.lastHeard,
          latitude: nil,
          longitude: nil
        )
      }
    }
    if let probe = appState.signalMapperProbeEngine {
      let snapshot = await probe.snapshot()
      for activity in snapshot.focusStates + snapshot.heardStates where activity.lastHeardAt != nil {
        live[activity.id.hex] = LiveSignal(
          rxSnr: activity.lastRxSnr,
          txSnr: activity.lastTxSnr,
          lastHeard: activity.lastHeardAt
        )
      }
    }
    liveSignals = live

    candidates = Array(byHex.values)
    // Pre-select what the running session already focuses.
    if let session = appState.signalMapperRideSession {
      selectedHexIDs = Set(session.focusTargets.map(\.id.hex))
    }
  }
}
