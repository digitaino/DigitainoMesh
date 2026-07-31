import AppIntents
import MC1Services
import os
import SwiftData
import SwiftUI
import TipKit

private let logger = Logger(subsystem: "com.mc1", category: "MC1App")

@main
struct MC1App: App {
  @State private var appState: AppState
  @State private var awaitingDataProtection = false
  /// Non-nil while the on-disk store cannot be opened: the scene shows
  /// `StoreRecoveryView` instead of the app, and `appState` is a throwaway
  /// in-memory container that must never be treated as the user's data.
  @State private var storeFailure: StoreOpenFailure?
  @Environment(\.scenePhase) private var scenePhase

  /// An unopenable store, reduced to what the recovery screen needs.
  private struct StoreOpenFailure: Equatable {
    let message: String

    init(_ error: any Error) {
      message = (error as NSError).localizedDescription
    }
  }

  /// Stable holder that App Intents read through `AppDependencyManager`. It
  /// must outlive the before-first-unlock `AppState` swap, so it is a plain
  /// stored property registered once in `init()`, not `@State`.
  private let intentBridge = IntentBridge()

  /// Stages externally opened URLs across launch; see `PendingExternalURL`.
  private let pendingExternalURL = PendingExternalURL()

  init() {
    // Register the bridge synchronously here: a background-launched intent
    // runs only `App.init` (no scene, no `.task`), so a deferred
    // registration could let its `@Dependency` read throw before it lands.
    // Capture into a local so the escaping autoclosure does not capture the
    // still-initializing `self`.
    let intentBridge = intentBridge
    AppDependencyManager.shared.add(dependency: intentBridge)

    // True on the before-first-unlock path and on the store-recovery path — both hold an
    // in-memory throwaway the bridge must not adopt.
    var usingThrowawayStore = false

    let container: ModelContainer
    do {
      container = try PersistenceStore.createContainer()
    } catch {
      logger.error("Container creation failed: \(error)")

      if UIApplication.shared.isProtectedDataAvailable {
        // Data is accessible — this is a genuine failure, not BFU.
        // Retry once for transient file system issues.
        logger.info("Retrying container creation")
        do {
          container = try PersistenceStore.createContainer()
        } catch {
          let nsError = error as NSError
          logger.fault("""
          Container creation failed after retry: \
          domain=\(nsError.domain, privacy: .public) \
          code=\(nsError.code, privacy: .public) \
          desc=\(nsError.localizedDescription, privacy: .public) \
          userInfo=\(String(describing: nsError.userInfo), privacy: .public)
          """)
          // Deliberately not a fatalError. A store that fails to open is almost always a
          // permanent condition (a migration the schema can't perform), so crashing here
          // produced a launch loop the user could never escape — with their messages and
          // contacts still on disk and no way to reach them. Come up on a throwaway
          // in-memory container instead and let `StoreRecoveryView` offer retry or a
          // non-destructive back-up-and-reset. Nothing is deleted automatically.
          do {
            container = try PersistenceStore.createContainer(inMemory: true)
          } catch {
            fatalError("In-memory ModelContainer creation failed while recovering from a store-open failure: \(error)")
          }
          _storeFailure = State(initialValue: StoreOpenFailure(nsError))
          usingThrowawayStore = true
        }
        let appState = AppState(modelContainer: container)
        _appState = State(initialValue: appState)
        // Same rule as the BFU path: the bridge must not adopt a throwaway store.
        if !usingThrowawayStore {
          intentBridge.adopt(appState)
        }
        return
      }

      // Before first unlock: the encrypted store is inaccessible. Create a throwaway
      // in-memory container so the struct can initialize. The .task body will wait for
      // data protection and replace this with the real store before doing any work.
      logger.warning("Protected data unavailable (before first unlock), deferring initialization")
      do {
        container = try PersistenceStore.createContainer(inMemory: true)
      } catch {
        fatalError("In-memory ModelContainer creation failed: \(error)")
      }
      _awaitingDataProtection = State(initialValue: true)
      usingThrowawayStore = true
    }
    let appState = AppState(modelContainer: container)
    _appState = State(initialValue: appState)
    // BFU throwaway: defer adoption to the post-unlock swap so a pre-unlock
    // intent reads nil, not an empty store.
    if !usingThrowawayStore {
      intentBridge.adopt(appState)
    }
  }

  var body: some Scene {
    WindowGroup {
      Group {
        if let storeFailure {
          // Swapped in for the whole app, not layered over it: none of ContentView's
          // launch work may touch the throwaway in-memory store standing in for the
          // user's real one.
          StoreRecoveryView(
            theme: appState.themeService.current,
            errorDescription: storeFailure.message,
            onTryAgain: reopenStore,
            onBackUpAndReset: backUpAndResetStore
          )
        } else {
          mainContent
        }
      }
      .environment(\.appState, appState)
      .environment(\.appTheme, appState.themeService.current)
      .tint(appState.themeService.current.chromeTint)
      .preferredColorScheme(appState.themeService.effectiveColorScheme)
    }
  }

  private var mainContent: some View {
    ContentView()
    #if !SIDELOAD
      .task(id: ObjectIdentifier(appState)) { await appState.storeState.service.load() }
    #endif
      .task {
        if awaitingDataProtection {
          await waitForProtectedData()
          do {
            let container = try PersistenceStore.createContainer()
            // Tear down the BFU-bootstrap AppState's StoreService listener Task
            // before swapping in the real AppState — otherwise the bootstrap
            // instance's Transaction.updates listener leaks for the process
            // lifetime and every later transaction event fires `walkCurrentEntitlements`
            // twice (once per orphaned StoreService).
            appState.shutdown()
            let realAppState = AppState(modelContainer: container)
            appState = realAppState
            // First real store on the BFU path; the bridge was
            // left nil in `init()` until now.
            intentBridge.adopt(realAppState)
            awaitingDataProtection = false
          } catch {
            let nsError = error as NSError
            logger.fault("""
            Container creation failed after unlock: \
            domain=\(nsError.domain, privacy: .public) \
            code=\(nsError.code, privacy: .public) \
            desc=\(nsError.localizedDescription, privacy: .public) \
            userInfo=\(String(describing: nsError.userInfo), privacy: .public)
            """)
            // Same reasoning as the `init()` path: hand the user a recovery screen
            // rather than a crash loop. `appState` is already the BFU throwaway, so
            // the scene stays up on it.
            storeFailure = StoreOpenFailure(nsError)
            awaitingDataProtection = false
            return
          }
        }

        // Launch-time, not radio-connect: the preference belongs to the phone, and a
        // Build 40 user who never reconnects still deserves the silence they chose.
        // Self-latching, so this is a single defaults read on every later launch.
        LegacyNotificationSwitchMigration.run()

        try? Tips.configure([
          .displayFrequency(.immediate)
        ])

        #if DEBUG
          if ProcessInfo.processInfo.isScreenshotMode {
            await setupScreenshotMode()
          } else {
            await appState.initialize()
          }
        #else
          await appState.initialize()
        #endif

        await runInitialForegroundReconciliationIfNeeded()
        pendingExternalURL.markReady(appState)
      }
      .onOpenURL { url in
        pendingExternalURL.submit(url, appState: appState)
      }
      .onChange(of: scenePhase) { oldPhase, newPhase in
        handleScenePhaseChange(from: oldPhase, to: newPhase)
      }
  }

  // MARK: - Store recovery

  /// "Try Again": re-attempt the real store with nothing changed on disk. Worth offering
  /// because a share of open failures are transient (a device still finishing a restore,
  /// a file briefly locked by the previous process).
  private func reopenStore() async {
    await adoptRealStore { try PersistenceStore.createContainer() }
  }

  /// "Back Up & Reset": move the unopenable store into `StoreBackups/<timestamp>/` and open
  /// a fresh one. User-confirmed in `StoreRecoveryView` — it takes live data out of the path
  /// the app reads. Nothing is deleted, so a later repair tool (or the user, via the Files
  /// app) can still get at it.
  private func backUpAndResetStore() async {
    await adoptRealStore {
      let folder = try PersistenceStore.backUpAndClearStore()
      logger.notice("Store moved aside to \(folder.lastPathComponent, privacy: .public); opening a fresh store")
      return try PersistenceStore.createContainer()
    }
  }

  /// Runs `makeContainer` off the main actor (opening a store can take seconds on a large
  /// migration), then swaps the throwaway `AppState` for one backed by the real store.
  /// Clearing `storeFailure` re-inserts `ContentView`, whose `.task` performs the normal
  /// launch sequence against the new container.
  private func adoptRealStore(_ makeContainer: @escaping @Sendable () throws -> ModelContainer) async {
    do {
      let container = try await Task.detached(priority: .userInitiated, operation: makeContainer).value
      appState.shutdown()
      let realAppState = AppState(modelContainer: container)
      appState = realAppState
      intentBridge.adopt(realAppState)
      storeFailure = nil
    } catch {
      logger.error("Store recovery attempt failed: \(error)")
      storeFailure = StoreOpenFailure(error)
    }
  }

  #if DEBUG && targetEnvironment(simulator)
    /// Sets up the app for App Store screenshot capture.
    /// Bypasses onboarding and auto-connects to simulator with mock data.
    @MainActor
    private func setupScreenshotMode() async {
      // Bypass onboarding
      appState.onboarding.hasCompletedOnboarding = true

      // Persist simulator device ID for auto-reconnect
      UserDefaults.standard.set(
        MockDataProvider.simulatorDeviceID.uuidString,
        forKey: PersistenceKeys.lastConnectedDeviceID
      )

      // Initialize app (will auto-connect to simulator device)
      await appState.initialize()
    }

  #elseif DEBUG
    @MainActor
    private func setupScreenshotMode() async {
      // Screenshot mode only works in simulator
      await appState.initialize()
    }
  #endif

  private func waitForProtectedData() async {
    guard !UIApplication.shared.isProtectedDataAvailable else { return }
    let notification = UIApplication.protectedDataDidBecomeAvailableNotification
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        for await _ in NotificationCenter.default.notifications(named: notification) {
          return
        }
      }
      group.addTask {
        while await !UIApplication.shared.isProtectedDataAvailable {
          try? await Task.sleep(for: .seconds(1))
        }
      }
      await group.next()
      group.cancelAll()
    }
  }

  private func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
    switch newPhase {
    case .active:
      Task {
        await appState.handleReturnToForeground()
      }
    case .background:
      appState.handleEnterBackground()
      // Flush the shared buffer, not services?.debugLogBuffer: while disconnected
      // (a failing reconnect is exactly that window) services is nil, and unflushed
      // entries die with the process if iOS terminates the suspended app.
      Task {
        await DebugLogBuffer.shared?.flush()
      }
    case .inactive:
      break
    @unknown default:
      break
    }
  }

  private func runInitialForegroundReconciliationIfNeeded() async {
    guard scenePhase == .active else { return }
    await appState.handleReturnToForeground()
  }
}
