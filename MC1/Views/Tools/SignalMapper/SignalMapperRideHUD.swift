import CoreLocation
import MC1Services
import SwiftUI

/// The ride-mode heads-up display: one big colored block per locked-on repeater, and the
/// session's vitals behind a tap.
///
/// Built for a bar mount in sunlight at 25 km/h (docs/ACTIVE_SURVEY_M3_5.md §2.7, review
/// 4a): the question while riding is "am I still heard?", which is one bit per target —
/// so the primary readout is a large opaque state block, not numbers in glass. Everything
/// quantitative collapses behind a tap for red lights.
///
/// Audio is primary feedback (review 4b): a bar-mounted phone transmits no haptic worth
/// having, so a lost target plays a tock and a regained one a note, through the same
/// `.playback`+`.mixWithOthers` session the repeater watch screen proved — audible in
/// earbuds over music with the mute switch on. Tones are edge-triggered only; a tone per
/// reply at probe cadence would be unbearable.
struct SignalMapperRideHUD: View {
  let session: SignalMapperRideSession
  let onSpotCheck: () -> Void
  let onLockOn: () -> Void

  @Environment(\.appState) private var appState
  @State private var isExpanded = false
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
  }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      VStack(spacing: 8) {
        if !session.isRadioConnected {
          disconnectedBanner
        }

        if session.focusTargets.isEmpty {
          lockOnPrompt
        } else {
          focusBlocks(now: context.date)
        }

        if isExpanded {
          detailGrid
        }

        actionRow
      }
      .padding(12)
      .background(.thinMaterial, in: .rect(cornerRadius: 16))
      .frame(maxWidth: 520)
      .contentShape(.rect)
      .onTapGesture { withAnimation(.snappy) { isExpanded.toggle() } }
      .onChange(of: linkStates(now: context.date)) { _, newStates in
        playEdges(newStates)
      }
      .sensoryFeedback(hapticIsPositive ? .success : .warning, trigger: hapticTrigger)
    }
    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
  }

  // MARK: - Focus blocks

  private func focusBlocks(now: Date) -> some View {
    HStack(spacing: 8) {
      ForEach(session.focusTargets, id: \.id) { target in
        let state = linkState(for: target.id, now: now)
        let focus = focusState(for: target.id)
        VStack(spacing: 2) {
          Text(session.focusMeta[target.id]?.name ?? target.id.hex)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.6)

          Text(uplinkText(for: focus))
            .font(.system(size: 34, weight: .bold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)

          Text(secondaryText(for: target.id, focus: focus, now: now))
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .opacity(0.9)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .foregroundStyle(.white)
        .background(state.color, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
      }
    }
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

  // MARK: - Detail

  private var detailGrid: some View {
    let totals = session.displayTotals
    return VStack(alignment: .leading, spacing: 4) {
      detailRow(
        L10n.Tools.Tools.SignalMapper.Ride.probes,
        "\(totals.probesSent)·\(totals.traceRepliesHeard + totals.discoverResponsesHeard)·\(totals.probesLost)"
      )
      detailRow(L10n.Tools.Tools.SignalMapper.Ride.cells, "\(totals.cellsProbed)")
      detailRow(
        L10n.Tools.Tools.SignalMapper.Ride.noFixDrops,
        "\(totals.skippedNoFixCount)"
      )
      ForEach(session.focusTargets, id: \.id) { target in
        if let maxRange = session.maxReplyDistanceMeters[target.id] {
          detailRow(
            L10n.Tools.Tools.SignalMapper.Ride.maxRange(
              session.focusMeta[target.id]?.name ?? target.id.hex
            ),
            distanceText(maxRange)
          )
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func detailRow(_ label: String, _ value: String) -> some View {
    HStack {
      Text(label)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .monospacedDigit()
    }
    .font(.footnote)
  }

  // MARK: - Chrome

  private var disconnectedBanner: some View {
    Label(
      L10n.Tools.Tools.SignalMapper.Ride.radioDisconnected,
      systemImage: "antenna.radiowaves.left.and.right.slash"
    )
    .font(.subheadline.weight(.semibold))
    .foregroundStyle(.white)
    .frame(maxWidth: .infinity)
    .padding(.vertical, 8)
    .background(.red, in: .rect(cornerRadius: 10))
  }

  private var lockOnPrompt: some View {
    Button(action: onLockOn) {
      Label(
        L10n.Tools.Tools.SignalMapper.Ride.lockOn,
        systemImage: "scope"
      )
      .font(.subheadline.weight(.semibold))
      .frame(maxWidth: .infinity)
      .padding(.vertical, 10)
    }
    .buttonStyle(.borderedProminent)
  }

  private var actionRow: some View {
    HStack(spacing: 8) {
      Button(action: onSpotCheck) {
        Label(
          L10n.Tools.Tools.SignalMapper.Survey.spotCheck,
          systemImage: "scope"
        )
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
      }
      .buttonStyle(.bordered)

      if !session.focusTargets.isEmpty {
        Button(action: onLockOn) {
          Image(systemName: "person.crop.circle.badge.plus")
            .font(.subheadline.weight(.semibold))
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(L10n.Tools.Tools.SignalMapper.Ride.lockOn)
      }
    }
  }

  // MARK: - State machine

  private func focusState(for id: NodeHexID) -> SignalMapperProbeEngine.FocusTargetState? {
    session.liveSnapshot?.focusStates.first { $0.id == id }
  }

  private func linkState(for id: NodeHexID, now: Date) -> FocusLinkState {
    guard session.isRadioConnected, let focus = focusState(for: id) else { return .unknown }
    if focus.lossStreak >= 3 { return .lost }
    let interval = max(4, MapperTuningStore().tuning.focusProbeIntervalSeconds)
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
    let there = CLLocation(latitude: latitude, longitude: longitude)
    return here.distance(from: there)
  }

  private func distanceText(_ meters: Double) -> String {
    meters >= 1000
      ? String(format: "%.1f km", meters / 1000)
      : String(format: "%.0f m", meters)
  }
}
