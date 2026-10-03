import Foundation
@testable import MC1
import MC1Services
import Testing

/// docs/RADIO_SWAP.md, owner decision 2: a radio not yet set up from these records is offered
/// the copy once per arming; one already copied to is topped up quietly.
@Suite("RadioSwapPromptState")
@MainActor
struct RadioSwapPromptStateTests {
  private static let deviceID = UUID()

  private static func profile(capturedAt: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)) -> IdentityProfile {
    IdentityProfile(
      nodeName: "Digitaino",
      radio: MeshCoreNodeConfig.RadioSettings(
        frequency: 910_525, bandwidth: 62500, spreadingFactor: 7, codingRate: 5, txPower: 22
      ),
      latitude: 0,
      longitude: 0,
      other: MeshCoreNodeConfig.OtherSettings(),
      channels: [],
      capturedAt: capturedAt
    )
  }

  @Test
  func `A radio never set up from these records is offered the copy under the identity's name`() throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    let profile = Self.profile()

    #expect(harness.state.step(deviceID: Self.deviceID, swapGuard: .all, profile: profile) == .offer)
    harness.state.offer(deviceID: Self.deviceID, profile: profile)

    #expect(harness.state.pending?.identityName == "Digitaino")
  }

  @Test
  func `Nothing happens without an armed guard or without a profile`() throws {
    let harness = try Harness()
    defer { harness.tearDown() }

    #expect(harness.state.step(deviceID: Self.deviceID, swapGuard: [], profile: Self.profile()) == .none)
    #expect(harness.state.step(deviceID: Self.deviceID, swapGuard: .all, profile: nil) == .none)
  }

  @Test
  func `Once answered, the same arming is not offered again, but the next switch is`() throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    let first = Self.profile()

    harness.state.offer(deviceID: Self.deviceID, profile: first)
    harness.state.dismiss()
    #expect(harness.state.step(deviceID: Self.deviceID, swapGuard: .all, profile: first) == .none)

    let rearmed = Self.profile(capturedAt: first.capturedAt.addingTimeInterval(3600))
    #expect(harness.state.step(deviceID: Self.deviceID, swapGuard: .all, profile: rearmed) == .offer)
  }

  @Test
  func `A radio already copied to is topped up quietly instead of offered`() throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    harness.preferences.setCopiedRecordsToRadio(deviceID: Self.deviceID)

    #expect(harness.state.step(deviceID: Self.deviceID, swapGuard: .all, profile: Self.profile()) == .topUp)
  }

  @Test
  func `An offer the connection ended before it was answered comes back`() throws {
    let harness = try Harness()
    defer { harness.tearDown() }

    harness.state.offer(deviceID: Self.deviceID, profile: Self.profile())
    harness.state.endSession()

    #expect(harness.state.step(deviceID: Self.deviceID, swapGuard: .all, profile: Self.profile()) == .offer)
  }

  private struct Harness {
    let suiteName: String
    let defaults: UserDefaults
    let preferences: DevicePreferenceStore
    let state: RadioSwapPromptState

    @MainActor
    init() throws {
      let name = "RadioSwapPromptStateTests.\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: name))
      suiteName = name
      self.defaults = defaults
      preferences = DevicePreferenceStore(userDefaults: defaults)
      state = RadioSwapPromptState(store: preferences)
    }

    func tearDown() {
      defaults.removePersistentDomain(forName: suiteName)
    }
  }
}
