import MC1Services
import SwiftUI

/// The lock-on picker: choose up to three repeaters whose live two-leg signal the ride
/// HUD tracks (docs/ACTIVE_SURVEY_M3_5.md §2.7).
///
/// Candidates come from the contact table and the discovered-node pool — anything of
/// repeater type whose full public key is known, because a directed trace is addressed
/// with leading key bytes and a repeater we only know by hash cannot be probed. Position
/// and name are captured here into the session's display metadata: the engine itself
/// deliberately learns neither.
struct SignalMapperFocusPickerView: View {
  /// True when this picker IS the start flow: confirming starts the run with the
  /// selection (possibly empty), and the confirm button says so.
  var startsSurvey = false
  let onApply: ([MapperProbeTarget], [NodeHexID: SignalMapperRideSession.FocusMeta]) -> Void

  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss

  @State private var candidates: [Candidate] = []
  @State private var selectedHexIDs: Set<String> = []
  @State private var isLoading = true

  struct Candidate: Identifiable {
    let id: NodeHexID
    let publicKey: Data
    let name: String?
    let lastHeard: Date?
    let latitude: Double?
    let longitude: Double?
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          if isLoading {
            ProgressView()
              .frame(maxWidth: .infinity)
          } else if candidates.isEmpty {
            Text(L10n.Tools.Tools.SignalMapper.Focus.empty)
              .foregroundStyle(.secondary)
          } else {
            ForEach(candidates) { candidate in
              Button {
                toggle(candidate)
              } label: {
                HStack {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.name ?? candidate.id.hex)
                      .foregroundStyle(.primary)
                    if let lastHeard = candidate.lastHeard {
                      Text(lastHeard, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                  }
                  Spacer()
                  if selectedHexIDs.contains(candidate.id.hex) {
                    Image(systemName: "checkmark.circle.fill")
                      .foregroundStyle(.tint)
                  }
                }
              }
            }
          }
        } footer: {
          Text(L10n.Tools.Tools.SignalMapper.Focus.footer(SignalMapperProbeEngine.maxFocusTargets))
        }

        if startsSurvey {
          Section {
            Button(L10n.Tools.Tools.SignalMapper.Focus.startWithout) {
              selectedHexIDs = []
              apply()
              dismiss()
            }
          }
        }
      }
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
      .task { await loadCandidates() }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }

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

  private func loadCandidates() async {
    defer { isLoading = false }
    guard let dataStore = appState.services?.dataStore,
          let radioID = appState.currentRadioID else { return }
    // Trace paths are addressed at the device's hash width; targets derive their identity
    // the same way so the HUD and the engine agree on who is who.
    let width = min(3, Int(appState.connectedDevice?.pathHashMode ?? 0) + 1)

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
        guard byHex[NodeHexID(data: node.publicKey.prefix(width))?.hex ?? ""] == nil,
              let id = NodeHexID(data: node.publicKey.prefix(width)) else { continue }
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

    candidates = byHex.values.sorted { lhs, rhs in
      (lhs.lastHeard ?? .distantPast) > (rhs.lastHeard ?? .distantPast)
    }
    // Pre-select what the running session already focuses.
    if let session = appState.signalMapperRideSession {
      selectedHexIDs = Set(session.focusTargets.map(\.id.hex))
    }
  }
}
