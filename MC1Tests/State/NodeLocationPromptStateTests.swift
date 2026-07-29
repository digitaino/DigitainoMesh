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
  private static let miami = CLLocation(latitude: 25.7617, longitude: -80.1918)
  private static let nearSanJuan = CLLocation(latitude: 18.4780, longitude: -66.1057)

  private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

  // MARK: - Presentation

  @Test
  func `Stale radio with a phone fix produces a pending prompt`() throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    let device = Self.makeDevice()

    harness.state.evaluate(device: device, phoneLocation: Self.miami, now: Self.now)

    let pending = try #require(harness.state.pending)
    #expect(pending.deviceID == device.id)
    #expect(pending.latitude == Self.miami.coordinate.latitude)
    #expect(pending.longitude == Self.miami.coordinate.longitude)
    #expect(pending.distanceMeters > NodeLocationStalenessPolicy.thresholdMeters)
  }

  @Test
  func `Nearby radio produces no prompt`() throws {
    let harness = try Harness()
    defer { harness.tearDown() }

    harness.state.evaluate(device: Self.makeDevice(), phoneLocation: Self.nearSanJuan, now: Self.now)

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

    harness.state.evaluate(device: nil, phoneLocation: Self.miami, now: Self.now)

    #expect(harness.state.pending == nil)
  }

  // MARK: - Session guard

  @Test
  func `A dismissed prompt is not re-offered in the same session`() throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    let device = Self.makeDevice()

    harness.state.evaluate(device: device, phoneLocation: Self.miami, now: Self.now)
    harness.state.clearPending()
    harness.state.evaluate(device: device, phoneLocation: Self.miami, now: Self.now)

    #expect(harness.state.pending == nil)
  }

  @Test
  func `A failed update re-offers on the next connect but writes no snooze`() throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    let device = Self.makeDevice()

    harness.state.evaluate(device: device, phoneLocation: Self.miami, now: Self.now)
    harness.state.markUpdateFailed()
    #expect(harness.state.failureTrigger == 1)
    #expect(harness.store.nodeLocationPromptSnoozedAt(deviceID: device.id) == nil)

    harness.state.endSession()
    harness.state.evaluate(device: device, phoneLocation: Self.miami, now: Self.now)

    #expect(harness.state.pending != nil)
  }

  @Test
  func `A successful update bumps the success trigger and clears the prompt`() throws {
    let harness = try Harness()
    defer { harness.tearDown() }

    harness.state.evaluate(device: Self.makeDevice(), phoneLocation: Self.miami, now: Self.now)
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

    harness.state.evaluate(device: device, phoneLocation: Self.miami, now: Self.now)
    harness.state.snoozeCurrent(now: Self.now)

    #expect(harness.state.pending == nil)
    #expect(harness.store.nodeLocationPromptSnoozedAt(deviceID: device.id) == Self.now)

    harness.state.endSession()
    harness.state.evaluate(
      device: device,
      phoneLocation: Self.miami,
      now: Self.now.addingTimeInterval(3 * 24 * 60 * 60)
    )

    #expect(harness.state.pending == nil)
  }

  @Test
  func `The snooze expires after a week`() throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    let device = Self.makeDevice()

    harness.state.evaluate(device: device, phoneLocation: Self.miami, now: Self.now)
    harness.state.snoozeCurrent(now: Self.now)
    harness.state.endSession()

    harness.state.evaluate(
      device: device,
      phoneLocation: Self.miami,
      now: Self.now.addingTimeInterval(NodeLocationStalenessPolicy.snoozeInterval + 1)
    )

    #expect(harness.state.pending != nil)
  }

  @Test
  func `A snooze on one radio does not silence another`() throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    let snoozed = Self.makeDevice()
    let other = Self.makeDevice()

    harness.state.evaluate(device: snoozed, phoneLocation: Self.miami, now: Self.now)
    harness.state.snoozeCurrent(now: Self.now)

    harness.state.evaluate(device: other, phoneLocation: Self.miami, now: Self.now)

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
