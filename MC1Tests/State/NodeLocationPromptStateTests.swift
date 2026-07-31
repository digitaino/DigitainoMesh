import CoreLocation
import Foundation
@testable import MC1
import MC1Services
import Testing

@Suite("NodeLocationPromptState")
@MainActor
struct NodeLocationPromptStateTests {
  /// San Juan, Puerto Rico — the radio's stale advert location in the motivating bug.
  private static let sanJuanDevice = (latitude: 18.4655, longitude: -66.1057)
  // Miami, FL — ~1,660 km away, far past the 50 mi threshold.
  private static let miami = CLLocationCoordinate2D(latitude: 25.7617, longitude: -80.1918)
  private static let nearSanJuan = CLLocationCoordinate2D(latitude: 18.4780, longitude: -66.1057)

  private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

  /// A phone fix at `coordinate`, dated `takenAt`. Fixes are dated explicitly because a fix
  /// older than ``NodeLocationStalenessPolicy/maxFixAge`` counts as no fix at all, and
  /// `CLLocation(latitude:longitude:)` would stamp the wall clock instead of this clock.
  private static func fix(_ coordinate: CLLocationCoordinate2D, takenAt: Date = now) -> CLLocation {
    CLLocation(
      coordinate: coordinate,
      altitude: 0,
      horizontalAccuracy: 10,
      verticalAccuracy: -1,
      timestamp: takenAt
    )
  }

  // MARK: - Presentation

  @Test
  func `Stale radio with a phone fix produces a pending prompt`() throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    let device = Self.makeDevice()

    harness.state.evaluate(device: device, phoneLocation: Self.fix(Self.miami), now: Self.now)

    let pending = try #require(harness.state.pending)
    #expect(pending.deviceID == device.id)
    #expect(pending.latitude == Self.miami.latitude)
    #expect(pending.longitude == Self.miami.longitude)
    #expect(pending.distanceMeters > NodeLocationStalenessPolicy.thresholdMeters)
  }

  @Test
  func `Nearby radio produces no prompt`() throws {
    let harness = try Harness()
    defer { harness.tearDown() }

    harness.state.evaluate(device: Self.makeDevice(), phoneLocation: Self.fix(Self.nearSanJuan), now: Self.now)

    #expect(harness.state.pending == nil)
  }

  @Test
  func `No phone fix produces no prompt`() throws {
    let harness = try Harness()
    defer { harness.tearDown() }

    harness.state.evaluate(device: Self.makeDevice(), phoneLocation: nil, now: Self.now)

    #expect(harness.state.pending == nil)
  }

  @Test
  func `Disconnected state produces no prompt`() throws {
    let harness = try Harness()
    defer { harness.tearDown() }

    harness.state.evaluate(device: nil, phoneLocation: Self.fix(Self.miami), now: Self.now)

    #expect(harness.state.pending == nil)
  }

  @Test
  func `A prompt carries the date of the fix behind it`() throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    let takenAt = Self.now.addingTimeInterval(-60)

    harness.state.evaluate(
      device: Self.makeDevice(),
      phoneLocation: Self.fix(Self.miami, takenAt: takenAt),
      now: Self.now
    )

    #expect(try #require(harness.state.pending).fixDate == takenAt)
  }

  // MARK: - Fix age

  @Test
  func `A fix too old to write produces no prompt and asks for a fresh one`() throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    let aged = Self.fix(
      Self.miami,
      takenAt: Self.now.addingTimeInterval(-NodeLocationStalenessPolicy.maxFixAge - 1)
    )

    let needsFreshFix = harness.state.evaluate(
      device: Self.makeDevice(),
      phoneLocation: aged,
      now: Self.now
    )

    #expect(needsFreshFix)
    #expect(harness.state.pending == nil)
  }

  @Test
  func `The fresh-fix request is made once per session`() throws {
    // Every arriving fix re-enters `evaluate`, and an aged one leaves the condition true, so
    // the request has to be one-shot or a phone answering with the same cached fix spins.
    let harness = try Harness()
    defer { harness.tearDown() }
    let device = Self.makeDevice()
    let aged = Self.fix(
      Self.miami,
      takenAt: Self.now.addingTimeInterval(-NodeLocationStalenessPolicy.maxFixAge - 1)
    )

    #expect(harness.state.evaluate(device: device, phoneLocation: aged, now: Self.now))
    #expect(!harness.state.evaluate(device: device, phoneLocation: aged, now: Self.now))

    harness.state.endSession()

    #expect(harness.state.evaluate(device: device, phoneLocation: aged, now: Self.now))
  }

  @Test
  func `A fresh fix arriving after an aged one prompts`() throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    let device = Self.makeDevice()

    harness.state.evaluate(
      device: device,
      phoneLocation: Self.fix(Self.miami, takenAt: Self.now.addingTimeInterval(-3600)),
      now: Self.now
    )
    let needsFreshFix = harness.state.evaluate(
      device: device,
      phoneLocation: Self.fix(Self.miami),
      now: Self.now
    )

    #expect(!needsFreshFix)
    #expect(harness.state.pending != nil)
  }

  @Test
  func `A radio with no configured location never asks for a fix`() throws {
    let harness = try Harness()
    defer { harness.tearDown() }

    // Null island is `hasLocation == false`: nothing to correct, so nothing to correct it with.
    let needsFreshFix = harness.state.evaluate(
      device: Self.makeDevice(latitude: 0, longitude: 0),
      phoneLocation: nil,
      now: Self.now
    )

    #expect(!needsFreshFix)
  }

  // MARK: - Session guard

  @Test
  func `A dismissed prompt is not re-offered in the same session`() throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    let device = Self.makeDevice()

    harness.state.evaluate(device: device, phoneLocation: Self.fix(Self.miami), now: Self.now)
    harness.state.clearPending()
    harness.state.evaluate(device: device, phoneLocation: Self.fix(Self.miami), now: Self.now)

    #expect(harness.state.pending == nil)
  }

  @Test
  func `A failed update re-offers on the next connect but writes no snooze`() throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    let device = Self.makeDevice()

    harness.state.evaluate(device: device, phoneLocation: Self.fix(Self.miami), now: Self.now)
    harness.state.markUpdateFailed()
    #expect(harness.state.failureTrigger == 1)
    #expect(harness.store.nodeLocationPromptSnoozedAt(deviceID: device.id) == nil)

    harness.state.endSession()
    harness.state.evaluate(device: device, phoneLocation: Self.fix(Self.miami), now: Self.now)

    #expect(harness.state.pending != nil)
  }

  @Test
  func `A successful update bumps the success trigger and clears the prompt`() throws {
    let harness = try Harness()
    defer { harness.tearDown() }

    harness.state.evaluate(device: Self.makeDevice(), phoneLocation: Self.fix(Self.miami), now: Self.now)
    harness.state.markUpdateSucceeded()

    #expect(harness.state.successTrigger == 1)
    #expect(harness.state.pending == nil)
  }

  // MARK: - Snooze

  @Test
  func `Not Now persists a per-device snooze that suppresses the next connect`() throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    let device = Self.makeDevice()

    harness.state.evaluate(device: device, phoneLocation: Self.fix(Self.miami), now: Self.now)
    harness.state.snoozeCurrent(now: Self.now)

    #expect(harness.state.pending == nil)
    #expect(harness.store.nodeLocationPromptSnoozedAt(deviceID: device.id) == Self.now)

    harness.state.endSession()
    let threeDaysOn = Self.now.addingTimeInterval(3 * 24 * 60 * 60)
    harness.state.evaluate(
      device: device,
      phoneLocation: Self.fix(Self.miami, takenAt: threeDaysOn),
      now: threeDaysOn
    )

    #expect(harness.state.pending == nil)
  }

  @Test
  func `The snooze expires after a week`() throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    let device = Self.makeDevice()

    harness.state.evaluate(device: device, phoneLocation: Self.fix(Self.miami), now: Self.now)
    harness.state.snoozeCurrent(now: Self.now)
    harness.state.endSession()

    let weekOn = Self.now.addingTimeInterval(NodeLocationStalenessPolicy.snoozeInterval + 1)
    harness.state.evaluate(
      device: device,
      phoneLocation: Self.fix(Self.miami, takenAt: weekOn),
      now: weekOn
    )

    #expect(harness.state.pending != nil)
  }

  @Test
  func `A snooze on one radio does not silence another`() throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    let snoozed = Self.makeDevice()
    let other = Self.makeDevice()

    harness.state.evaluate(device: snoozed, phoneLocation: Self.fix(Self.miami), now: Self.now)
    harness.state.snoozeCurrent(now: Self.now)

    harness.state.evaluate(device: other, phoneLocation: Self.fix(Self.miami), now: Self.now)

    #expect(harness.state.pending?.deviceID == other.id)
  }

  // MARK: - Helpers

  /// Isolated `UserDefaults` suite plus a state bound to it. `tearDown` is registered by
  /// `Harness()`'s caller through `defer`, matching `DevicePreferenceStoreTests`.
  private struct Harness {
    let suiteName: String
    let defaults: UserDefaults
    let store: DevicePreferenceStore
    let state: NodeLocationPromptState

    @MainActor
    init() throws {
      let name = "NodeLocationPromptStateTests.\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: name))
      let store = DevicePreferenceStore(userDefaults: defaults)
      suiteName = name
      self.defaults = defaults
      self.store = store
      state = NodeLocationPromptState(store: store)
    }

    func tearDown() {
      defaults.removePersistentDomain(forName: suiteName)
    }
  }

  private static func makeDevice(
    latitude: Double = sanJuanDevice.latitude,
    longitude: Double = sanJuanDevice.longitude
  ) -> DeviceDTO {
    DeviceDTO(
      id: UUID(),
      publicKey: Data(repeating: 0xBB, count: 32),
      nodeName: "TestNode",
      firmwareVersion: 1,
      firmwareVersionString: "1.12.0",
      manufacturerName: "Test",
      buildDate: "2025-01-01",
      maxContacts: 100,
      maxChannels: 8,
      frequency: 915_000,
      bandwidth: 250_000,
      spreadingFactor: 10,
      codingRate: 5,
      txPower: 20,
      maxTxPower: 20,
      latitude: latitude,
      longitude: longitude,
      blePin: 0,
      manualAddContacts: false,
      multiAcks: 2,
      telemetryModeBase: 2,
      telemetryModeLoc: 0,
      telemetryModeEnv: 0,
      advertLocationPolicy: 0,
      lastConnected: Date(),
      lastContactSync: 0,
      isActive: true,
      ocvPreset: nil,
      customOCVArrayString: nil
    )
  }
}
