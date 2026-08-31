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
      // The visible label and the interactive `Menu`'s label must be the *same size*.
      // They are two instances of one view, drawn on top of each other; the Menu carries
      // the glass backdrop, `colorMultiply` clears its content but not that backdrop, and
      // the two coincide only for as long as nothing changes one and not the other.
      // Sizing them apart — a 44 pt floor applied inside the Menu's label only — put a
      // 44 pt glass capsule across the middle of a 120 pt cluster (field report,
      // 2026-08-31). Any minimum belongs to the label itself, upstream of here, where one
      // change reaches both copies.
      label
        .accessibilityHidden(true)
        .overlay {
          Menu { content } label: { label } primaryAction: { primaryAction() }
            .colorMultiply(.clear)
        }
    } else {
      Menu { content } label: { label } primaryAction: { primaryAction() }
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
