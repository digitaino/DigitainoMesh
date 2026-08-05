import CoreLocation
import MC1Services
import SwiftUI

/// The heard-repeats map: every echo of an outgoing message drawn as a round
/// trip — us → the repeaters that carried it → back to us — over the same
/// full-bleed canvas, hop resolution, and floating-panel layout the message
/// path screen uses (`MessagePathDetailView`), so the two path-shaped maps
/// stay one system. An echo that reached us through repeaters that never
/// heard us directly traces the triangle/polygon that detour actually took.
///
/// Presented as a cover rather than a sheet for the same reason the path
/// screen is: a downward drag over a map should pan the map, not dismiss it.
struct HeardRepeatsMapView: View {
  /// Panel sizing mirrors `MessagePathDetailView` so the two screens read as
  /// siblings.
  private static let panelMaxHeightFraction: CGFloat = 0.45
  private static let panelCornerRadius: CGFloat = 20
  private static let panelMargin: CGFloat = 12

  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss

  let message: MessageDTO
  let repeats: [MessageRepeatDTO]
  let pathViewModel: MessagePathViewModel

  @State private var locatedNodes: [(point: MapPoint, coordinate: CLLocationCoordinate2D)] = []
  @State private var lines: [MapLine] = []
  @State private var repeatListHeight: CGFloat = 0
  @State private var panelHeight: CGFloat = 0

  var body: some View {
    NavigationStack {
      content
        .navigationTitle(L10n.Chats.Chats.Message.Action.repeatDetails)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button(L10n.Localizable.Common.done) { dismiss() }
          }
        }
        .onAppear {
          // A stamped message anchors its loops to the send-time fix and
          // needs no GPS. Only the unstamped fallback origin depends on the
          // live location — and the cached fix can predate a suspend — so
          // ask for a live one then; the sample onChange moves it when it
          // lands.
          if message.userFixCoordinate == nil {
            appState.requestPhoneFixIfStale()
          }
          rebuildNodes()
        }
        // The actions sheet preloads the view model, but a fast tap can land
        // here with the contacts fetch still in flight — rebuild when it
        // lands so the map doesn't stay empty forever.
        .onChange(of: pathViewModel.isLoading) { _, isLoading in
          guard !isLoading else { return }
          rebuildNodes()
        }
        // A fresh fix landed: the unstamped fallback origin is built from it,
        // so rebuild. A stamped message is anchored to its recorded fix.
        .onChange(of: locationSample) { _, _ in
          guard message.userFixCoordinate == nil else { return }
          rebuildNodes()
        }
    }
  }

  @ViewBuilder
  private var content: some View {
    if pathViewModel.isLoading {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if !locatedNodes.contains(where: { $0.point.pinStyle == .repeaterHop }) {
      // No plottable repeater is not a failure — the repeat rows still name
      // what they can, so the list simply becomes the whole screen. This also
      // covers the origin-only case: a lone "me" pin on an empty map explains
      // nothing about the echoes.
      VStack(spacing: 0) {
        panelHeader
        Divider()
        repeatList(maxHeight: nil)
      }
    } else {
      GeometryReader { proxy in
        MessagePathMapCanvas(
          locatedNodes: locatedNodes,
          linesOverride: lines,
          cameraBottomSheetFraction: panelHeight / max(proxy.size.height, 1)
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
          floatingPanel(maxListHeight: proxy.size.height * Self.panelMaxHeightFraction)
        }
      }
    }
  }

  private func floatingPanel(maxListHeight: CGFloat) -> some View {
    VStack(spacing: 0) {
      panelHeader
      Divider()
        .padding(.horizontal, 16)
      repeatList(maxHeight: maxListHeight)
    }
    .liquidGlass(in: .rect(cornerRadius: Self.panelCornerRadius))
    .padding(.horizontal, Self.panelMargin)
    .padding(.bottom, Self.panelMargin)
    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
  }

  /// "Heard: N repeats" — the same figure the message's detail rows show,
  /// so the panel names what the loops below it draw.
  private var panelHeader: some View {
    HStack {
      let word = repeats.count == 1
        ? L10n.Chats.Chats.Message.Repeat.singular
        : L10n.Chats.Chats.Message.Repeat.plural
      Text(L10n.Chats.Chats.Message.Info.heardRepeats(repeats.count, word))
        .font(.subheadline.weight(.medium))
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private func repeatList(maxHeight: CGFloat?) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        RepeatDetailsContent(
          repeats: repeats,
          contacts: pathViewModel.contacts,
          discoveredNodes: pathViewModel.discoveredRepeaters,
          userLocation: originReference
        )
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { repeatListHeight = $0 }
    }
    .scrollBounceBehavior(.basedOnSize)
    .frame(height: maxHeight.map { min(repeatListHeight, $0) })
  }

  /// The "where were we" reference for name disambiguation in the rows — the
  /// send-time stamp when the message carries one, else the live best guess
  /// (`MessagePathMapView.receiverReference`, the same reference the map
  /// resolves against). Note the rules differ by design even with the shared
  /// reference: rows *name* ambiguous repeaters by proximity best-match,
  /// while the map only *pins* unambiguous ones.
  private var originReference: CLLocation? {
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

  private func rebuildNodes() {
    let built = MessagePathMapView.heardRepeatNodes(
      message: message,
      repeats: repeats,
      repeaters: pathViewModel.repeaters,
      discoveredRepeaters: pathViewModel.discoveredRepeaters,
      userLocation: appState.bestAvailableLocation,
      originName: appState.connectedDevice?.nodeName ?? L10n.Chats.Chats.Path.Receiver.you
    )
    locatedNodes = built.nodes
    lines = built.lines
  }
}

private struct LocationSample: Equatable {
  let latitude: Double
  let longitude: Double
}
