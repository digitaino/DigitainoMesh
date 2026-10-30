# Testing

## Running Tests

### Xcode

Use the Test navigator (Cmd+6) or Cmd+U to run all tests.

### Command Line

Prefer the `make` targets; they take a per-simulator lock so concurrent sessions serialize instead of hanging:

```bash
make test-app    # full app suite on iPhone 17e / iOS 27.0
make test-store  # StoreKit/IAP SKTestSession suites on iOS 18.x
make test        # both of the above
```

The full app suite can take several minutes. `xcsift` prints its summary when the run ends. The periodic elapsed-time messages do not show whether tests are still making progress. Save the raw log when investigating a slow or stuck run:

```bash
mkdir -p tmp
make test-app XCSIFT_WITH_HEARTBEAT='tee tmp/test-app-raw.log | xcsift -f toon'
```

Check the command's exit status and Xcode's test summary in the raw log. `xcsift` can report zero failures even when a Swift Testing assertion failed. Look in the `.xcresult` bundle for failure details.

Pass filters, repetition settings, or a result-bundle path through `XCODEBUILD_TEST_ARGS`:

```bash
make test-app XCODEBUILD_TEST_ARGS='-only-testing:MC1Tests/LifecycleTransitionTests -test-iterations 5'
```

App tests run one at a time. Parallel testing is disabled in both the generated scheme and the make targets because several suites share the key window and keyboard. `@MainActor` and `.serialized` on a suite still allow other suites to run while a test is suspended. Keep parallel testing disabled for the full app suite.

Run the SPM packages from the repository root, with parallel testing disabled as it is in CI:

```bash
set -o pipefail

# Services package tests
swift test --package-path MC1Services --no-parallel 2>&1 | xcsift -f toon

# MeshCore package tests
swift test --package-path MeshCore --no-parallel 2>&1 | xcsift -f toon
```

Use `xcsift` to get structured output. Add `-c` for code coverage or `-w` for a detailed warnings list. See CLAUDE.md for the full flag reference.

The Build workflow runs both SPM package suites and builds the app for the iOS Simulator. GitHub CI does not run the app or StoreKit test suites for now. Run those locally with the make targets above.

For a local app test run that saves logs and an `.xcresult` bundle, use `scripts/test-app-ci.py`. It runs `make test-app` on iPhone 17e / iOS 27.0 and reuses `.derivedData`.

The script allows 12 minutes for building and testing. If the run exceeds that limit, it saves a process list and short stack samples to help diagnose the stall. It samples the test host only when it can identify it unambiguously on the pinned simulator. It then interrupts Xcode, gives it time to save results, and stops the process group it started. Failed runs are not retried.

The output directory contains `xcodebuild.log`, `runner.log`, `status.json`, the `.xcresult` bundle, and any stall diagnostics that were saved. If the process stops abruptly, these files may be incomplete. Choose a new output directory for each run:

```bash
python3 scripts/test-app-ci.py --artifacts tmp/app-ci-local
python3 -m unittest discover -s scripts/tests -v
```

StoreKit/IAP suites run on iOS 18.x (iPhone 16e); SKTestSession serves no products under iOS 26 simulators. `make test-store` selects the iOS 18 destination automatically.

## Test Targets

| Target | Package | Framework | Scope |
|--------|---------|-----------|-------|
| `MC1Tests` | Xcode project | Swift Testing | ViewModels, AppState, views, models, utilities |
| `MC1ServicesTests` | MC1Services (SPM) | Swift Testing | Services, transport, persistence, connection management |
| `MeshCoreTests` | MeshCore (SPM) | Swift Testing | Protocol parsing, crypto, transport codecs |

All test targets use Swift Testing (`@Suite`, `@Test`, `#expect`), including the byte-level protocol compatibility tests in `MeshCoreTests/Validation/` and `MeshCoreTests/Protocol/`. The keyboard and scroll suites cover these 25 cases:

| Suite | Cases | What it tests |
|-------|-------|-------------------|
| `NativeViewportScrollPreservationTests` | 13 | Keeping the bottom or reading position visible as the viewport, insets, composer, rows, or layout change; dragging, deceleration, and scroll offset limits |
| `ChatKeyboardTransitionTests` | 5 | Keyboard alignment, tall rows staying visible, initial and saved reading positions, and focusing the composer near the bottom |
| `ChatKeyboardTransitionClassificationTests` | 3 | Distinguishing modal, interactive navigation, and noninteractive navigation transitions |
| `ChatKeyboardSheetDismissalTests` | 3 | Focus and keyboard behavior when a sheet closes |
| `ChatChannelKeyboardTypingTests` | 1 | Typing in the channel composer used by the app |

The three transition-classification cases run as separate inputs to one parameterized test.

Transition tests attach `samples.json`, `notifications.json`, and all captured PNGs to the test results. Viewport tests attach text and images when they fail. Each test cleans up the state it creates: restoring windows and controllers, dismissing the keyboard, stopping recorders, and shutting down test instances of `AppState`.

When a test waits for SwiftUI to lay out a change, use `await` and check the rendered size or position until a deadline. A synchronous nested `RunLoop` can prevent pending `MainActor` work from running. The row-growth test checks the reading position while it waits for the new row height, then makes its final assertions.

## Mock Patterns

Mocks are **protocol-based Swift actors** with a consistent structure:

```swift
public actor MockChannelService: ChannelServiceProtocol {
    // MARK: - Stubs
    public var stubbedChannels: [Channel] = []

    // MARK: - Recorded Invocations
    public private(set) var fetchChannelsInvocations: [Void] = []

    // MARK: - Protocol Methods
    public func fetchChannels() async throws -> [Channel] {
        fetchChannelsInvocations.append(())
        return stubbedChannels
    }

    // MARK: - Test Helpers
    public func reset() { ... }
}
```

- **Stubs** (`stubbedXxx`) provide configurable return values
- **Invocation arrays** (`xxxInvocations`) record every call for assertion
- **`reset()`** clears recorded state between tests
- Actor isolation provides thread safety under strict concurrency

Protocol-based mock actors live in `MC1ServicesTests/Mocks/`; app-layer test doubles are defined inline alongside the tests that use them in `MC1Tests/`.

## ServiceContainer.forTesting()

Creates the full service graph backed by in-memory SwiftData storage:

```swift
let transport = SimulatorMockTransport()
let session = MeshCoreSession(transport: transport)
let container = try await ServiceContainer.forTesting(session: session)
```

- Uses `PersistenceStore.createContainer(inMemory: true)` for zero disk I/O
- Takes an optional `radioID` (default: synthesized `UUID()`) to scope the per-radio stores
- Cross-service callbacks are established by `ServiceContainer.init`; `ServiceContainerWiringTests` verifies those connections via `forTesting()`
- `SimulatorMockTransport` is a production actor (`Simulator/SimulatorMockTransport.swift`) that satisfies `MeshTransport` with no-op operations

## Test Utilities

| Utility | Location | Purpose |
|---------|----------|---------|
| `MutableBox<T>` | `MC1Tests/Helpers/TestHelpers.swift` | Captures mutable values in async closures under strict concurrency |
| `TestClock` | `MeshCore/Tests/MeshCoreTestSupport/TestClock.swift` | Advances virtual time for MeshCore and MC1Services tests using an injected `Clock` |
| `DeviceDTO.testDevice()` | `MC1ServicesTests/Helpers/DeviceDTO+Testing.swift` | Factory with sensible defaults for building test fixtures |
| `SimulatorMockTransport` | `MC1Services/.../Simulator/SimulatorMockTransport.swift` | No-op `MeshTransport` for creating sessions without hardware |
| `PythonReferenceBytes` | `MeshCoreTests/Fixtures/PythonReferenceBytes.swift` | Static byte arrays from the Python reference implementation |

For delays and timeouts, inject a `Clock`. Before advancing a `TestClock`, check `sleeperCount` to confirm the code has started waiting. For event ordering, subscribe before sending events. For task ordering, wait for a signal that the relevant work has started or finished. A sleep or `Task.yield()` does not prove another task is ready. Use real-time deadlines when waiting for external systems or detecting stuck test setup.

## Conventions

- **`@MainActor` on test suites**: Any test interacting with `AppState` or `ConnectionManager` annotates the `@Suite` or `@Test` with `@MainActor`.
- **App-layer tests** instantiate `AppState` directly. Tests that change preferences pass an isolated `UserDefaults` suite and call `shutdown()` before cleaning it up.
- **Service-layer tests** use `ServiceContainer.forTesting()` or inject individual mock actors.
- **MeshCore tests** are self-contained with no external dependencies.

## File Organization

```
MC1Tests/
├── AppState/          # AppState sub-object tests
├── Extensions/        # Data extensions, battery info, error dispatch
├── Formatters/        # Message path formatting
├── Helpers/           # MutableBox and other test utilities
├── Localization/      # Localized label tests
├── Models/            # Data model tests
├── Protocol/          # CLI response, LPP display
├── Services/          # Elevation, preview cache, image detection
├── State/             # Message event stream, send queue
├── Theme/             # Theme structure and contrast
├── Utilities/         # Demo mode, mention utilities, scroll policies
├── ViewModels/        # ViewModel unit tests
└── Views/             # View-level logic tests

MC1ServicesTests/
├── Connection/        # Connection model/store tests
├── Helpers/           # Test fixture builders
├── Mocks/             # Protocol-based mock actors
├── Models/            # DTO and connection model tests
├── Services/          # Per-service unit tests
├── Transport/         # BLE phase and state machine tests
├── Utilities/         # Device identity, hashtag utilities
└── (root)             # ServiceContainer wiring, sync coordinator tests

MeshCoreTests/
├── Events/            # EventDispatcher and filter tests
├── Fixtures/          # Reference byte arrays
├── Helpers/           # Polling and other test utilities
├── Protocol/          # PacketBuilder command tests
├── Session/           # Session timeout and lifecycle tests
├── Transport/         # WiFi codec and transport tests
└── Validation/        # Byte-level protocol tests
```

## Weather UI tests on the phone (`MC1UITests`)

XCUITests that drive the Weather tool on a **real iPhone with a real radio**, against the app
exactly as it stands on that phone. They are launched by hand, never by `make test`: they live in
their own `MC1UITests` scheme, so the `MC1` scheme's Test action is still the unit suite alone.

> **These tests never change the owner's data beyond a place they created themselves.** The only
> writer is `WeatherPlacesRoundTrip`, which adds "Llano, TX" and then removes it — and skips the
> whole test if Llano is already saved. No bell is turned off, no saved place is deleted, no
> setting is touched. `WeatherUpdateLive` spends airtime, once: a single tap on Update.

| Test | What it does |
|------|--------------|
| `WeatherPagerSmoke` | Opens Tools → Weather, swipes through every page, screenshots each, asserts each page is named and carries the bottom toolbar (Places and Update). Asks the radio for nothing. |
| `WeatherDrillInsStayOnPage` | From a non-first page: the station (via the honesty line), the forecast discussion, the radio page. Asserts the station screen names that page's place and that every drill-in returns to the same page. |
| `WeatherUpdateLive` | **One** request. Taps Update on My location, waits up to 60 s for the caption to settle ("… answered at …", "No answer at …", "Everything is current"), screenshots before and after. |
| `WeatherPlacesRoundTrip` | Adds "Llano, TX" by search, confirms the page appeared, removes it by swiping the row, confirms the page is gone. Skips if Llano is already saved. |
| `WeatherNotificationsScreen` | Radio row → Alert notifications, screenshot, back out. Changes nothing. |

### The two commands

Build the runner for the phone (UDID `00008130-001964611E43001C`):

```bash
xcodebuild build-for-testing \
  -project MC1.xcodeproj \
  -scheme MC1UITests \
  -destination 'platform=iOS,id=00008130-001964611E43001C' \
  -derivedDataPath build/uitests-device \
  -allowProvisioningUpdates
```

Run it (unlock the phone first; add `-only-testing:` to pick one test):

```bash
xcodebuild test-without-building \
  -project MC1.xcodeproj \
  -scheme MC1UITests \
  -destination 'platform=iOS,id=00008130-001964611E43001C' \
  -derivedDataPath build/uitests-device \
  -resultBundlePath build/weather-ui.xcresult \
  -only-testing:MC1UITests/WeatherPagerSmoke \
  -allowProvisioningUpdates
```

Inside the tool the app's tab bar is hidden (docs/MESHWX_UI.md §4), so a run that starts on a
weather screen finds no Tools tab; the driver recognises the pager and carries on. On iOS 26 the
glass toolbar buttons report no hit point, so the driver taps the centre of a button's frame.

`WEATHER_UI_ACTIVATE=1` — passed as `TEST_RUNNER_WEATHER_UI_ACTIVATE=1` on either line — foregrounds
a running app instead of relaunching it, which keeps the Bluetooth session alive between tests.
Without it each test relaunches the app and the radio reconnects (`WeatherUpdateLive` waits up to
30 s for that before it decides Update is disabled).

### Where the screenshots land

Every `snap` is **attached to the result bundle** and **written as a PNG**. The run prints its own
directory as the first line of the log (`WXUI| screenshots -> …`), together with a `run.log` and,
where a test dumps one, the whole accessibility tree as `*.tree.txt`.

* **From the `.xcresult`** — the way to get them off the phone:

  ```bash
  xcrun xcresulttool export attachments \
    --path build/weather-ui.xcresult \
    --output-path build/weather-ui-shots
  ```

* **Straight from disk** — on a simulator the runner's `Documents` is a folder on this Mac, so the
  printed path opens as it is:
  `~/Library/Developer/CoreSimulator/Devices/<UDID>/data/Containers/Data/Application/<runner>/Documents/WeatherUIShots/<test>-<timestamp>/`.
  Set `TEST_RUNNER_WEATHER_UI_SHOT_DIR=/some/dir` to send them somewhere else when the sandbox
  allows it; the run says which directory it actually used.

### In the simulator

The same scheme runs on the project's iPhone 17e, against whatever that simulator holds:

```bash
xcodebuild build-for-testing -project MC1.xcodeproj -scheme MC1UITests \
  -destination 'platform=iOS Simulator,name=iPhone 17e' CODE_SIGNING_ALLOWED=NO

xcodebuild test-without-building -project MC1.xcodeproj -scheme MC1UITests \
  -destination 'platform=iOS Simulator,name=iPhone 17e' \
  -only-testing:MC1UITests/WeatherPagerSmoke CODE_SIGNING_ALLOWED=NO
```

A simulator has no radio, so `WeatherUpdateLive` skips there (Update is blocked), and
`WeatherDrillInsStayOnPage` skips when only one page is saved.

### Known limitation: swipe-to-delete in Places

`WeatherPlacesRoundTrip`'s removal step could **not** be made to work in the iPhone 17e simulator
(iOS 27 beta). A Places row is a `Button` filling the whole list cell, and every synthesised
horizontal drag that starts anywhere on that cell — `swipeLeft()`, slow drags, drags from the cell's
top or bottom strip — fires the button as a *tap* instead: the place is picked and Places closes.
Drags that start in the strip beside the bell do nothing at all, because that strip is inside the
screen's own edge-pan area. The same drags page the `TabView` perfectly, so events are being
delivered; it is `.swipeActions` on this row that never wins. (Note the mirror image of this fight
in docs/MESHWX_UI.md §3.1 U-4, where `onDelete` lost to `onMove`'s drag.)

The test therefore tries `swipeLeft()` twice and a slow drag twice before giving up, and **says so
in the failure**. It is untested on the phone — if it works there, this note can go.

**If that step fails, "Llano, TX" is left saved.** Remove it by hand: Places → swipe the row →
Remove. Nothing else the test did needs undoing.

### Driving the tool from a test

`MC1UITests/Support/WeatherDriver.swift` holds the launch, wait, swipe, screenshot and
tree-dump helpers; `MC1UITests/Support/WeatherUIIdentifiers.swift` mirrors the
`.accessibilityIdentifier(…)` calls in `MC1/Views/Tools/Weather/` — a UI test bundle does not link
the app, so it cannot read `L10n` or the app's own constants. **Change one and change the other.**

Two things the driver knows that are easy to get wrong:

* **Never swipe down on a place page.** A downward swipe at the top of one is pull-to-refresh, and
  that spends airtime. `reveal` only ever scrolls a page downwards; tests walk a page top to bottom.
* **An identifier on a SwiftUI container is handed down to its children**, overwriting theirs. That
  is why the tool's bar carries no identifier of its own and is found as its two buttons instead.
