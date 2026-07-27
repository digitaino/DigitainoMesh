import Foundation
@testable import MC1Services
import Testing

/// Spec source: legacy `SignalBarsService.requestRefresh(targetHexID:)` / `startProbe()`,
/// which wrote `Data([action, target])` to `SYNC_ID_SIGNAL_BARS`.
///
/// Radios already in the field parse these two bytes, so the layout is frozen: these are
/// byte-exact assertions, not shape assertions.
@Suite("SignalBarsTrigger byte contract")
struct SignalBarsTriggerTests {
  @Test
  func `Action codes match the firmware's`() {
    #expect(SignalBarsTrigger.Action.refreshAll.rawValue == 0)
    #expect(SignalBarsTrigger.Action.pingTarget.rawValue == 1)
    #expect(SignalBarsTrigger.Action.discoveryProbe.rawValue == 2)
  }

  @Test
  func `Every trigger serializes to exactly two bytes of action and target`() throws {
    let cases: [(trigger: SignalBarsTrigger, bytes: [UInt8])] = try [
      (.refreshAll, [0x00, 0x00]),
      (.discoveryProbe, [0x02, 0x00]),
      (.ping(#require(NodeHexID("0C"))), [0x01, 0x0C]),
      (.ping(#require(NodeHexID("A5B6"))), [0x01, 0xA5]),
      (.ping(#require(NodeHexID("0c13ab"))), [0x01, 0x0C])
    ]
    for testCase in cases {
      #expect(
        testCase.trigger.payload == Data(testCase.bytes),
        "expected \(testCase.bytes) for \(testCase.trigger)"
      )
      #expect(testCase.trigger.payload.count == 2)
    }
  }

  @Test
  func `Only the first hash byte travels because that is the key the firmware matches on`() {
    let narrow = nodeID("0C")
    let wide = nodeID("0C13AB")
    #expect(SignalBarsTrigger.ping(narrow).payload == SignalBarsTrigger.ping(wide).payload)
  }

  @Test
  func `A refresh without a target is the refresh-all trigger`() {
    #expect(SignalBarsTrigger.refresh(target: nil).payload == Data([0x00, 0x00]))
    let target = nodeID("7F")
    #expect(SignalBarsTrigger.refresh(target: target).payload == Data([0x01, 0x7F]))
  }
}
