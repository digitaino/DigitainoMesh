import MC1Services
import SwiftUI

struct ContentView: View {
  @Environment(\.appState) private var appState
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  var body: some View {
    @Bindable var connectionUI = appState.connectionUI

    Group {
      if appState.onboarding.hasCompletedOnboarding {
        if horizontalSizeClass == .regular {
          MainSidebarView()
        } else {
          MainTabView()
        }
      } else {
        OnboardingView()
      }
    }
    .animation(.default, value: appState.onboarding.hasCompletedOnboarding)
    .onChange(of: scenePhase) { _, newPhase in
      if newPhase == .active {
        appState.handleBecameActive()
      }
    }
    // The stale-location check needs a ready radio *and* a phone fix. Connect-ready is
    // handled by `onDeviceSynced`; this is the other half, for when the fix lands second.
    .onChange(of: appState.locationService.currentLocation) { _, _ in
      appState.evaluateNodeLocationStaleness()
    }
    .alert(
      connectionUI.connectionFailedTitle ?? L10n.Localizable.Alert.ConnectionFailed.title,
      isPresented: $connectionUI.showingConnectionFailedAlert
    ) {
      if appState.connectionUI.failedPairingDeviceID != nil {
        switch appState.connectionUI.pairingFailureKind {
        case .authentication, .pinRejected:
          // Bond can't proceed (a dead saved bond or a rejected fresh PIN), so
          // destructive remove is the recovery. The two kinds share these
          // buttons and differ only in the message copy set by the presenter.
          Button(L10n.Localizable.Alert.ConnectionFailed.removeAndRetry, role: .destructive) {
            appState.removeFailedPairingAndRetry()
          }
          .accessibilityLabel(L10n.Localizable.Accessibility.Alert.ConnectionFailed.removeAndRetry)
          Button(L10n.Localizable.Common.cancel, role: .cancel) {
            appState.connectionUI.failedPairingDeviceID = nil
          }
        case .transient, .none:
          // Transient variant — bond is still good, prefer non-destructive retry.
          // `.none` is unreachable in practice (every pairing-failure path routes
          // through `presentPairingFailure`, which always sets the kind). Folding
          // it into the safer branch ensures a missing kind can't promote a working
          // bond into the destructive recovery.
          Button(L10n.Localizable.Common.tryAgain) {
            Task { await appState.retryFailedPairingConnect() }
          }
          Button(L10n.Localizable.Alert.ConnectionFailed.removeAndRetry, role: .destructive) {
            appState.removeFailedPairingAndRetry()
          }
          .accessibilityLabel(L10n.Localizable.Accessibility.Alert.ConnectionFailed.removeAndRetry)
          Button(L10n.Localizable.Common.cancel, role: .cancel) {
            appState.connectionUI.failedPairingDeviceID = nil
          }
        }
      } else {
        Button(L10n.Localizable.Common.ok, role: .cancel) {}
      }
    } message: {
      Text(appState.connectionUI.connectionFailedMessage ?? L10n.Localizable.Alert.ConnectionFailed.defaultMessage)
    }
    .alert(
      L10n.Localizable.Alert.CouldNotConnect.title,
      isPresented: Binding(
        get: { appState.connectionUI.otherAppWarningDeviceID != nil },
        set: { if !$0 { appState.connectionUI.otherAppWarningDeviceID = nil } }
      )
    ) {
      Button(L10n.Localizable.Common.ok) {
        appState.connectionUI.otherAppWarningDeviceID = nil
      }
    } message: {
      Text(L10n.Localizable.Alert.CouldNotConnect.otherAppMessage)
    }
    // macOS "Designed for iPad" device picker. `bluetoothScanPicker` is nil on iOS, where
    // AccessorySetupKit presents its own system picker, so this sheet never appears there.
    .sheet(isPresented: Binding(
      get: { appState.connectionManager.bluetoothScanPicker?.isPresenting ?? false },
      set: { if !$0 { appState.connectionManager.bluetoothScanPicker?.cancel() } }
    )) {
      if let scanPicker = appState.connectionManager.bluetoothScanPicker {
        DeviceScannerSheet(picker: scanPicker)
      }
    }
    .sheet(item: $connectionUI.pendingSystemPairingSetup, onDismiss: {
      appState.handleSystemPairingSetupSheetDismissed()
    }) { prompt in
      SystemPairingSetupSheet(
        prompt: prompt,
        onForget: { appState.confirmSystemPairingSetup() },
        onCancel: { appState.cancelSystemPairingSetup() }
      )
    }
    // SwiftUI does not reliably co-present a sheet and an alert from the same host,
    // so the binding yields a release only while the connection UI above is quiescent;
    // `pendingRelease` stays set and re-presents on the next render once any alert clears.
    .sheet(item: Binding(
      get: { connectionUIQuiescent ? appState.whatsNew.pendingRelease : nil },
      set: { if $0 == nil { appState.whatsNew.markShown() } }
    )) { release in
      WhatsNewSheet(release: release)
    }
    // After a radio takes on an identity: the "Copy to This Radio" screen itself, so the offer
    // shows exactly what would be written and nothing is written until the user confirms.
    // Same co-presentation contract as the What's New sheet, which it yields to.
    .sheet(item: Binding(
      get: { radioSwapOfferPresentable ? appState.radioSwapPrompt.pending : nil },
      set: { if $0 == nil { appState.radioSwapPrompt.dismiss() } }
    )) { offer in
      NavigationStack {
        NodeConfigImportView(source: .records, swapIdentityName: offer.identityName) {
          appState.radioSwapPrompt.dismiss()
        }
      }
    }
    // A blank radio: set it up as one of the user's saved nodes, or keep it as a new node.
    // Same co-presentation contract; a swipe closes it unanswered, so it is asked again.
    .sheet(item: Binding(
      get: { radioSetUpPresentable ? appState.radioSetUpPrompt.pending : nil },
      set: { if $0 == nil { appState.radioSetUpPrompt.close() } }
    )) { setUp in
      RadioSetUpSheet(setUp: setUp)
    }
    // Same co-presentation contract as the What's New sheet above: the getter yields the
    // prompt only while this host is quiescent, and `pending` stays set meanwhile, so the
    // alert re-presents on a later render once the higher-priority surface clears.
    .alert(
      L10n.Localizable.Alert.NodeLocationStale.title,
      isPresented: Binding(
        get: { nodeLocationPromptPresentable },
        set: { if !$0 { appState.nodeLocationPrompt.clearPending() } }
      ),
      presenting: appState.nodeLocationPrompt.pending
    ) { prompt in
      // The write takes the presented value, not `pending`: dismissal runs the binding's
      // setter — which clears `pending` — before the task below starts.
      Button(L10n.Localizable.Alert.NodeLocationStale.update) {
        Task { await appState.applyPendingNodeLocation(prompt) }
      }
      Button(L10n.Localizable.Alert.NodeLocationStale.notNow, role: .cancel) {
        appState.nodeLocationPrompt.snoozeCurrent()
      }
    } message: { prompt in
      Text(L10n.Localizable.Alert.NodeLocationStale.message(
        NodeLocationStalenessPolicy.formattedDistance(prompt.distanceMeters)
      ))
    }
    .sensoryFeedback(.success, trigger: appState.nodeLocationPrompt.successTrigger)
    .sensoryFeedback(.error, trigger: appState.nodeLocationPrompt.failureTrigger)
  }

  /// True when no connection alert or scan picker from this host is presenting.
  private var connectionUIQuiescent: Bool {
    !appState.connectionUI.showingConnectionFailedAlert
      && appState.connectionUI.otherAppWarningDeviceID == nil
      && appState.connectionUI.pendingSystemPairingSetup == nil
      && !(appState.connectionManager.bluetoothScanPicker?.isPresenting ?? false)
  }

  /// The radio swap offer yields to the connection alerts, the scan picker, and What's New.
  private var radioSwapOfferPresentable: Bool {
    appState.radioSwapPrompt.pending != nil
      && connectionUIQuiescent
      && appState.whatsNew.pendingRelease == nil
  }

  /// The set-up question yields to the same surfaces as the swap offer, and to the offer itself.
  private var radioSetUpPresentable: Bool {
    appState.radioSetUpPrompt.pending != nil
      && connectionUIQuiescent
      && appState.whatsNew.pendingRelease == nil
      && appState.radioSwapPrompt.pending == nil
  }

  /// The stale-location prompt is the lowest-priority surface on this host: it yields to the
  /// connection alerts, the scan picker, the What's New sheet, the radio swap offer and the
  /// set-up question.
  private var nodeLocationPromptPresentable: Bool {
    appState.nodeLocationPrompt.pending != nil
      && connectionUIQuiescent
      && appState.whatsNew.pendingRelease == nil
      && appState.radioSwapPrompt.pending == nil
      && appState.radioSetUpPrompt.pending == nil
  }
}

// MARK: - Onboarding View

struct OnboardingView: View {
  @Environment(\.appState) private var appState

  var body: some View {
    @Bindable var onboarding = appState.onboarding

    NavigationStack(path: $onboarding.onboardingPath) {
      WelcomeView()
        .navigationDestination(for: OnboardingStep.self) { step in
          switch step {
          case .welcome:
            WelcomeView()
          case .permissions:
            PermissionsView()
          case .pair:
            DeviceScanView()
          case .region:
            RegionStepView()
          case .preset:
            PresetStepView()
          }
        }
    }
  }
}

// MARK: - Main Tab View

struct MainTabView: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @State private var showingDeviceSelection = false

  var body: some View {
    @Bindable var navigation = appState.navigation

    TabView(selection: $navigation.selectedTab) {
      Tab(L10n.Localizable.Tabs.chats, systemImage: "message.fill", value: AppTab.chats.rawValue) {
        ChatsView()
      }
      .badge(appState.services?.notificationService.badgeCount ?? 0)

      Tab(L10n.Localizable.Tabs.nodes, systemImage: "flipphone", value: AppTab.nodes.rawValue) {
        ContactsListView()
      }

      Tab(L10n.Localizable.Tabs.map, systemImage: "map.fill", value: AppTab.map.rawValue) {
        MapView()
      }

      Tab(L10n.Localizable.Tabs.tools, systemImage: "wrench.and.screwdriver", value: AppTab.tools.rawValue) {
        ToolsView()
      }

      Tab(L10n.Localizable.Tabs.settings, systemImage: "gear", value: AppTab.settings.rawValue) {
        SettingsView()
      }
    }
    .themedChrome(theme)
    .syncingPillOverlay(onDisconnectedTap: { showingDeviceSelection = true })
    .onChange(of: appState.navigation.selectedTab) { _, _ in
      // Donate pending device menu tip when returning to a valid tab
      if appState.navigation.pendingDeviceMenuTipDonation, appState.navigation.isOnValidTabForDeviceMenuTip {
        Task {
          await appState.donateDeviceMenuTipIfOnValidTab()
        }
      }
    }
    .sheet(isPresented: $showingDeviceSelection, onDismiss: {
      appState.handleDeviceSelectionSheetDismissed()
    }) {
      DeviceSelectionSheet()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
  }
}

#Preview("Content View - Onboarding") {
  ContentView()
    .environment(\.appState, AppState())
}

#Preview("Content View - Main App") {
  let appState = AppState()
  appState.onboarding.hasCompletedOnboarding = true
  return ContentView()
    .environment(\.appState, appState)
}
