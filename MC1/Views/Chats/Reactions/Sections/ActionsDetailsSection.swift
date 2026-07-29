import MC1Services
import SwiftUI

struct ActionsDetailsSection: View {
  let message: MessageDTO
  let availability: MessageActionAvailability
  @Binding var isDetailExpanded: Bool
  let repeats: [MessageRepeatDTO]?
  let contacts: [ContactDTO]
  let discoveredNodes: [DiscoveredNodeDTO]
  let pathViewModel: MessagePathViewModel
  /// Routes Reply with Route through the sheet's `performAction`, so the sheet
  /// dismisses like any other action row. Defaulted for previews.
  var onSelectAction: ((MessageAction) -> Void)?

  @Environment(\.appState) private var appState
  @State private var showPathMap = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if availability.canViewPath {
        pathMapButton
        if let onSelectAction, let routeInfo = routeInfoText {
          replyWithRouteButton(routeInfo: routeInfo, onSelectAction: onSelectAction)
        }
      }

      if availability.canShowRepeatDetails || availability.canViewPath {
        ActionsExpandableDetailRow(
          message: message,
          availability: availability,
          isDetailExpanded: $isDetailExpanded,
          repeats: repeats,
          contacts: contacts,
          discoveredNodes: discoveredNodes,
          pathViewModel: pathViewModel
        )
      }

      Text(L10n.Chats.Chats.Message.Action.details)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 4)

      if message.isOutgoing {
        ActionsOutgoingDetailsRows(message: message)
      } else {
        ActionsIncomingDetailsRows(message: message)
      }
    }
    .sheet(isPresented: $showPathMap) {
      MessagePathMapView(source: .message(message), pathViewModel: pathViewModel)
    }
  }

  private var pathMapButton: some View {
    Button {
      showPathMap = true
    } label: {
      HStack {
        Label(L10n.Chats.Chats.Path.map, systemImage: "map")
        Spacer()
      }
      .padding()
      .contentShape(.rect)
    }
    .foregroundStyle(.primary)
  }

  private func replyWithRouteButton(
    routeInfo: String,
    onSelectAction: @escaping (MessageAction) -> Void
  ) -> some View {
    Button {
      onSelectAction(.replyWithRoute(routeInfo))
    } label: {
      HStack {
        Label(L10n.Chats.Chats.Path.replyWithRoute, systemImage: "arrowshape.turn.up.left")
        Spacer()
      }
      .padding()
      .contentShape(.rect)
    }
    .foregroundStyle(.primary)
  }

  /// The "RX via ..." line a route reply carries. Deliberately not localized:
  /// it is a wire format other clients parse back into a shared-route card
  /// (`SharedRouteParser`), so the shape must stay stable across locales.
  private var routeInfoText: String? {
    let hopCount = message.hopCount
    guard hopCount > 0 else { return nil }
    let pathHex = message.pathNodesHex.joined(separator: ",")
    guard !pathHex.isEmpty else { return nil }
    let hopWord = hopCount == 1 ? "hop" : "hops"
    let distancePart = routeDistanceText.map { " \($0)" } ?? ""
    return "RX via \(pathHex). \(hopCount) \(hopWord)\(distancePart)"
  }

  /// Distance over the same nodes the path map plots, so the shared figure
  /// matches the pill the recipient would see. Prefixed "≥" when some hops
  /// could not be located — the drawn path is then a lower bound.
  private var routeDistanceText: String? {
    let nodes = MessagePathMapView.locatedNodes(
      for: .message(message),
      contacts: pathViewModel.contacts,
      repeaters: pathViewModel.repeaters,
      discoveredRepeaters: pathViewModel.discoveredRepeaters,
      userLocation: appState.bestAvailableLocation,
      receiverName: appState.connectedDevice?.nodeName
    )
    guard let distance = nodes.map(\.coordinate).totalDistance() else { return nil }
    let formatted = Measurement(value: distance, unit: UnitLength.meters)
      .formatted(.measurement(width: .abbreviated, usage: .road))
    let locatedHops = nodes.count(where: { $0.point.pinStyle == .repeaterHop })
    return locatedHops < message.hopCount ? "≥ \(formatted)" : formatted
  }
}

private struct ActionsExpandableDetailRow: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let message: MessageDTO
  let availability: MessageActionAvailability
  @Binding var isDetailExpanded: Bool
  let repeats: [MessageRepeatDTO]?
  let contacts: [ContactDTO]
  let discoveredNodes: [DiscoveredNodeDTO]
  let pathViewModel: MessagePathViewModel

  var body: some View {
    VStack(spacing: 0) {
      Button {
        withAnimation(reduceMotion ? nil : .default) {
          isDetailExpanded.toggle()
        }
      } label: {
        HStack {
          Label(
            availability.canShowRepeatDetails
              ? L10n.Chats.Chats.Message.Action.repeatDetails
              : L10n.Chats.Chats.Message.Action.viewPath,
            systemImage: availability.canShowRepeatDetails
              ? "arrow.triangle.branch"
              : "point.topleft.down.to.point.bottomright.curvepath"
          )
          Spacer()
          Image(systemName: "chevron.right")
            .rotationEffect(.degrees(isDetailExpanded ? 90 : 0))
            .foregroundStyle(.secondary)
            .font(.caption)
            .accessibilityHidden(true)
        }
        .padding()
        .contentShape(.rect)
      }
      .foregroundStyle(.primary)
      .accessibilityValue(
        isDetailExpanded
          ? L10n.Chats.Chats.Message.Action.expanded
          : L10n.Chats.Chats.Message.Action.collapsed
      )

      if isDetailExpanded {
        Divider()
          .padding(.horizontal)
        ActionsExpandedContent(
          message: message,
          availability: availability,
          repeats: repeats,
          contacts: contacts,
          discoveredNodes: discoveredNodes,
          pathViewModel: pathViewModel
        )
        .padding(.horizontal)
        .padding(.bottom)
        .id("expandedContent")
      }
    }
  }
}

private struct ActionsExpandedContent: View {
  @Environment(\.appState) private var appState

  let message: MessageDTO
  let availability: MessageActionAvailability
  let repeats: [MessageRepeatDTO]?
  let contacts: [ContactDTO]
  let discoveredNodes: [DiscoveredNodeDTO]
  let pathViewModel: MessagePathViewModel

  var body: some View {
    if availability.canShowRepeatDetails {
      RepeatDetailsContent(
        repeats: repeats,
        contacts: contacts,
        discoveredNodes: discoveredNodes,
        userLocation: appState.bestAvailableLocation
      )
    } else if availability.canViewPath {
      MessagePathContent(
        message: message,
        viewModel: pathViewModel,
        receiverName: appState.connectedDevice?.nodeName ?? L10n.Chats.Chats.Path.Receiver.you,
        userLocation: appState.bestAvailableLocation
      )
    }
  }
}

private struct ActionsOutgoingDetailsRows: View {
  let message: MessageDTO

  var body: some View {
    ActionInfoRow(text: L10n.Chats.Chats.Message.Info.sent(
      message.senderDate.formatted(date: .abbreviated, time: .standard)
    ))

    if let rtt = message.roundTripTime {
      ActionInfoRow(text: L10n.Chats.Chats.Message.Info.roundTrip(Int(rtt)))
    }

    if message.heardRepeats > 0 {
      let word = message.heardRepeats == 1
        ? L10n.Chats.Chats.Message.Repeat.singular
        : L10n.Chats.Chats.Message.Repeat.plural
      ActionInfoRow(text: L10n.Chats.Chats.Message.Info.heardRepeats(message.heardRepeats, word))
    }
  }
}

private struct ActionsIncomingDetailsRows: View {
  let message: MessageDTO

  var body: some View {
    ActionInfoRow(
      text: L10n.Chats.Chats.Message.Info.hops(hopCountFormatted(message)),
      icon: "arrowshape.bounce.right"
    )

    if let hashSize = message.pathHashSizeIfKnown {
      ActionInfoRow(text: L10n.Chats.Chats.Message.Info.pathHash(hashSize))
    }

    if message.routeType == .tcFlood {
      ActionInfoRow(
        text: message.regionScope.map { L10n.Chats.Chats.Message.Info.floodedUnder($0) }
          ?? L10n.Chats.Chats.Message.Info.regionUnresolved,
        icon: "globe"
      )
    }

    let sentText = L10n.Chats.Chats.Message.Info.sent(
      message.senderDate.formatted(date: .abbreviated, time: .standard)
    )
    let adjusted = message.timestampCorrected ? " " + L10n.Chats.Chats.Message.Info.adjusted : ""
    ActionInfoRow(text: sentText + adjusted)

    if message.timestampCorrected {
      ActionInfoRow(text: L10n.Chats.Chats.Message.Info.originalSendTime(
        message.wireSentDate.formatted(date: .abbreviated, time: .standard)
      ))
    }

    ActionInfoRow(text: L10n.Chats.Chats.Message.Info.received(
      message.createdAt.formatted(date: .abbreviated, time: .standard)
    ))

    if let snr = message.snr {
      ActionInfoRow(text: L10n.Chats.Chats.Message.Info.snr(snrFormatted(snr)))
    }
  }

  private func snrFormatted(_ snr: Double) -> String {
    let quality = SNRQuality(snr: snr).localizedLabel
    return "\(snr.formatted(.number.precision(.fractionLength(1)))) dB (\(quality))"
  }

  private func hopCountFormatted(_ message: MessageDTO) -> String {
    if message.isDirectRouted {
      return L10n.Chats.Chats.Message.Hops.direct
    }
    return "\(message.hopCount)"
  }
}
