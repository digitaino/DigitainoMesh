import Crypto
import Foundation

/// v2.2 app authentication: proves "this request was produced by the PocketMesh app"
/// without identifying which install sent it. The same code signs on the client and
/// verifies on the server, so the scheme cannot drift.
///
/// Scheme: `X-Client-Sig = hex(HMAC-SHA256(key, timestamp ‖ "." ‖ body))` with
/// `X-Client-Ts = <unix seconds>`. The server rejects timestamps outside
/// `±replayWindow` and compares signatures in constant time.
///
/// An embedded key is extractable by a determined attacker — accepted and documented
/// (DESIGN.md §5). This raises the bar from "anyone with curl" to "someone who
/// reverse-engineered the binary," and rotation is an app update + env change.
public enum RequestSigner {
  public static let signatureHeader = "X-Client-Sig"
  public static let timestampHeader = "X-Client-Ts"
  public static let replayWindow: TimeInterval = 300

  public static func signature(key: String, timestamp: String, body: Data) -> String {
    var message = Data(timestamp.utf8)
    message.append(UInt8(ascii: "."))
    message.append(body)
    let mac = HMAC<SHA256>.authenticationCode(
      for: message,
      using: SymmetricKey(data: Data(key.utf8))
    )
    return mac.map { String(format: "%02x", $0) }.joined()
  }

  /// Constant-time verification. `now` is injected for testability.
  public static func verify(
    key: String,
    timestamp: String,
    body: Data,
    signatureHex: String,
    now: Date
  ) -> Bool {
    guard let ts = TimeInterval(timestamp),
          abs(now.timeIntervalSince1970 - ts) <= replayWindow
    else { return false }

    let expected = signature(key: key, timestamp: timestamp, body: body)
    // Constant-time comparison over the hex strings.
    let a = Array(expected.utf8)
    let b = Array(signatureHex.utf8)
    guard a.count == b.count else { return false }
    var difference: UInt8 = 0
    for i in 0..<a.count {
      difference |= a[i] ^ b[i]
    }
    return difference == 0
  }
}
