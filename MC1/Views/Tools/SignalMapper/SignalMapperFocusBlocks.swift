import CoreLocation
import MC1Services
import SwiftUI

/// The ride readout, pinned as a bottom safe-area inset.
///
/// Two modes, one rule learned from v1 and re-learned from the second field test: **a
/// survey screen always shows who it is hearing, without being configured first.**
///
/// - **Locked on**: one block per chosen target, with the 4-state color, tones on
///   lost/regained, and the loss-streak machinery — the deliberate range-test mode.
/// - **Unconfigured**: the same blocks, auto-populated with the repeaters that answered
///   most recently (`heardStates` from the engine), under a "Hearing now" caption with a
///   lock-on button beside it. Before anything replies, a quiet "Listening…" row.
///
/// Blocks are near-opaque with the state carried by a 6 pt bar and a soft tint, numerals
/// in `.primary` at a scaling text style — glass and white-on-green both failed the
/// sunlight test (UI review S2).
struct SignalMapperFocusBlocks: View {
  let session: SignalMapperRideSession
  let onLockOn: () -> Void

  @Environment(\.appState) private var appState
  @State private var tonePlayer = RepeaterWatchTonePlayer()
  @State private var lastLinkStates: [String: FocusLinkState] = [:]
  @State private var hapticTrigger = 0
  @State private var hapticIsPositive = false

  /// The one-bit-per-target answer, derived from the engine's per-target state and the
  /// clock. Auto blocks use only the recency half (no probes are aimed at them, so
  /// `lossStreak`/`lastReplyAt` cadence semantics don't apply).
  enum FocusLinkState: Equatable {
    case heardBothWays
    case downlinkOnly
    case lost
    case unknown

    var color: Color {
      switch self {
      case .heardBothWays: .green
      case .downlinkOnly: .orange
      case .lost: .red
      case .unknown: .gray
      }
    }

    var localizedLabel: String {
      switch self {
      case .heardBothWays: L10n.Tools.Tools.SignalMapper.Focus.stateHeard
      case .downlinkOnly: L10n.Tools.Tools.SignalMapper.Focus.stateDownlinkOnly
      case .lost: L10n.Tools.Tools.SignalMapper.Focus.stateLost
      case .unknown: L10n.Tools.Tools.SignalMapper.Focus.stateUnknown
      }
    }
  }

  private var isLockedOn: Bool {
    !session.focusTargets.isEmpty
  }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      VStack(spacing: 6) {
        if !isLockedOn {
          autoCaption
        }
        content(now: context.date)
      }
      .padding(.horizontal, 12)
      .padding(.top, 8)
      .padding(.bottom, 12)
      .onChange(of: focusLinkStates(now: context.date)) { _, newStates in
        playEdges(newStates)
      }
      .sensoryFeedback(hapticIsPositive ? .success : .warning, trigger: hapticTrigger)
    }
    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
  }

  @ViewBuilder
  private func content(now: Date) -> some View {
    if isLockedOn {
      HStack(spacing: 8) {
        ForEach(session.focusTargets, id: \.id) { target in
          block(
            id: target.id,
            state: focusLinkState(for: target.id, now: now),
            activity: activity(for: target.id),
            now: now
          )
        }
      }
    } else {
      let heard = session.liveSnapshot?.heardStates ?? []
      if heard.isEmpty {
        listeningRow
      } else {
        HStack(spacing: 8) {
          ForEach(heard.prefix(3)) { activity in
            block(
              id: activity.id,
              state: recencyState(for: activity, now: now),
              activity: activity,
              now: now
            )
          }
        }
      }
    }
  }

  /// "Hearing now" + the lock-on affordance, side by side — locking on is a refinement
  /// of what the screen already shows, not the price of seeing anything at all.
  private var autoCaption: some View {
    HStack {
      Text(L10n.Tools.Tools.SignalMapper.Ride.hearingNow)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      Spacer()
      Button(action: onLockOn) {
        Label(L10n.Tools.Tools.SignalMapper.Ride.lockOn, systemImage: "scope")
          .font(.caption.weight(.semibold))
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
  }

  private var listeningRow: some View {
    HStack(spacing: 8) {
      Image(systemName: "ear.badge.waveform")
        .foregroundStyle(.secondary)
      Text(L10n.Tools.Tools.SignalMapper.Ride.listening)
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Spacer()
    }
    .padding(.vertical, 14)
    .padding(.horizontal, 14)
    .background(Color(.secondarySystemBackground).opacity(0.95), in: .rect(cornerRadius: 14))
    .accessibilityElement(children: .combine)
  }

  // MARK: - One block

  private func block(
    id: NodeHexID,
    state: FocusLinkState,
    activity: SignalMapperProbeEngine.FocusTargetState?,
    now: Date
  ) -> some View {
    let name = session.meta(for: id)?.name ?? id.hex

    return VStack(spacing: 2) {
      Text(name)
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .foregroundStyle(.primary)

      Text(uplinkText(for: activity))
        .font(.system(.largeTitle, design: .rounded, weight: .bold))
        .monospacedDigit()
        .lineLimit(1)
        .foregroundStyle(.primary)
        .contentTransition(.numericText())

      Text(secondaryText(for: id, activity: activity, now: now))
        .font(.caption)
        .monospacedDigit()
        .lineLimit(1)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 10)
    .padding(.horizontal, 6)
    .background {
      RoundedRectangle(cornerRadius: 16)
        .fill(Color(.secondarySystemBackground).opacity(0.95))
        .overlay {
          RoundedRectangle(cornerRadius: 16)
            .fill(state.color.opacity(0.14))
        }
        .overlay(alignment: .top) {
          Capsule()
            .fill(state.color)
            .frame(height: 6)
            .padding(.horizontal, 14)
            .padding(.top, 4)
        }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel(name: name, state: state, activity: activity))
  }

  /// The big number is the uplink — "how well do they hear me" is the ride's question.
  private func uplinkText(for activity: SignalMapperProbeEngine.FocusTargetState?) -> String {
    if let txSnr = activity?.lastTxSnr {
      return String(format: "▲%.0f", txSnr)
    }
    return "▲–"
  }

  private func secondaryText(
    for id: NodeHexID,
    activity: SignalMapperProbeEngine.FocusTargetState?,
    now: Date
  ) -> String {
    var parts: [String] = []
    if let rxSnr = activity?.lastRxSnr {
      parts.append(String(format: "▼%.0f", rxSnr))
    }
    if let heard = activity?.lastHeardAt {
      parts.append(L10n.Tools.Tools.SignalMapper.Ride.age(Int(now.timeIntervalSince(heard))))
    }
    if let distance = currentDistanceMeters(to: id) {
      parts.append(distanceText(distance))
    }
    return parts.isEmpty ? " " : parts.joined(separator: "  ")
  }

  private func accessibilityLabel(
    name: String,
    state: FocusLinkState,
    activity: SignalMapperProbeEngine.FocusTargetState?
  ) -> String {
    var label = "\(name), \(state.localizedLabel)"
    if let txSnr = activity?.lastTxSnr {
      label += ", " + L10n.Tools.Tools.SignalMapper.Focus.uplinkAccessibility(Int(txSnr.rounded()))
    }
    return label
  }

  // MARK: - State machines

  private func activity(for id: NodeHexID) -> SignalMapperProbeEngine.FocusTargetState? {
    session.liveSnapshot?.focusStates.first { $0.id == id }
  }

  private func focusLinkState(for id: NodeHexID, now: Date) -> FocusLinkState {
    guard session.isRadioConnected, let focus = activity(for: id) else { return .unknown }
    if focus.lossStreak >= 3 { return .lost }
    let interval = session.focusProbeInterval
    if let reply = focus.lastReplyAt, now.timeIntervalSince(reply) <= max(interval * 2, 45) {
      return .heardBothWays
    }
    if let heard = focus.lastHeardAt, now.timeIntervalSince(heard) <= 60 {
      return .downlinkOnly
    }
    return .unknown
  }

  /// Auto blocks aren't probed on a cadence, so their state is recency alone: replied
  /// in the last 30 s → green; heard within 90 s → amber; older → gray.
  private func recencyState(
    for activity: SignalMapperProbeEngine.FocusTargetState,
    now: Date
  ) -> FocusLinkState {
    guard session.isRadioConnected, let heard = activity.lastHeardAt else { return .unknown }
    let age = now.timeIntervalSince(heard)
    if age <= 30, activity.lastReplyAt != nil { return .heardBothWays }
    if age <= 90 { return .downlinkOnly }
    return .unknown
  }

  private func focusLinkStates(now: Date) -> [String: FocusLinkState] {
    var states: [String: FocusLinkState] = [:]
    for target in session.focusTargets {
      states[target.id.hex] = focusLinkState(for: target.id, now: now)
    }
    return states
  }

  /// Edge-triggered audio for LOCKED-ON targets only: entering `.lost` plays a tock,
  /// regaining a two-way link plays a note. Auto blocks churn as the neighbourhood
  /// changes and must stay silent.
  private func playEdges(_ newStates: [String: FocusLinkState]) {
    defer { lastLinkStates = newStates }
    for (id, state) in newStates {
      guard let previous = lastLinkStates[id], previous != state else { continue }
      if state == .lost, previous != .unknown {
        tonePlayer.play(.tock)
        hapticIsPositive = false
        hapticTrigger += 1
      } else if state == .heardBothWays, previous == .lost {
        tonePlayer.play(.note)
        hapticIsPositive = true
        hapticTrigger += 1
      }
    }
  }

  // MARK: - Distance

  private func currentDistanceMeters(to id: NodeHexID) -> Double? {
    guard let meta = session.meta(for: id),
          let latitude = meta.latitude, let longitude = meta.longitude,
          let here = appState.locationService.currentLocation else { return nil }
    return here.distance(from: CLLocation(latitude: latitude, longitude: longitude))
  }

  private func distanceText(_ meters: Double) -> String {
    meters >= 1000
      ? String(format: "%.1f km", meters / 1000)
      : String(format: "%.0f m", meters)
  }
}
