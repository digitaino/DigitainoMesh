import CoreLocation
import MC1Services
import SwiftUI

/// The live half of the ride HUD: one line per repeater, above the cell card.
///
/// It was three tall tiles with a lone "▲–" in them until the third field test called it
/// "a huge card with a triangle and wasted space" — correctly. The card below holds the
/// *stored* picture of the hexagon; these rows hold what is happening this second, and a
/// range test needs exactly one line each: who, both legs, how long ago, how far.
///
/// Unlocked it shows whoever answered most recently. That matters because the card is
/// built from the store — flushed every 30 s, rebuilt every 20 s — so on a hexagon the
/// rider has just entered there is nothing to draw yet, and these rows are the only thing
/// on screen saying the ride is working.
///
/// Tones and haptics stay: entering `.lost`, regaining a two-way link, and losing the
/// radio itself are the events a rider cannot watch the screen for.
struct SignalMapperFocusBlocks: View {
  let session: SignalMapperRideSession
  /// Whether the cell card is on screen underneath. Only decides whether the quiet
  /// "listening…" placeholder is worth its line.
  var hasCellCard = false
  let onLockOn: () -> Void

  @Environment(\.appState) private var appState
  @State private var tonePlayer = RepeaterWatchTonePlayer()
  @State private var lastLinkStates: [String: FocusLinkState] = [:]
  @State private var hapticTrigger = 0
  @State private var hapticIsPositive = false
  @State private var wasRadioConnected = true

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

  /// Who is answering right now, straight off the engine's live snapshot. Two rows: the
  /// live half must never cost the map more than it is worth.
  private var heardStates: [SignalMapperProbeEngine.FocusTargetState] {
    Array((session.liveSnapshot?.heardStates ?? []).prefix(2))
  }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      VStack(alignment: .leading, spacing: 3) {
        caption
        if isLockedOn {
          ForEach(session.focusTargets, id: \.id) { target in
            row(
              id: target.id,
              state: focusLinkState(for: target.id, now: context.date),
              activity: activity(for: target.id),
              now: context.date
            )
          }
        } else if !heardStates.isEmpty {
          ForEach(heardStates) { activity in
            row(
              id: activity.id,
              state: recencyState(for: activity, now: context.date),
              activity: activity,
              now: context.date
            )
          }
        } else if !hasCellCard {
          listeningRow
        }
      }
      .padding(.horizontal, 14)
      .padding(.top, 4)
      .padding(.bottom, 8)
      .background(Color(.secondarySystemBackground).opacity(0.96), in: .rect(cornerRadius: 16))
      .padding(.horizontal, 12)
      .padding(.top, 8)
      .onChange(of: focusLinkStates(now: context.date)) { _, newStates in
        playEdges(newStates)
      }
      .sensoryFeedback(hapticIsPositive ? .success : .warning, trigger: hapticTrigger)
    }
    .onChange(of: session.isRadioConnected) { _, connected in
      // The radio dropping is what makes a whole ride worthless, and the only other cue
      // for it is a glyph on a strip the rider is not looking at.
      defer { wasRadioConnected = connected }
      guard wasRadioConnected, !connected else { return }
      tonePlayer.play(.tock)
      hapticIsPositive = false
      hapticTrigger += 1
    }
    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
  }

  private var caption: some View {
    HStack {
      Text(
        isLockedOn
          ? L10n.Tools.Tools.SignalMapper.Ride.lockedOn
          : L10n.Tools.Tools.SignalMapper.Ride.hearingNow
      )
      .font(.caption2.weight(.semibold))
      .foregroundStyle(.secondary)
      .textCase(.uppercase)

      Spacer()

      Button(action: onLockOn) {
        Label(
          isLockedOn
            ? L10n.Localizable.Common.edit
            : L10n.Tools.Tools.SignalMapper.Focus.apply,
          systemImage: "scope"
        )
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.tint)
    }
  }

  /// Nothing has answered yet and there is no card underneath: say so rather than
  /// leaving the bottom of the screen blank.
  private var listeningRow: some View {
    HStack(spacing: 6) {
      Image(systemName: "ear.badge.waveform")
        .font(.caption2)
        .foregroundStyle(.secondary)
      Text(L10n.Tools.Tools.SignalMapper.Ride.listening)
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
    }
    .padding(.bottom, 4)
    .accessibilityElement(children: .combine)
  }

  // MARK: - One row

  private func row(
    id: NodeHexID,
    state: FocusLinkState,
    activity: SignalMapperProbeEngine.FocusTargetState?,
    now: Date
  ) -> some View {
    let name = session.meta(for: id)?.name ?? id.hex
    let hasReading = activity?.lastTxSnr != nil || activity?.lastRxSnr != nil

    return HStack(spacing: 7) {
      Circle()
        .fill(state.color)
        .frame(width: 7, height: 7)

      Text(name)
        .font(.caption.weight(.medium))
        .lineLimit(1)

      Spacer(minLength: 4)

      if hasReading {
        Text(uplinkText(for: activity))
          .font(.system(.subheadline, design: .rounded, weight: .bold))
          .monospacedDigit()
          .foregroundStyle(activity?.lastTxSnr == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
          .contentTransition(.numericText())

        Text(downlinkText(for: activity))
          .font(.system(.subheadline, design: .rounded, weight: .semibold))
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .contentTransition(.numericText())
      } else {
        // No reading yet is a sentence, not a pair of dashes after a triangle.
        Text(L10n.Tools.Tools.SignalMapper.Ride.noReplyYet)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      let trailing = trailingText(for: id, activity: activity, now: now)
      if !trailing.isEmpty {
        Text(trailing)
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel(name: name, state: state, activity: activity, now: now, id: id))
  }

  /// The loud half of the row is the uplink — "how well do they hear me" is the ride's
  /// question.
  private func uplinkText(for activity: SignalMapperProbeEngine.FocusTargetState?) -> String {
    guard let txSnr = activity?.lastTxSnr else { return "▲–" }
    return "▲" + Self.decibels(txSnr)
  }

  private func downlinkText(for activity: SignalMapperProbeEngine.FocusTargetState?) -> String {
    guard let rxSnr = activity?.lastRxSnr else { return "▼–" }
    return "▼" + Self.decibels(rxSnr)
  }

  private func trailingText(
    for id: NodeHexID,
    activity: SignalMapperProbeEngine.FocusTargetState?,
    now: Date
  ) -> String {
    var parts: [String] = []
    if let heard = activity?.lastHeardAt {
      parts.append(L10n.Tools.Tools.SignalMapper.Ride.age(Int(now.timeIntervalSince(heard))))
    }
    if let distance = currentDistanceMeters(to: id) {
      parts.append(distanceText(distance))
    }
    return parts.joined(separator: " ")
  }

  private func accessibilityLabel(
    name: String,
    state: FocusLinkState,
    activity: SignalMapperProbeEngine.FocusTargetState?,
    now: Date,
    id: NodeHexID
  ) -> String {
    var label = "\(name), \(state.localizedLabel)"
    if let txSnr = activity?.lastTxSnr {
      label += ", " + L10n.Tools.Tools.SignalMapper.Focus.uplinkAccessibility(Int(txSnr.rounded()))
    }
    if let rxSnr = activity?.lastRxSnr {
      label += ", " + L10n.Tools.Tools.SignalMapper.Card.downlinkAccessibility(Int(rxSnr.rounded()))
    }
    // Distance is the point of a range test; it cannot be sighted-only.
    if let distance = currentDistanceMeters(to: id) {
      label += ", " + distanceText(distance)
    }
    return label
  }

  // MARK: - State machine

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

  /// Auto rows aren't probed on a cadence, so their state is recency alone: replied in
  /// the last 30 s → green; heard within 90 s → amber; older → grey.
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

  /// Edge-triggered audio for locked-on targets: entering `.lost` plays a tock, regaining
  /// a two-way link plays a note. A negative edge wins the tick, so two targets flipping
  /// opposite ways in the same second cannot report the bad news as good.
  private func playEdges(_ newStates: [String: FocusLinkState]) {
    defer { lastLinkStates = newStates }
    var lostAny = false
    var regainedAny = false
    for (id, state) in newStates {
      guard let previous = lastLinkStates[id], previous != state else { continue }
      if state == .lost, previous != .unknown {
        lostAny = true
      } else if state == .heardBothWays, previous == .lost {
        regainedAny = true
      }
    }
    guard lostAny || regainedAny else { return }
    tonePlayer.play(lostAny ? .tock : .note)
    hapticIsPositive = !lostAny
    hapticTrigger += 1
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
      ? String(format: "%.1fkm", meters / 1000)
      : String(format: "%.0fm", meters)
  }

  /// Rounded decibels without the `-0` that `%.0f` produces for anything in (−0.5, 0).
  private static func decibels(_ value: Double) -> String {
    let rounded = value.rounded()
    return String(format: "%.0f", rounded == 0 ? 0 : rounded)
  }
}
