import CoreLocation
import MC1Services
import SwiftUI

struct ActionsDetailsSection: View {
  @Environment(\.appState) private var appState

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

  @State private var showPathDetail = false
  @State private var showRepeatsMap = false
  @State private var showPacketScope = false
  /// Route text picked on `MessagePathDetailView`, dispatched from the sheet's
  /// `onDismiss`. The dispatch also dismisses the actions sheet, and dismissing the
  /// parent while the child is still presented can strand the actions sheet open —
  /// same deferral as `ActionsEmojiSection`.
  @State private var pendingRouteInfo: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if availability.canViewPath {
        viewPathButton
      }

      if availability.canViewPacketScope {
        networkViewButton
      }

      if availability.canShowRepeatDetails {
        ActionsExpandableDetailRow(
          isDetailExpanded: $isDetailExpanded,
          repeats: repeats,
          contacts: contacts,
          discoveredNodes: discoveredNodes,
          // The stamp-first reference the repeats map resolves against, so an
          // ambiguous repeater isn't named one thing here and another there.
          userLocation: MessagePathMapView.receiverReference(
            for: .message(message),
            userLocation: appState.bestAvailableLocation
          ),
          onViewMap: { showRepeatsMap = true }
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
    // A cover, not a sheet: the path screen is a full-bleed map, and a sheet's
    // swipe-down would fight every downward pan on it. It closes with Done.
    .fullScreenCover(isPresented: $showPathDetail, onDismiss: {
      if let routeInfo = pendingRouteInfo {
        pendingRouteInfo = nil
        onSelectAction?(.replyWithRoute(routeInfo))
      }
    }) {
      MessagePathDetailView(
        message: message,
        pathViewModel: pathViewModel,
        onReplyWithRoute: onSelectAction == nil ? nil : { routeInfo in
          pendingRouteInfo = routeInfo
          showPathDetail = false
        }
      )
    }
    // Same cover treatment as the path screen, and no onDismiss dispatch:
    // the repeats map takes no action back to the sheet.
    .fullScreenCover(isPresented: $showRepeatsMap) {
      HeardRepeatsMapView(
        message: message,
        repeats: repeats ?? [],
        pathViewModel: pathViewModel
      )
    }
    // A sheet, not a cover: this is a scrolling list with no map underneath,
    // so the standard swipe-down dismissal is the right affordance.
    .sheet(isPresented: $showPacketScope) {
      PacketScopeDetailView(
        message: message,
        pathViewModel: pathViewModel,
        // Same stamp-first reference the repeats map resolves against, so a
        // repeater is not named one thing there and another here.
        userLocation: MessagePathMapView.receiverReference(
          for: .message(message),
          userLocation: appState.bestAvailableLocation
        )
      )
    }
  }

  /// Entry to the observer network's view of this packet — the opt-in CoreScope
  /// lookup. The fetch happens on the presented screen, never from rendering
  /// this row: the sheet opening is the user-initiated moment the privacy
  /// contract keys on.
  private var networkViewButton: some View {
    Button {
      showPacketScope = true
    } label: {
      HStack {
        Label(
          L10n.Chats.Chats.Message.Action.networkView,
          systemImage: "dot.radiowaves.up.forward"
        )
        Spacer()
        Image(systemName: "chevron.right")
          .foregroundStyle(.secondary)
          .font(.caption)
          .accessibilityHidden(true)
      }
      .padding()
      .contentShape(.rect)
    }
    .foregroundStyle(.primary)
  }

  /// The one entry point to the path: map, hop list and Reply with Route live
  /// together on `MessagePathDetailView`, not as three sibling rows here.
  private var viewPathButton: some View {
    Button {
      showPathDetail = true
    } label: {
      HStack {
        Label(
          L10n.Chats.Chats.Message.Action.viewPath,
          systemImage: "point.topleft.down.to.point.bottomright.curvepath"
        )
        Spacer()
        Image(systemName: "chevron.right")
          .foregroundStyle(.secondary)
          .font(.caption)
          .accessibilityHidden(true)
      }
      .padding()
      .contentShape(.rect)
    }
    .foregroundStyle(.primary)
  }
}

/// The Repeat Details disclosure for an outgoing message that was heard again.
/// Repeats are a handful of metadata rows, not a destination — they expand in
/// place rather than earning a screen the way the path does.
private struct ActionsExpandableDetailRow: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @Binding var isDetailExpanded: Bool
  let repeats: [MessageRepeatDTO]?
  let contacts: [ContactDTO]
  let discoveredNodes: [DiscoveredNodeDTO]
  /// Reference for name disambiguation in the rows — the host passes the
  /// stamp-first reference shared with the heard-repeats map.
  let userLocation: CLLocation?
  /// Opens the heard-repeats map. Rendered as the first row of the expanded
  /// content — the map is a destination the way the path screen is, but it
  /// stays subordinate to the disclosure so collapsed state costs no height.
  var onViewMap: (() -> Void)?

  var body: some View {
    VStack(spacing: 0) {
      Button {
        withAnimation(reduceMotion ? nil : .default) {
          isDetailExpanded.toggle()
        }
      } label: {
        HStack {
          Label(
            L10n.Chats.Chats.Message.Action.repeatDetails,
            systemImage: "arrow.triangle.branch"
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
        if let onViewMap, repeats?.isEmpty == false {
          Button(action: onViewMap) {
            HStack {
              Label(L10n.Chats.Chats.Repeats.viewOnMap, systemImage: "map")
              Spacer()
              Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
                .font(.caption)
                .accessibilityHidden(true)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .contentShape(.rect)
          }
          .foregroundStyle(.primary)
        }
        RepeatDetailsContent(
          repeats: repeats,
          contacts: contacts,
          discoveredNodes: discoveredNodes,
          userLocation: userLocation
        )
        .padding(.horizontal)
        .padding(.bottom)
        .id("expandedContent")
      }
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
      let regionText: String = {
        switch RegionScopeSemantics.coalesce(
          scope: message.regionScope,
          matches: message.regionScopeMatches
        ) {
        case .none:
          return L10n.Chats.Chats.Message.Info.regionUnresolved
        case let .unique(name):
          return L10n.Chats.Chats.Message.Info.floodedUnder(name)
        case let .ambiguous(names):
          let list = ListFormatter.localizedString(byJoining: names)
          return L10n.Chats.Chats.Message.Info.regionAmbiguous(list)
        }
      }()
      ActionInfoRow(text: regionText, icon: "globe")
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
