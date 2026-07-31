import Foundation
import Testing
@testable import SurveyKit

@Suite("RequestSigner")
struct RequestSignerTests {

    @Test func roundTripsAndRejectsTampering() {
        let key = "test-key"
        let body = Data("{\"cells\":[]}".utf8)
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let ts = String(Int(now.timeIntervalSince1970))
        let sig = RequestSigner.signature(key: key, timestamp: ts, body: body)

        #expect(RequestSigner.verify(key: key, timestamp: ts, body: body, signatureHex: sig, now: now))
        #expect(!RequestSigner.verify(key: "other", timestamp: ts, body: body, signatureHex: sig, now: now))
        #expect(!RequestSigner.verify(key: key, timestamp: ts, body: Data("x".utf8), signatureHex: sig, now: now))
        // Outside the replay window.
        let late = now.addingTimeInterval(RequestSigner.replayWindow + 1)
        #expect(!RequestSigner.verify(key: key, timestamp: ts, body: body, signatureHex: sig, now: late))
    }
}
