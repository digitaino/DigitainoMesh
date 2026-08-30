import MC1Services
import SwiftUI

/// The mapper's manual transmitter: fire a discover, a trace, or a real flood packet by
/// hand, instead of waiting for the cadence to decide.
///
/// The automatic engine is deliberately narrow — zero-hop discovers and directed traces,
/// never flood-routed (`floodsPerTierCell = 0`, Rafael 2026-08-26). That keeps a
/// three-hour ride off everyone else's mesh, but it also means the survey never measures
/// the thing a *real* message does: get relayed. This sheet is where that measurement is
/// taken on purpose, one packet at a time, with the user's finger on it.
///
/// The flood goes out on a **private channel the user picks**, which is the mitigation:
/// the packet still traverses the mesh and still comes back as echoes the capture engine
/// folds as uplink evidence, but only holders of that key can read it. Nothing is
/// auto-selected and the public channel is unreachable — the point of the exercise is not
/// to put survey noise in front of people, and "the lowest-index private channel" is
/// somebody's group chat.
struct SignalMapperTransmitSheet: View {
  let model: SignalMapperCoverageModel

  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss

  @AppStorage(AppStorageKey.mapperFloodChannelIndex.rawValue)
  private var floodChannelIndex = AppStorageKey.defaultMapperFloodChannelIndex

  @State private var channels: [ChannelDTO] = []
  @State private var targets: [MapperProbeTarget] = []
  @State private var selectedTargetHex: String?
  @State private var isWorking = false
  @State private var outcome: Outcome?

  private struct Outcome: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let isFailure: Bool
  }

  private var isSurveying: Bool {
    appState.signalMapperRideSession != nil
  }

  var body: some View {
    NavigationStack {
      List {
        probesSection
        floodSection
        if let outcome {
          Section {
            Label(
              outcome.text,
              systemImage: outcome.isFailure ? "exclamationmark.triangle" : "checkmark.circle"
            )
            .font(.callout)
            .foregroundStyle(outcome.isFailure ? Color.orange : Color.green)
          }
        }
      }
      .navigationTitle(L10n.Tools.Tools.SignalMapper.Transmit.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.Localizable.Common.done) { dismiss() }
        }
      }
      .task { await load() }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }

  // MARK: - Probes

  @ViewBuilder
  private var probesSection: some View {
    Section {
      Button {
        run { await model.manualDiscover(appState: appState) }
      } label: {
        Label(L10n.Tools.Tools.SignalMapper.Transmit.discover, systemImage: "dot.radiowaves.left.and.right")
      }
      .disabled(!isSurveying || isWorking)

      if !targets.isEmpty {
        Picker(L10n.Tools.Tools.SignalMapper.Transmit.traceTarget, selection: $selectedTargetHex) {
          ForEach(targets, id: \.id.hex) { target in
            Text(targetLabel(target)).tag(Optional(target.id.hex))
          }
        }
        .disabled(!isSurveying || isWorking)
      }

      Button {
        guard let target = targets.first(where: { $0.id.hex == selectedTargetHex }) else { return }
        run { await model.manualTrace(appState: appState, target: target) }
      } label: {
        Label(L10n.Tools.Tools.SignalMapper.Transmit.trace, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
      }
      .disabled(!isSurveying || isWorking || selectedTargetHex == nil)
    } header: {
      Text(L10n.Tools.Tools.SignalMapper.Transmit.probesHeader)
    } footer: {
      Text(
        isSurveying
          ? L10n.Tools.Tools.SignalMapper.Transmit.probesFooter
          : L10n.Tools.Tools.SignalMapper.Transmit.needsSurvey
      )
    }
  }

  /// The engine knows repeaters by path hash only, so the name comes from the run's own
  /// display directory — the same lookup the ride rows use.
  private func targetLabel(_ target: MapperProbeTarget) -> String {
    guard let name = appState.signalMapperRideSession?.meta(for: target.id)?.name else {
      return target.id.hex
    }
    return "\(name) \(target.id.hex)"
  }

  // MARK: - Flood

  @ViewBuilder
  private var floodSection: some View {
    Section {
      Picker(L10n.Tools.Tools.SignalMapper.Transmit.channel, selection: $floodChannelIndex) {
        // Nothing is auto-selected. The lowest-index private channel is somebody's group
        // chat, and a flood on it is exactly the "bothering people" this whole design
        // avoids — the user picks, or makes a survey channel (review item 4).
        Text(L10n.Tools.Tools.SignalMapper.Transmit.noChannel).tag(0)
        ForEach(channels, id: \.index) { channel in
          Text(channel.name).tag(Int(channel.index))
        }
      }
      .disabled(isWorking)

      Button {
        run {
          guard let slot = await model.createSurveyChannel(
            appState: appState,
            name: L10n.Tools.Tools.SignalMapper.Transmit.channelName
          ) else { return false }
          await load()
          floodChannelIndex = Int(slot)
          return true
        }
      } label: {
        Label(L10n.Tools.Tools.SignalMapper.Transmit.createChannel, systemImage: "plus.circle")
      }
      .disabled(isWorking || appState.connectedDevice == nil)

      Button {
        run {
          await model.sendFloodProbe(
            appState: appState,
            channelIndex: UInt8(clamping: floodChannelIndex),
            text: L10n.Tools.Tools.SignalMapper.Transmit.floodText
          )
        }
      } label: {
        Label(L10n.Tools.Tools.SignalMapper.Transmit.flood, systemImage: "antenna.radiowaves.left.and.right")
      }
      .disabled(isWorking || floodChannelIndex == 0)
    } header: {
      Text(L10n.Tools.Tools.SignalMapper.Transmit.floodHeader)
    } footer: {
      Text(
        isSurveying
          ? L10n.Tools.Tools.SignalMapper.Transmit.floodFooter
          : L10n.Tools.Tools.SignalMapper.Transmit.floodFooterIdle
      )
    }
  }

  // MARK: - Plumbing

  private func load() async {
    channels = await model.floodChannels(appState: appState)
    // Never write the preference from a read path. `floodChannels` returns [] for any
    // failure — being disconnected included — so the old reassignment destroyed a saved
    // choice just by opening this sheet while the radio was away (review item 7).
    if !channels.isEmpty, !channels.contains(where: { Int($0.index) == floodChannelIndex }) {
      floodChannelIndex = 0
    }
    if let probe = appState.signalMapperProbeEngine {
      targets = await probe.addressableTargets()
      if selectedTargetHex == nil || !targets.contains(where: { $0.id.hex == selectedTargetHex }) {
        selectedTargetHex = targets.first?.id.hex
      }
    } else {
      targets = []
      selectedTargetHex = nil
    }
  }

  /// Runs one transmission and reports what happened. Every action here puts a packet on
  /// the air, so silence is not an acceptable answer — a refused probe (no fix, no budget,
  /// no radio) has to say so rather than look like a dead button.
  private func run(_ action: @escaping () async -> Bool) {
    guard !isWorking else { return }
    isWorking = true
    Task {
      let sent = await action()
      isWorking = false
      outcome = Outcome(
        text: sent
          ? L10n.Tools.Tools.SignalMapper.Transmit.sent
          : L10n.Tools.Tools.SignalMapper.Transmit.refused,
        isFailure: !sent
      )
    }
  }
}
