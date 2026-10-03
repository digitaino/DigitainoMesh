import Foundation
@testable import MC1
import MC1Services
import Testing

/// docs/RADIO_SWAP.md, owner decision 2: the copy is offered once per radio taking on an
/// identity, and only while its swap guard is armed with a stored profile.
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
  func `An armed guard with a profile offers the copy under the identity's name`() throws {
    let harness = try Harness()
    defer { harness.tearDown() }

    harness.state.evaluate(deviceID: Self.deviceID, swapGuard: .all, profile: Self.profile())

    #expect(harness.state.pending?.identityName == "Digitaino")
  }

  @Test
  func `Nothing is offered without an armed guard or without a profile`() throws {
    let harness = try Harness()
    defer { harness.tearDown() }

    harness.state.evaluate(deviceID: Self.deviceID, swapGuard: [], profile: Self.profile())
    #expect(harness.state.pending == nil)
    harness.state.evaluate(deviceID: Self.deviceID, swapGuard: .all, profile: nil)
    #expect(harness.state.pending == nil)
  }

  @Test
  func `Once answered, the same arming is not offered again, but a new one is`() throws {
    let harness = try Harness()
    defer { harness.tearDown() }
    let first = Self.profile()

    harness.state.evaluate(deviceID: Self.deviceID, swapGuard: .all, profile: first)
    harness.state.dismiss()
    harness.state.evaluate(deviceID: Self.deviceID, swapGuard: .all, profile: first)
    #expect(harness.state.pending == nil)

    let rearmed = Self.profile(capturedAt: first.capturedAt.addingTimeInterval(3600))
    harness.state.evaluate(deviceID: Self.deviceID, swapGuard: .all, profile: rearmed)
    #expect(harness.state.pending != nil)
  }

  @Test
  func `An offer the connection ended before it was answered comes back`() throws {
    let harness = try Harness()
    defer { harness.tearDown() }

    harness.state.evaluate(deviceID: Self.deviceID, swapGuard: .all, profile: Self.profile())
    harness.state.endSession()
    harness.state.evaluate(deviceID: Self.deviceID, swapGuard: .all, profile: Self.profile())

    #expect(harness.state.pending != nil)
  }

  private struct Harness {
    let suiteName: String
    let defaults: UserDefaults
    let state: RadioSwapPromptState

    @MainActor
    init() throws {
      let name = "RadioSwapPromptStateTests.\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: name))
      suiteName = name
      self.defaults = defaults
      state = RadioSwapPromptState(store: DevicePreferenceStore(userDefaults: defaults))
    }

    func tearDown() {
      defaults.removePersistentDomain(forName: suiteName)
    }
  }
}
