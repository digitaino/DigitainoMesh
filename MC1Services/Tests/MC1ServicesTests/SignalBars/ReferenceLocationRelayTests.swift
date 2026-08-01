import Foundation
@testable import MC1Services
import Testing

@Suite("ReferenceLocationRelay")
struct ReferenceLocationRelayTests {
  // Each 0.001° of latitude is ~111 m, so these fixtures step in known distances.
  private let origin = ReferenceCoordinate(latitude: 30.27, longitude: -97.74)

  @Test
  func `Starts with no coordinate`() async {
    let relay = ReferenceLocationRelay()
    #expect(await relay.currentReferenceCoordinate() == nil)
  }

  @Test
  func `The first fix is stored and significant`() async {
    let relay = ReferenceLocationRelay()

    #expect(await relay.update(origin))
    #expect(await relay.currentReferenceCoordinate() == origin)
  }

  @Test
  func `Drift below the threshold is stored but not significant`() async {
    let relay = ReferenceLocationRelay()
    await relay.update(origin)

    let drifted = ReferenceCoordinate(latitude: 30.271, longitude: -97.74)
    #expect(await relay.update(drifted) == false)
    // The freshest fix still wins for ranking; only the re-resolve is skipped.
    #expect(await relay.currentReferenceCoordinate() == drifted)
  }

  @Test
  func `Drift accumulates against the last announced fix, not the last push`() async {
    let relay = ReferenceLocationRelay()
    await relay.update(origin)

    // Two ~111 m steps, each below the threshold on its own—
    #expect(await relay.update(ReferenceCoordinate(latitude: 30.271, longitude: -97.74)) == false)
    #expect(await relay.update(ReferenceCoordinate(latitude: 30.272, longitude: -97.74)) == false)
    // —and the third crosses 250 m measured from the announced origin.
    #expect(await relay.update(ReferenceCoordinate(latitude: 30.273, longitude: -97.74)))
  }

  @Test
  func `A move beyond the threshold is significant and rebases the drift origin`() async {
    let relay = ReferenceLocationRelay()
    await relay.update(origin)

    let moved = ReferenceCoordinate(latitude: 30.30, longitude: -97.74)
    #expect(await relay.update(moved))
    // Small drift around the new spot is quiet again.
    #expect(await relay.update(ReferenceCoordinate(latitude: 30.301, longitude: -97.74)) == false)
  }
}
