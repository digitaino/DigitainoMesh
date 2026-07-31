import MessagingUI
import SwiftUI
import UIKit

/// Chat scroll container backed by `MessagingUI.TiledView`.
///
/// Replaces the bespoke flipped `UITableView`: the library provides stable
/// prepend (no scroll jump when paging older messages) and auto-scroll-to-bottom
/// on append. Consumers keep passing the same items array and cell-content
/// closure they used with the old table.
struct ChatTiledView<Item: Identifiable & Hashable & Sendable, Content: View>: View where Item.ID == UUID {
  let items: [Item]
  let cellContent: (Item) -> Content

  /// Themed canvas color; `nil` leaves the background transparent so the
  /// surrounding surface shows through.
  var contentBackground: Color?

  @Binding var isAtBottom: Bool
  @Binding var unreadCount: Int

  /// Bumped by callers to scroll to the visual bottom (e.g. on send).
  var scrollToBottomRequest: Int = 0

  /// Bumped by callers to jump to `scrollTargetID` (mention / reply / deeplink / divider).
  var scrollToTargetRequest: Int = 0
  var scrollTargetID: Item.ID?

  /// One-shot item the list opens scrolled to on the first non-empty snapshot;
  /// nil opens at the bottom. Drives the library's initial scroll target.
  var initialScrollTargetID: Item.ID?

  /// Invoked when the top is reached, to page in older messages.
  var onLoadOlder: (@MainActor @Sendable () async -> Void)?

  /// Invoked once, on the first post-positioning geometry report, when an
  /// `initialScrollTargetID` was in effect — the point at which the library has
  /// consumed the one-shot target. Lets the owner retire a divider target so a
  /// later `.id` rebuild does not re-jump to it.
  var onInitialTargetConsumed: (() -> Void)?

  /// Search-reveal events derived from the scroll geometry: `.reveal` when the reader scrolls
  /// up from the bottom far enough (or pulls past the end of a conversation too short to
  /// scroll), `.settledAtBottom` when the list comes to rest at the newest message again.
  /// Optional and defaulted so consumers without the affordance (the room conversation) are
  /// unaffected. `.none` frames are not forwarded.
  var onSearchRevealEvent: ((ChatSearchRevealEvent) -> Void)?

  /// Whether the bar `.reveal` opens is already showing. Passed in rather than inferred so the
  /// latch can consume a crossing without re-firing the reveal while the bar is up.
  var isSearchBarActive: Bool = false

  @Environment(\.appTheme) private var appTheme
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  @State private var scrollPosition: TiledScrollPosition
  @State private var host = CellContentHost<Item, Content>()
  @State private var newestID: Item.ID?
  @State private var hasConsumedInitialGeometry = false
  @State private var searchRevealLatch = ChatSearchRevealLatchBox()

  init(
    items: [Item],
    cellContent: @escaping (Item) -> Content,
    contentBackground: Color? = nil,
    isAtBottom: Binding<Bool>,
    unreadCount: Binding<Int>,
    scrollToBottomRequest: Int = 0,
    scrollToTargetRequest: Int = 0,
    scrollTargetID: Item.ID? = nil,
    initialScrollTargetID: Item.ID? = nil,
    onLoadOlder: (@MainActor @Sendable () async -> Void)? = nil,
    onInitialTargetConsumed: (() -> Void)? = nil,
    onSearchRevealEvent: ((ChatSearchRevealEvent) -> Void)? = nil,
    isSearchBarActive: Bool = false
  ) {
    self.items = items
    self.cellContent = cellContent
    self.contentBackground = contentBackground
    _isAtBottom = isAtBottom
    _unreadCount = unreadCount
    self.scrollToBottomRequest = scrollToBottomRequest
    self.scrollToTargetRequest = scrollToTargetRequest
    self.scrollTargetID = scrollTargetID
    self.initialScrollTargetID = initialScrollTargetID
    self.onLoadOlder = onLoadOlder
    self.onInitialTargetConsumed = onInitialTargetConsumed
    self.onSearchRevealEvent = onSearchRevealEvent
    self.isSearchBarActive = isSearchBarActive
    // Open at the bottom by default; with an initial target present, hold off
    // append-follow until the geometry callback re-derives it from the resting
    // position, so an append during open does not fight the target.
    _scrollPosition = State(initialValue: TiledScrollPosition(
      autoScrollsToBottomOnAppend: initialScrollTargetID == nil,
      scrollsToBottomOnReplace: true
    ))
  }

  var body: some View {
    host.content = cellContent

    return TiledView(items: items, scrollPosition: $scrollPosition) { item in
      ChatTiledCell(item: item, host: host)
    }
    .prependLoader(onLoadOlder.map { load in
      .loader(perform: load) {
        ProgressView().padding(.vertical, 8)
      }
    })
    .initialScrollTarget(id: initialScrollTargetID.map { AnyHashable($0) }, anchor: .top)
    .onTiledScrollGeometryChange { geometry in
      let atBottom = geometry.pointsFromBottom < ChatScrollConstants.bottomDetectionThreshold
      if atBottom != isAtBottom { isAtBottom = atBottom }
      if atBottom, unreadCount != 0 { unreadCount = 0 }
      // Only follow appends while near the bottom; otherwise new messages
      // accumulate as unread (counted in the onChange below). The first report
      // after a target open reflects the resting position, not a user scroll, so
      // it consumes the one-shot target instead of arming follow.
      if hasConsumedInitialGeometry || initialScrollTargetID == nil {
        scrollPosition.autoScrollsToBottomOnAppend = atBottom
      } else {
        onInitialTargetConsumed?()
      }
      hasConsumedInitialGeometry = true
      reportSearchRevealEvent(geometry)
    }
    .onDragIntoBottomSafeArea {
      UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    .background(contentBackground ?? .clear)
    .id(appearanceIdentity)
    .overlay(alignment: .bottomTrailing) {
      ScrollToBottomButton(
        isVisible: !isAtBottom,
        unreadCount: unreadCount,
        onTap: { scrollPosition.scrollTo(edge: .bottom) }
      )
      .padding(.trailing, 16)
      .padding(.bottom, 8)
    }
    .onChange(of: scrollToBottomRequest) {
      searchRevealLatch.latch.noteProgrammaticScroll()
      scrollPosition.scrollTo(edge: .bottom)
    }
    .onChange(of: scrollToTargetRequest) {
      guard let id = scrollTargetID else { return }
      searchRevealLatch.latch.noteProgrammaticScroll()
      scrollPosition.scrollTo(id: id)
    }
    .onChange(of: items.last?.id, initial: true) { _, latest in
      defer { newestID = latest }
      guard !isAtBottom, let previous = newestID,
            let previousIndex = items.firstIndex(where: { $0.id == previous }) else { return }
      let appended = items.count - 1 - previousIndex
      if appended > 0 { unreadCount += appended }
    }
  }

  /// Feeds one geometry frame to the reveal latch and forwards a meaningful event to the
  /// owner. The rubber-band distance still has to be derived from raw offsets — the clamped
  /// `pointsFromBottom` reads the whole band as "at the bottom" — because it both gates
  /// re-arming (a stretched band is not at rest) and carries the short-conversation pull.
  private func reportSearchRevealEvent(_ geometry: TiledScrollGeometry) {
    guard let onSearchRevealEvent else { return }
    let overscroll = ChatSearchRevealPolicy.overscrollPastBottom(
      contentOffsetY: geometry.contentOffset.y,
      contentHeight: geometry.contentSize.height,
      visibleHeight: geometry.visibleSize.height,
      topInset: geometry.contentInset.top,
      bottomInset: geometry.contentInset.bottom
    )
    let event = searchRevealLatch.latch.event(
      pointsFromBottom: geometry.pointsFromBottom,
      contentOffsetY: geometry.contentOffset.y,
      overscroll: overscroll,
      contentFits: geometry.contentSize.height <= geometry.visibleSize.height,
      isSearchActive: isSearchBarActive
    )
    if event != .none { onSearchRevealEvent(event) }
  }

  /// Fingerprint of theme + appearance. A change fully rebuilds the list (via `.id`) so the
  /// baked bubble colors repaint — the library does not reconfigure cells when only the
  /// environment changes.
  private var appearanceIdentity: String {
    let appearance = AppearanceToken.make(
      colorScheme: colorScheme,
      contrast: colorSchemeContrast,
      dynamicTypeSize: dynamicTypeSize
    )
    return "\(appTheme.id)|\(appearance)"
  }
}

/// Reference box for the reveal latch.
///
/// The latch re-arms on every resting geometry frame, and geometry arrives on every frame of
/// every scroll. Holding it directly in `@State` would write through the property wrapper each
/// time and rebuild the whole list mid-scroll; a class instance parked in `@State` keeps the
/// arming state alive across body evaluations without invalidating anything. Same reason
/// `CellContentHost` above is a class.
@MainActor
private final class ChatSearchRevealLatchBox {
  var latch = ChatSearchRevealLatch()
}
