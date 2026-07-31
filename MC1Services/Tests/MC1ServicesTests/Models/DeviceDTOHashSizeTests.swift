import Foundation
@testable import MC1Services
import MeshCore
import Testing

@Suite("DeviceDTO hash sizes")
struct DeviceDTOHashSizeTests {
  @Test(arguments: [
    (mode: UInt8(0), hash: 1, trace: 1),
    (mode: UInt8(1), hash: 2, trace: 2),
    (mode: UInt8(2), hash: 3, trace: 3),
    // Mode 3 is reserved; the clamp keeps the prefix inside the 3-byte protocol maximum.
    (mode: UInt8(3), hash: 4, trace: 3),
  ])
  func `traceHashSize follows the mode plus one encoding, clamped to three bytes`(
    testCase: (mode: UInt8, hash: Int, trace: Int)
  ) {
    let device = DeviceDTO.testDevice().copy {
      $0.pathHashMode = testCase.mode
    }
    #expect(device.hashSize == testCase.hash)
    // Regression: `1 << pathHashMode` built a 4-byte prefix in 3-byte mode and broke traces
    // (legacy fix carried to v2). The width now comes from `PathEncoding.hashSize(forMode:)`,
    // which the trace parser splits replies with, so the two cannot drift apart again.
    #expect(device.traceHashSize == testCase.trace)
    #expect(device.traceHashSize == PathEncoding.hashSize(forMode: testCase.mode))
  }
}
