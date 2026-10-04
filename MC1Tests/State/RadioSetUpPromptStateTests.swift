import Foundation
@testable import MC1
import MC1Services
import Testing

/// docs/RADIO_SWAP.md flow B: only a blank radio is asked, and only about saved nodes that have
/// history here; "Use as a New Node" is remembered for that radio's key.
@Suite("Set up a blank radio")
@MainActor
struct RadioSetUpPromptStateTests {
  private static let blankKey = Data(repeating: 0x48, count: 32)
  private static let nodeKey = Data(repeating: 0xCC, count: 32)
  private static let goneKey = Data(repeating: 0x77, count: 32)
  private static let saved = [
    SavedIdentity(publicKey: blankKey, nodeName: "480A1F8A"),
    SavedIdentity(publicKey: nodeKey, nodeName: "Digitaino"),
    SavedIdentity(publicKey: goneKey, nodeName: "Old node")
  ]

  private static func candidates(
    radioHasHistory: Bool = false,
    keyCarriedByAnotherRadio: Bool = false,
    declinedKey: Data? = nil
  ) -> [SavedIdentity] {
    RadioSetUpPolicy.candidates(
      radioPublicKey: blankKey,
      radioHasHistory: radioHasHistory,
      keyCarriedByAnotherRadio: keyCarriedByAnotherRadio,
      declinedKey: declinedKey,
      saved: saved,
      hasRadioRow: { $0 != goneKey }
    )
  }

  @Test
  func `A blank radio is offered the saved nodes that have history here, never itself`() {
    #expect(Self.candidates().map(\.nodeName) == ["Digitaino"])
  }

  @Test
  func `A radio with its own history, or one of several radios carrying a node, is not asked`() {
    #expect(Self.candidates(radioHasHistory: true).isEmpty)
    #expect(Self.candidates(keyCarriedByAnotherRadio: true).isEmpty)
  }

  @Test
  func `A radio kept as a new node is not asked again while it keeps that key`() {
    #expect(Self.candidates(declinedKey: Self.blankKey).isEmpty)
    #expect(Self.candidates(declinedKey: Data(repeating: 0x01, count: 32)).map(\.nodeName) == ["Digitaino"])
  }

  @Test
  func `Use as a New Node is remembered, a swipe is not`() throws {
    let name = "RadioSetUpPromptStateTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let state = RadioSetUpPromptState(store: DevicePreferenceStore(userDefaults: defaults))
    let deviceID = UUID()
    let setUp = PendingRadioSetUp(
      deviceID: deviceID,
      radioName: "480A1F8A",
      radioPublicKey: Self.blankKey,
      candidates: [Self.saved[1]]
    )

    state.offer(setUp)
    state.close()
    #expect(state.declinedKey(deviceID: deviceID) == nil)

    state.offer(setUp)
    #expect(state.pending == setUp)
    state.decline()
    #expect(state.pending == nil)
    #expect(state.declinedKey(deviceID: deviceID) == Self.blankKey)
  }
}
