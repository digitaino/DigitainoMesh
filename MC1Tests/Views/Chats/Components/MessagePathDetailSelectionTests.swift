import Foundation
@testable import MC1
import Testing

@Suite("Message path detail selection")
struct MessagePathDetailSelectionTests {
  @Test
  func `resolvedSelection prefers the current id`() {
    let arrivals = makeArrivals(count: 3)
    let current = arrivals[1].id
    #expect(MessagePathArrivals.resolvedSelection(preferred: current, arrivals: arrivals) == current)
  }

  @Test
  func `resolvedSelection falls back to first when current vanishes`() {
    let arrivals = makeArrivals(count: 2)
    let vanished = UUID()
    #expect(
      MessagePathArrivals.resolvedSelection(preferred: vanished, arrivals: arrivals)
        == arrivals[0].id
    )
  }

  @Test
  func `resolvedSelection uses first when preferred is nil`() {
    let arrivals = makeArrivals(count: 2)
    #expect(
      MessagePathArrivals.resolvedSelection(preferred: nil, arrivals: arrivals)
        == arrivals[0].id
    )
  }

  @Test
  func `resolvedSelection is nil when arrivals are empty`() {
    #expect(MessagePathArrivals.resolvedSelection(preferred: UUID(), arrivals: []) == nil)
  }

  private func makeArrivals(count: Int) -> [MessagePathArrival] {
    (0..<count).map { index in
      MessagePathArrival(
        id: UUID(),
        pathNodes: Data([UInt8(index)]),
        pathLength: 1,
        snr: nil,
        rssi: nil,
        receivedAt: Date(timeIntervalSince1970: TimeInterval(index)),
        isFirst: index == 0
      )
    }
  }
}
