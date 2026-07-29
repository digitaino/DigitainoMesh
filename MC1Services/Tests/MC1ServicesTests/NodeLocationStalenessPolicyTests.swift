import CoreLocation
import Foundation
@testable import MC1Services
import Testing

@Suite("NodeLocationStalenessPolicy")
struct NodeLocationStalenessPolicyTests {
  /// San Juan, Puerto Rico — the radio's stale advert location in the motivating bug.
  private static let sanJuan = (latitude: 18.4655, longitude: -66.1057)
  /// Miami, FL — ~1,660 km away, far past the 50 mi threshold.
  private static let miami = CLLocationCoordinate2D(latitude: 25.7617, longitude: -80.1918)
  /// ~1.5 km from San Juan: well inside the threshold.
  private static let nearSanJuan = CLLocationCoordinate2D(latitude: 18.4780, longitude: -66.1057)

  private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

  private func evaluate(
    device: (latitude: Double, longitude: Double) = sanJuan,
    hasLocation: Bool = true,
    phone: CLLocationCoordinate2D? = miami,
    lastSnoozedAt: Date? = nil,
    now: Date = now
  ) -> NodeLocationStalenessPolicy.Decision {
    NodeLocationStalenessPolicy.evaluate(
      deviceLatitude: device.latitude,
      deviceLongitude: device.longitude,
      deviceHasLocation: hasLocation,
      phoneCoordinate: phone,
      lastSnoozedAt: lastSnoozedAt,
      now: now
    )
  }

  // MARK: - Threshold

  @Test
  func `Radio a thousand miles from the phone prompts`() throws {
    let decision = evaluate()
    // San Juan to Miami is roughly 1,660 km.
    let distance = try #require(decision.promptDistanceMeters)
    #expect(distance > 1_600_000)
    #expect(distance < 1_700_000)
  }

  @Test
  func `Radio within the threshold does not prompt`() {
    let decision = evaluate(phone: Self.nearSanJuan)
    #expect(decision.promptDistanceMeters == nil)
    guard case let .skip(.withinThreshold(distance)) = decision else {
      Issue.record("Expected .withinThreshold, got \(decision)")
      return
    }
    #expect(distance < NodeLocationStalenessPolicy.thresholdMeters)
  }

  @Test
  func `Distance just under 50 miles does not prompt, just over does`() {
    // One degree of latitude is ~111.32 km; walk north from the equator so the
    // meridian arc is the whole distance.
    let equator = (latitude: 0.0, longitude: 0.0)
    let metersPerDegree = 111_320.0
    let underDegrees = (NodeLocationStalenessPolicy.thresholdMeters - 2000) / metersPerDegree
    let overDegrees = (NodeLocationStalenessPolicy.thresholdMeters + 2000) / metersPerDegree

    let under = evaluate(
      device: equator,
      phone: CLLocationCoordinate2D(latitude: underDegrees, longitude: 0)
    )
    let over = evaluate(
      device: equator,
      phone: CLLocationCoordinate2D(latitude: overDegrees, longitude: 0)
    )

    #expect(under.promptDistanceMeters == nil)
    #expect(over.promptDistanceMeters != nil)
  }

  @Test
  func `Threshold constant is 50 miles`() {
    let miles = Measurement(value: NodeLocationStalenessPolicy.thresholdMeters, unit: UnitLength.meters)
      .converted(to: .miles).value
    #expect(abs(miles - 50) < 0.001)
  }

  // MARK: - Missing inputs

  @Test
  func `No phone fix does not prompt`() {
    #expect(evaluate(phone: nil) == .skip(.noPhoneFix))
  }

  @Test
  func `Null-island phone fix counts as no fix`() {
    let nullIsland = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    #expect(evaluate(phone: nullIsland) == .skip(.noPhoneFix))
  }

  @Test
  func `Device without a configured location does not prompt`() {
    #expect(evaluate(hasLocation: false) == .skip(.deviceHasNoLocation))
  }

  @Test
  func `Device without a location wins over a missing phone fix`() {
    // Reason ordering matters for the log line: nothing to correct beats nothing to correct with.
    #expect(evaluate(hasLocation: false, phone: nil) == .skip(.deviceHasNoLocation))
  }

  // MARK: - Snooze

  @Test
  func `Fresh snooze suppresses the prompt`() {
    let snoozedAt = Self.now.addingTimeInterval(-2 * 24 * 60 * 60)
    let decision = evaluate(lastSnoozedAt: snoozedAt)
    let expiry = snoozedAt.addingTimeInterval(NodeLocationStalenessPolicy.snoozeInterval)
    #expect(decision == .skip(.snoozed(until: expiry)))
  }

  @Test
  func `Expired snooze re-asks`() {
    let snoozedAt = Self.now.addingTimeInterval(-NodeLocationStalenessPolicy.snoozeInterval - 1)
    #expect(evaluate(lastSnoozedAt: snoozedAt).promptDistanceMeters != nil)
  }

  @Test
  func `Snooze interval is one week`() {
    #expect(NodeLocationStalenessPolicy.snoozeInterval == 604_800)
  }

  @Test
  func `A snoozed but non-stale radio reports withinThreshold, not snoozed`() {
    let decision = evaluate(phone: Self.nearSanJuan, lastSnoozedAt: Self.now)
    guard case .skip(.withinThreshold) = decision else {
      Issue.record("Expected .withinThreshold, got \(decision)")
      return
    }
  }

  // MARK: - Formatting

  @Test
  func `Distance formats in miles for a US locale and kilometers for a metric one`() {
    let meters = 80467.2
    let us = NodeLocationStalenessPolicy.formattedDistance(meters, locale: Locale(identifier: "en_US"))
    let de = NodeLocationStalenessPolicy.formattedDistance(meters, locale: Locale(identifier: "de_DE"))
    #expect(us.contains("mi"))
    #expect(us.contains("50"))
    #expect(de.contains("km"))
    #expect(de.contains("80"))
  }
}
