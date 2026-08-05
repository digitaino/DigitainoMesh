import CoreLocation
import MC1Services
import SwiftUI

/// Everything about how a message reached this device, in one place: the route
/// drawn on a full-bleed map, the hop-by-hop list in a panel floating over it,
/// and Reply with Route in that panel's header — sharing a route is something
/// you do after seeing it, so the action lives where the route is shown, not
/// beside its entry point in the actions sheet.
///
/// Presented as a cover rather than a sheet (see `ActionsDetailsSection`): this
/// is a screen, not a card, and a downward drag over a map should pan the map
/// rather than throw the route away.
struct MessagePathDetailView: View {
  /// The hop panel's ceiling as a share of the screen. A short path sizes the
  /// panel to its own rows and leaves everything else to the map; a long one
  /// scrolls inside the panel instead of crowding the map out.
  private static let panelMaxHeightFraction: CGFloat = 0.45
  private static let panelCornerRadius: CGFloat = 20
  private static let panelMargin: CGFloat = 12

  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss

  let message: MessageDTO
  let pathViewModel: MessagePathViewModel
  /// Hands the composed route text back to the presenter, which dismisses this
  /// screen and dispatches the reply from its `onDismiss` — the dispatch also
  /// dismisses the actions sheet, and tearing down the parent under a
  /// still-presented child can strand it open. `nil` hides the button (previews).
  var onReplyWithRoute: ((String) -> Void)?

  @State private var locatedNodes: [(point: MapPoint, coordinate: CLLocationCoordinate2D)] = []
  /// Measured content height of the hop list, so the panel can size itself to
  /// the rows it actually has instead of claiming a fixed slab of the screen.
  @State private var hopListHeight: CGFloat = 0
  /// Measured panel height, handed to the map so a camera fit frames the path
  /// in the space left above the panel rather than behind it.
  @State private var panelHeight: CGFloat = 0
  @State private var copyHapticTrigger = 0

  var body: some View {
    NavigationStack {
      content
        .navigationTitle(L10n.Chats.Chats.Path.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          if !locatedNodes.isEmpty {
            ToolbarItem(placement: .principal) {
              PathDistanceBanner(
                hopCount: message.pathHops.count,
                totalPathDistance: locatedNodes.map(\.coordinate).totalDistance()
              )
            }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button(L10n.Localizable.Common.done) { dismiss() }
          }
        }
        .sensoryFeedback(.success, trigger: copyHapticTrigger)
        .onAppear {
          // A stamped message pins the receiver from its own recorded fix and
          // needs no GPS. Only the unstamped fallback pin is as honest as the
          // phone fix behind it — and the cached one can predate a suspend —
          // so ask for a live fix then; the sample onChange below moves the
          // pin when it lands.
          if message.userFixCoordinate == nil {
            appState.requestPhoneFixIfStale()
          }
          locatedNodes = buildLocatedNodes()
        }
        // The actions sheet preloads the view model, but a fast tap can land
        // here with the contacts fetch still in flight — rebuild when it lands
        // so the map doesn't stay empty forever.
        .onChange(of: pathViewModel.isLoading) { _, isLoading in
          guard !isLoading else { return }
          locatedNodes = buildLocatedNodes()
        }
        // A fresh fix landed: the unstamped fallback pin and the hop-list
        // disambiguation are built from it, so rebuild. A stamped message is
        // anchored to its recorded fix — rebuilding would only churn the map's
        // point source for identical pins.
        .onChange(of: locationSample) { _, _ in
          guard message.userFixCoordinate == nil else { return }
          locatedNodes = buildLocatedNodes()
        }
    }
  }

  @ViewBuilder
  private var content: some View {
    if pathViewModel.isLoading {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if locatedNodes.isEmpty {
      // Nothing plottable is not a failure: the hop list still names what it
      // can, so it simply becomes the whole screen rather than sitting under
      // an unavailable placard.
      VStack(spacing: 0) {
        panelHeader
        Divider()
        hopList(maxHeight: nil)
      }
    } else {
      GeometryReader { proxy in
        MessagePathMapCanvas(
          locatedNodes: locatedNodes,
          cameraBottomSheetFraction: panelHeight / max(proxy.size.height, 1)
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
          floatingPanel(maxListHeight: proxy.size.height * Self.panelMaxHeightFraction)
        }
      }
    }
  }

  /// The hop list over the map: a glass card inset from the edges, matching the
  /// floating controls the app's other map screens use, rather than a slab
  /// welded to the bottom of the screen.
  private func floatingPanel(maxListHeight: CGFloat) -> some View {
    VStack(spacing: 0) {
      panelHeader
      Divider()
        .padding(.horizontal, 16)
      hopList(maxHeight: maxListHeight)
    }
    .liquidGlass(in: .rect(cornerRadius: Self.panelCornerRadius))
    .padding(.horizontal, Self.panelMargin)
    .padding(.bottom, Self.panelMargin)
    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
  }

  /// The panel's top row: the raw path bytes and their copy control on the
  /// left, Reply with Route on the right. The action reads as one control among
  /// the route's own affordances instead of a full-width bar competing with the
  /// map for the bottom of the screen.
  private var panelHeader: some View {
    HStack(spacing: 8) {
      if !message.pathHops.isEmpty {
        Button(L10n.Chats.Chats.Path.copyButton, systemImage: "doc.on.doc") {
          copyHapticTrigger += 1
          UIPasteboard.general.string = message.pathStringForClipboard
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .accessibilityLabel(L10n.Chats.Chats.Path.copyAccessibility)
        .accessibilityHint(L10n.Chats.Chats.Path.copyHint)

        Text(message.pathString)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }

      Spacer(minLength: 0)

      if let onReplyWithRoute, let routeInfo = routeInfoText {
        Button {
          onReplyWithRoute(routeInfo)
        } label: {
          Label(L10n.Chats.Chats.Path.replyWithRoute, systemImage: "arrowshape.turn.up.left")
            .font(.subheadline.weight(.medium))
        }
        .buttonStyle(.borderless)
        .layoutPriority(1)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  /// The hop rows. `maxHeight` caps the panel version at its share of the
  /// screen — below that the list is exactly as tall as its rows, which is what
  /// keeps a two-hop path from leaving half a screen of empty panel. `nil`
  /// leaves the list free to fill, for the no-map layout.
  private func hopList(maxHeight: CGFloat?) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        MessagePathContent(
          message: message,
          viewModel: pathViewModel,
          receiverName: appState.connectedDevice?.nodeName ?? L10n.Chats.Chats.Path.Receiver.you,
          userLocation: hopReferenceLocation
        )
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { hopListHeight = $0 }
    }
    .scrollBounceBehavior(.basedOnSize)
    .frame(height: maxHeight.map { min(hopListHeight, $0) })
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

  /// Distance over the same nodes the map above plots, so the shared figure
  /// matches the drawn route. Prefixed "≥" when some hops could not be
  /// located — the drawn path is then a lower bound.
  private var routeDistanceText: String? {
    guard let distance = locatedNodes.map(\.coordinate).totalDistance() else { return nil }
    let formatted = Measurement(value: distance, unit: UnitLength.meters)
      .formatted(.measurement(width: .abbreviated, usage: .road))
    let locatedHops = locatedNodes.count(where: { $0.point.pinStyle == .repeaterHop })
    return locatedHops < message.hopCount ? "≥ \(formatted)" : formatted
  }

  /// Reference for disambiguating hop hashes in the list — the same rule the
  /// map builder resolves against (`MessagePathMapView.receiverReference`), so
  /// an ambiguous hop is never named differently here than it is pinned there.
  private var hopReferenceLocation: CLLocation? {
    MessagePathMapView.receiverReference(
      for: .message(message),
      userLocation: appState.bestAvailableLocation
    )
  }

  /// Value-typed projection of `bestAvailableLocation`, so `onChange` compares
  /// coordinates, not `CLLocation` identity (the radio-GPS fallback allocates a
  /// fresh object on every read).
  private var locationSample: LocationSample? {
    guard let location = appState.bestAvailableLocation else { return nil }
    return LocationSample(
      latitude: location.coordinate.latitude,
      longitude: location.coordinate.longitude
    )
  }

  private func buildLocatedNodes() -> [(point: MapPoint, coordinate: CLLocationCoordinate2D)] {
    MessagePathMapView.locatedNodes(
      for: .message(message),
      contacts: pathViewModel.contacts,
      repeaters: pathViewModel.repeaters,
      discoveredRepeaters: pathViewModel.discoveredRepeaters,
      userLocation: appState.bestAvailableLocation,
      receiverName: appState.connectedDevice?.nodeName
    )
  }
}

private struct LocationSample: Equatable {
  let latitude: Double
  let longitude: Double
}
