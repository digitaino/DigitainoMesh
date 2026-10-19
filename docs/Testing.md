# Testing

## Running Tests

### Xcode

Use the Test navigator (Cmd+6) or Cmd+U to run all tests.

### Command Line

Prefer the `make` targets; they take a per-simulator lock so concurrent sessions serialize instead of hanging:

```bash
make test-app    # full app suite on iOS 26 (StoreKit suites auto-skip here)
make test-store  # StoreKit/IAP SKTestSession suites on iOS 18.x
make test        # both of the above
```

To run a single suite or the SPM packages directly:

```bash
# App-layer tests (MC1Tests): project standard destination is iPhone 17e / iOS 26
xcodebuild test \
  -project MC1.xcodeproj \
  -scheme MC1 \
  -destination "platform=iOS Simulator,name=iPhone 17e,OS=26.5" \
  2>&1 | xcsift -f toon

# Services package tests
cd MC1Services && swift test 2>&1 | xcsift -f toon

# MeshCore package tests
cd MeshCore && swift test 2>&1 | xcsift -f toon
```

Use `xcsift` to get structured output. Add `-c` for code coverage or `-w` for a detailed warnings list. See CLAUDE.md for the full flag reference.

StoreKit/IAP suites run on iOS 18.x (iPhone 16e); SKTestSession serves no products under iOS 26 simulators. `make test-store` selects the iOS 18 destination automatically.

## Test Targets

| Target | Package | Framework | Scope |
|--------|---------|-----------|-------|
| `MC1Tests` | Xcode project | Swift Testing | ViewModels, AppState, views, models, utilities |
| `MC1ServicesTests` | MC1Services (SPM) | Swift Testing | Services, transport, persistence, connection management |
| `MeshCoreTests` | MeshCore (SPM) | Swift Testing | Protocol parsing, crypto, transport codecs |

**Framework**: Swift Testing (`@Suite`, `@Test`, `#expect`) is used throughout, including the byte-level protocol compatibility tests in `MeshCoreTests/Validation/` and `MeshCoreTests/Protocol/`.

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
| `DeviceDTO.testDevice()` | `MC1ServicesTests/Helpers/DeviceDTO+Testing.swift` | Factory with sensible defaults for building test fixtures |
| `SimulatorMockTransport` | `MC1Services/.../Simulator/SimulatorMockTransport.swift` | No-op `MeshTransport` for creating sessions without hardware |
| `PythonReferenceBytes` | `MeshCoreTests/Fixtures/PythonReferenceBytes.swift` | Static byte arrays from the Python reference implementation |

## Conventions

- **`@MainActor` on test suites**: Any test interacting with `AppState` or `ConnectionManager` annotates the `@Suite` or `@Test` with `@MainActor`.
- **App-layer tests** instantiate `AppState()` directly without mock injection.
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
