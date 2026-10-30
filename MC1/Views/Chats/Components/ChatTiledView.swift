import MessagingUI
import SwiftUI

/// MessagingUI.TiledView provides stable prepend positioning and controlled append-follow for chat.
struct ChatTiledView<Item: Identifiable & Hashable & Sendable, Content: View>: View where Item.ID == UUID {
  let items: [Item]
  let cellContent: (Item) -> Content

  /// Themed canvas color; `nil` leaves the background transparent so the
  /// surrounding surface shows through.
  var contentBackground: Color?

  @Binding var isAtBottom: Bool
  @Binding var unreadCount: Int

  /// Bumped by callers to pin the visual bottom. Honored only while `isAtBottom`
  /// is already true; `ScrollToBottomButton` calls `scrollPosition.scrollTo` itself.
  var scrollToBottomRequest: Int = 0

  /// Request an unconditional bottom scroll, including while reading history.
  var userScrollToBottomRequest: Int = 0

  /// Returns whether an appended row raises the unread badge while scrolled up.
  var countsTowardUnread: (Item) -> Bool = { _ in true }

  /// Bumped by callers to jump to `scrollTargetID` (mention / reply / deeplink / divider).
  var scrollToTargetRequest: Int = 0
  var scrollTargetID: Item.ID?

  /// One-shot item the list opens scrolled to on the first non-empty snapshot;
  /// nil opens at the bottom. Drives the library's initial scroll target.
  var initialScrollTargetID: Item.ID?

  /// Invoked when the top is reached, to page in older messages.
  var onLoadOlder: (@MainActor @Sendable () async -> Void)?

  /// Retire the opening target after its first positioned geometry report so a later rebuild cannot replay it.
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

  /// Message heights kept across views, so a reopen skips measuring
  /// unchanged items. Nil measures on each open.
  var sizeCache: TiledSizeCache<Item>?

  @Environment(\.appTheme) private var appTheme
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  @State private var scrollPosition: TiledScrollPosition
  @State private var host = CellContentHost<Item, Content>()
  @State private var newestID: Item.ID?
  @State private var hasConsumedInitialGeometry = false
  @State private var searchRevealLatch = ChatSearchRevealLatchBox()

  private var openingScrollTargetID: Item.ID? {
    guard !hasConsumedInitialGeometry else { return nil }
    return scrollTargetID ?? initialScrollTargetID
  }

  init(
    items: [Item],
    cellContent: @escaping (Item) -> Content,
    contentBackground: Color? = nil,
    isAtBottom: Binding<Bool>,
    unreadCount: Binding<Int>,
    scrollToBottomRequest: Int = 0,
    userScrollToBottomRequest: Int = 0,
    countsTowardUnread: @escaping (Item) -> Bool = { _ in true },
    scrollToTargetRequest: Int = 0,
    scrollTargetID: Item.ID? = nil,
    initialScrollTargetID: Item.ID? = nil,
    onLoadOlder: (@MainActor @Sendable () async -> Void)? = nil,
    onInitialTargetConsumed: (() -> Void)? = nil,
    onSearchRevealEvent: ((ChatSearchRevealEvent) -> Void)? = nil,
    isSearchBarActive: Bool = false,
    sizeCache: TiledSizeCache<Item>? = nil
  ) {
    self.items = items
    self.cellContent = cellContent
    self.contentBackground = contentBackground
    _isAtBottom = isAtBottom
    _unreadCount = unreadCount
    self.scrollToBottomRequest = scrollToBottomRequest
    self.userScrollToBottomRequest = userScrollToBottomRequest
    self.countsTowardUnread = countsTowardUnread
    self.scrollToTargetRequest = scrollToTargetRequest
    self.scrollTargetID = scrollTargetID
    self.initialScrollTargetID = initialScrollTargetID
    self.onLoadOlder = onLoadOlder
    self.onInitialTargetConsumed = onInitialTargetConsumed
    self.onSearchRevealEvent = onSearchRevealEvent
    self.isSearchBarActive = isSearchBarActive
    self.sizeCache = sizeCache
    // Defer append-follow while an initial target is positioning so incoming messages cannot displace it.
    _scrollPosition = State(initialValue: TiledScrollPosition(
      autoScrollsToBottomOnAppend: scrollTargetID == nil && initialScrollTargetID == nil,
      scrollsToBottomOnReplace: true
    ))
  }

  var body: some View {
    host.content = cellContent
    // Cached heights are only valid for the appearance they were measured in.
    sizeCache?.context = appearanceIdentity

    return TiledView(items: items, scrollPosition: $scrollPosition) { item in
      ChatTiledCell(item: item, host: host)
    }
    .sizeCache(sizeCache)
    .prependLoader(onLoadOlder.map { load in
      .loader(perform: load) {
        ProgressView().padding(.vertical, 8)
      }
    })
    .initialScrollTarget(id: openingScrollTargetID.map { AnyHashable($0) }, anchor: .top)
    .onTiledScrollGeometryChange { geometry in
      let atBottom = geometry.pointsFromBottom < ChatScrollConstants.bottomDetectionThreshold
      if atBottom != isAtBottom { isAtBottom = atBottom }
      if atBottom, unreadCount != 0 { unreadCount = 0 }
      // Follow appends only while near the bottom. A one-shot target's first
      // report is the resting position, so consume it instead of arming follow.
      if openingScrollTargetID == nil {
        scrollPosition.autoScrollsToBottomOnAppend = atBottom
      } else {
        onInitialTargetConsumed?()
      }
      hasConsumedInitialGeometry = true
      reportSearchRevealEvent(geometry)
    }
    .onDragIntoBottomSafeArea { ChatKeyboardLift.resignFirstResponder() }
    .softTopScrollEdgeEffect()
    .background(contentBackground ?? .clear)
    .legacyTimelineClip()
    .id(appearanceIdentity)
    .overlay(alignment: .bottomTrailing) {
      ScrollToBottomButton(
        isVisible: !isAtBottom,
        unreadCount: unreadCount,
        onTap: { scrollUserToBottom() }
      )
      .padding(.trailing, 16)
      .padding(.bottom, 8)
    }
    .onChange(of: scrollToBottomRequest) {
      guard isAtBottom else { return }
      searchRevealLatch.latch.noteProgrammaticScroll()
      scrollPosition.scrollTo(edge: .bottom, animated: false)
    }
    .onChange(of: userScrollToBottomRequest) {
      scrollUserToBottom()
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
      let incoming = items.suffix(from: previousIndex + 1).filter(countsTowardUnread).count
      if incoming > 0 { unreadCount += incoming }
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

  /// Unconditional jump to the visual bottom. Used by `ScrollToBottomButton`
  /// and by `userScrollToBottomRequest`. Distinct from `scrollToBottomRequest`,
  /// which must not yank a scrolled-up thread.
  private func scrollUserToBottom() {
    scrollPosition.scrollTo(edge: .bottom)
  }

  /// Rebuild on theme or appearance changes because the library does not reconfigure environment-only cell updates.
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

private struct LegacyTimelineClip: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 26, *) {
      content
    } else {
      content.clipped()
    }
  }
}

private extension View {
  func legacyTimelineClip() -> some View {
    modifier(LegacyTimelineClip())
  }
}

private extension TiledView {
  /// OS 27 defaults the top fade to hard. Soft keeps the progressive blur
  /// under the conversation title capsule.
  @ViewBuilder
  consuming func softTopScrollEdgeEffect() -> some View {
    if #available(iOS 26.0, *) {
      scrollEdgeEffectStyle(.soft, for: .top)
    } else {
      self
    }
  }
}
