import CoreLocation
import MC1Services
import SwiftUI

/// The lock-on readout: one compact block per focus target, pinned as a bottom safe-area
/// inset so the map above stays the hero (UI review §1: the first design stacked this
/// above a 211 pt control column and the whole card landed mid-screen).
///
/// Visual language (review S2, contrast): the block itself is near-opaque system
/// background — glass is decorative at 25 km/h — with the link state carried by a 6 pt
/// bar across the top and a soft tint, while the numerals stay `.primary` for maximum
/// contrast in sunlight. The big number is the uplink ("how well do they hear me?"),
/// in a text style that scales with Dynamic Type instead of a fixed 34 pt.
///
/// Audio is primary feedback: a bar-mounted phone transmits no haptic worth having, so
/// a lost target plays a tock and a regained one a note through the same
/// `.playback`+`.mixWithOthers` session the repeater watch screen proved. Edge-triggered
/// only — a tone per reply at probe cadence would be unbearable.
struct SignalMapperFocusBlocks: View {
  let session: SignalMapperRideSession

  @Environment(\.appState) private var appState
  @State private var tonePlayer = RepeaterWatchTonePlayer()
  @State private var lastLinkStates: [String: FocusLinkState] = [:]
  @State private var hapticTrigger = 0
  @State private var hapticIsPositive = false

  /// The one-bit-per-target answer, derived from the engine's focus state and the clock.
  enum FocusLinkState: Equatable {
    /// A reply (both legs) within the last two probe intervals.
    case heardBothWays
    /// Downlink evidence only: we hear them, no reply to our probes yet.
    case downlinkOnly
    /// Three consecutive probes lost — out of their earshot.
    case lost
    /// Nothing recent in either direction.
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

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      HStack(spacing: 8) {
        ForEach(session.focusTargets, id: \.id) { target in
          block(for: target, now: context.date)
        }
      }
      .padding(.horizontal, 12)
      .padding(.top, 8)
      .padding(.bottom, 12)
      .onChange(of: linkStates(now: context.date)) { _, newStates in
        playEdges(newStates)
      }
      .sensoryFeedback(hapticIsPositive ? .success : .warning, trigger: hapticTrigger)
    }
    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
  }

  // MARK: - One block

  private func block(for target: MapperProbeTarget, now: Date) -> some View {
    let state = linkState(for: target.id, now: now)
    let focus = focusState(for: target.id)
    let name = session.focusMeta[target.id]?.name ?? target.id.hex

    return VStack(spacing: 2) {
      Text(name)
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .foregroundStyle(.primary)

      Text(uplinkText(for: focus))
        .font(.system(.largeTitle, design: .rounded, weight: .bold))
        .monospacedDigit()
        .lineLimit(1)
        .foregroundStyle(.primary)
        .contentTransition(.numericText())

      Text(secondaryText(for: target.id, focus: focus, now: now))
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
          // The state bar: readable at arm's length without relying on text contrast.
          Capsule()
            .fill(state.color)
            .frame(height: 6)
            .padding(.horizontal, 14)
            .padding(.top, 4)
        }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel(name: name, state: state, focus: focus))
  }

  /// The big number is the uplink — "how well do they hear me" is the ride's question.
  private func uplinkText(for focus: SignalMapperProbeEngine.FocusTargetState?) -> String {
    if let txSnr = focus?.lastTxSnr {
      return String(format: "▲%.0f", txSnr)
    }
    return "▲–"
  }

  private func secondaryText(
    for id: NodeHexID,
    focus: SignalMapperProbeEngine.FocusTargetState?,
    now: Date
  ) -> String {
    var parts: [String] = []
    if let rxSnr = focus?.lastRxSnr {
      parts.append(String(format: "▼%.0f", rxSnr))
    }
    if let heard = focus?.lastHeardAt {
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
    focus: SignalMapperProbeEngine.FocusTargetState?
  ) -> String {
    var label = "\(name), \(state.localizedLabel)"
    if let txSnr = focus?.lastTxSnr {
      label += ", " + L10n.Tools.Tools.SignalMapper.Focus.uplinkAccessibility(Int(txSnr.rounded()))
    }
    return label
  }

  // MARK: - State machine

  private func focusState(for id: NodeHexID) -> SignalMapperProbeEngine.FocusTargetState? {
    session.liveSnapshot?.focusStates.first { $0.id == id }
  }

  private func linkState(for id: NodeHexID, now: Date) -> FocusLinkState {
    guard session.isRadioConnected, let focus = focusState(for: id) else { return .unknown }
    if focus.lossStreak >= 3 { return .lost }
    // The interval is captured once at session start — never a per-render
    // `UserDefaults` read (review S3: 22 keys per call at 1 Hz, for hours).
    let interval = session.focusProbeInterval
    if let reply = focus.lastReplyAt, now.timeIntervalSince(reply) <= max(interval * 2, 45) {
      return .heardBothWays
    }
    if let heard = focus.lastHeardAt, now.timeIntervalSince(heard) <= 60 {
      return .downlinkOnly
    }
    return .unknown
  }

  private func linkStates(now: Date) -> [String: FocusLinkState] {
    var states: [String: FocusLinkState] = [:]
    for target in session.focusTargets {
      states[target.id.hex] = linkState(for: target.id, now: now)
    }
    return states
  }

  /// Edge-triggered audio: entering `.lost` from anything better plays a tock, regaining
  /// a two-way link from `.lost` plays a note. Nothing else makes a sound.
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
    guard let meta = session.focusMeta[id],
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

/// The unlocked state's bottom row: a quiet dashed outline inviting lock-on, not a
/// prominent filled button blocking the map (review S2 — hierarchy).
struct SignalMapperLockOnHint: View {
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      Label(L10n.Tools.Tools.SignalMapper.Ride.lockOn, systemImage: "scope")
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .background {
      RoundedRectangle(cornerRadius: 14)
        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        .foregroundStyle(.tertiary)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
    }
    .padding(.horizontal, 16)
    .padding(.top, 8)
    .padding(.bottom, 12)
    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
  }
}
