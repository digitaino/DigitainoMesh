// MC1/Views/Chats/Components/MessagePathContent.swift
import CoreLocation
import MC1Services
import SwiftUI

/// Inline content for message path visualization, extracted from MessagePathSheet.
/// Shows sender, intermediate hops and receiver. The raw path hex and its copy
/// control live in the host screen's header row, beside Reply with Route, so
/// the hop rows stay a single uninterrupted list.
struct MessagePathContent: View {
  let message: MessageDTO
  let viewModel: MessagePathViewModel
  let receiverName: String
  let userLocation: CLLocation?

  var body: some View {
    if viewModel.isLoading {
      ProgressView()
        .frame(maxWidth: .infinity, alignment: .center)
        .padding()
    } else if message.pathNodes == nil {
      ContentUnavailableView(
        L10n.Chats.Chats.Path.Unavailable.title,
        systemImage: "point.topleft.down.to.point.bottomright.curvepath",
        description: Text(L10n.Chats.Chats.Path.Unavailable.description)
      )
    } else {
      let senderResolution = viewModel.senderResolution(for: message)
      let pathHops = message.pathHops

      // Sender
      PathHopRowView(
        hopType: .sender,
        nodeName: senderResolution.displayName,
        nodeID: viewModel.senderNodeID(for: message),
        snr: nil,
        matchKind: senderResolution.matchKind
      )

      // Intermediate hops
      ForEach(Array(pathHops.enumerated()), id: \.offset) { index, hop in
        let repeaterResolution = viewModel.repeaterResolution(
          for: hop.data,
          userLocation: userLocation
        )
        PathHopRowView(
          hopType: .intermediate(index + 1),
          nodeName: repeaterResolution.displayName,
          nodeID: hop.hex,
          snr: nil,
          matchKind: repeaterResolution.matchKind
        )
      }

      // Receiver
      PathHopRowView(
        hopType: .receiver,
        nodeName: receiverName,
        nodeID: nil,
        snr: message.snr
      )
    }
  }
}
