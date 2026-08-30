import SwiftUI

extension View {
  /// Applies liquid glass effect on iOS 26+, falls back to regularMaterial on earlier versions
  @ViewBuilder
  func liquidGlass(in shape: some Shape = .rect(cornerRadius: 12)) -> some View {
    if #available(iOS 26.0, *) {
      glassEffect(in: shape)
    } else {
      background(.regularMaterial, in: shape)
    }
  }

  /// Applies glass button style on iOS 26+, falls back to borderedProminent on earlier versions
  @ViewBuilder
  func liquidGlassButtonStyle() -> some View {
    if #available(iOS 26.0, *) {
      buttonStyle(.glass)
    } else {
      buttonStyle(.borderedProminent)
    }
  }

  /// Applies glass button style on iOS 26+, falls back to bordered (secondary weight) on earlier versions
  @ViewBuilder
  func liquidGlassSecondaryButtonStyle() -> some View {
    if #available(iOS 26.0, *) {
      buttonStyle(.glass)
    } else {
      buttonStyle(.bordered)
    }
  }

  /// Applies prominent glass button style with tint on iOS 26+, falls back to borderedProminent on earlier versions
  @ViewBuilder
  func liquidGlassProminentButtonStyle() -> some View {
    if #available(iOS 26.0, *) {
      buttonStyle(.glassProminent)
    } else {
      buttonStyle(.borderedProminent)
    }
  }

  /// Applies interactive liquid glass effect on iOS 26+, falls back to thinMaterial on earlier versions
  @ViewBuilder
  func liquidGlassInteractive(in shape: some Shape = .circle) -> some View {
    if #available(iOS 26.0, *) {
      glassEffect(.regular.interactive(), in: shape)
    } else {
      background(.thinMaterial, in: shape)
    }
  }

  #if os(iOS)
    /// Applies visible toolbar backgrounds for full-screen content views.
    /// On iOS 26+, explicitly sets visibility so system applies liquid glass.
    /// On iOS 18, uses regularMaterial background.
    @ViewBuilder
    func liquidGlassToolbarBackground() -> some View {
      if #available(iOS 26.0, *) {
        toolbarBackgroundVisibility(.visible, for: .navigationBar)
      } else {
        toolbarBackground(.regularMaterial, for: .navigationBar, .tabBar)
          .toolbarBackgroundVisibility(.visible, for: .navigationBar, .tabBar)
      }
    }
  #endif
}

extension View {
  /// Applies glassEffectID on iOS 26+ for smooth morphing transitions, no-op on earlier versions
  @ViewBuilder
  func liquidGlassID<ID: Hashable & Sendable>(_ id: ID, in namespace: Namespace.ID) -> some View {
    if #available(iOS 26.0, *) {
      glassEffectID(id, in: namespace)
    } else {
      self
    }
  }
}

/// Drop-in replacement for `Menu` that works around an iPadOS 26 Liquid Glass bug
/// where toolbar Menus leave a ghost box after dismissal.
///
/// On iOS 26+, renders the label as a plain view with an invisible interactive `Menu`
/// overlay, so the glass morph animation has nothing visible to ghost.
/// On earlier iOS versions, uses a standard `Menu`.
struct ToolbarMenu<Content: View, LabelView: View>: View {
  @ViewBuilder let content: Content
  @ViewBuilder let label: LabelView

  var body: some View {
    if #available(iOS 26, *) {
      label
        .accessibilityHidden(true)
        .overlay {
          Menu { content } label: { label }
            .colorMultiply(.clear)
        }
    } else {
      Menu { content } label: { label }
    }
  }
}

/// `ToolbarMenu` for a control with a primary action: a tap runs `primaryAction`, a sustained
/// press opens the menu — `Menu(primaryAction:)`'s split, carried through the same ghost-box
/// workaround. A separate type rather than an optional on `ToolbarMenu` so the two shapes are
/// distinct static structures: a runtime branch between the `Menu` inits would hand a hosted
/// toolbar item a new identity mid-update.
struct ToolbarActionMenu<Content: View, LabelView: View>: View {
  let primaryAction: () -> Void
  @ViewBuilder let content: Content
  @ViewBuilder let label: LabelView

  var body: some View {
    if #available(iOS 26, *) {
      // The interactive `Menu` lives in an `.overlay`, which contributes nothing to
      // layout: the toolbar item's size — and therefore its hit rect, since UIKit clips
      // hit-testing to the hosting view's bounds — is the *base* label's. A label that
      // shrinks (a signal cluster collapsing to a single glyph) takes the tap target down
      // with it, to well under the 44 pt minimum, and the control reads as dead
      // (field report, 2026-08-30: "now it won't open at all").
      //
      // The floor has to go on **both**: on the base, or the bounds clip whatever the
      // overlay does; and inside the `Menu`'s own label, because an overlay is *centred*
      // at its ideal size rather than filled, so a floor applied outside the `Menu`
      // enlarges the box without enlarging the only view that has a gesture attached.
      label
        .accessibilityHidden(true)
        .frame(minWidth: 44, minHeight: 44)
        .overlay {
          Menu {
            content
          } label: {
            label
              .frame(minWidth: 44, minHeight: 44)
              .contentShape(.rect)
          } primaryAction: {
            primaryAction()
          }
          .colorMultiply(.clear)
        }
    } else {
      Menu {
        content
      } label: {
        label
          .frame(minWidth: 44, minHeight: 44)
          .contentShape(.rect)
      } primaryAction: {
        primaryAction()
      }
    }
  }
}

/// A container that uses GlassEffectContainer on iOS 26+, passes through content on earlier versions
struct LiquidGlassContainer<Content: View>: View {
  let spacing: CGFloat
  @ViewBuilder let content: Content

  init(spacing: CGFloat = 20, @ViewBuilder content: () -> Content) {
    self.spacing = spacing
    self.content = content()
  }

  var body: some View {
    if #available(iOS 26.0, *) {
      GlassEffectContainer(spacing: spacing) {
        content
      }
    } else {
      content
    }
  }
}
