import Foundation
@testable import MC1Services
import Testing

/// MessageServiceConfig guards against `maxAttempts > 4` via a precondition.
/// The firmware ACK hash masks the attempt index with `& 0x03`, so attempt 4
/// would repeat attempt 0's code, and a repeater that already relayed that code
/// drops it: a 5th send's confirmation can be lost even when the message
/// arrived. Swift Testing has no precondition matcher, so the failing case is
/// documented inline rather than asserted at runtime; the boundary case is
/// exercised here.
@Suite("MessageServiceConfig precondition")
struct MessageServiceConfigTests {
  @Test
  func `maxAttempts == 4 is accepted at the precondition boundary`() {
    let config = MessageServiceConfig(maxAttempts: 4)
    #expect(config.maxAttempts == 4)
  }

  @Test
  func `Default config respects the maxAttempts ceiling`() {
    let config = MessageServiceConfig()
    #expect(config.maxAttempts <= 4)
  }
}
