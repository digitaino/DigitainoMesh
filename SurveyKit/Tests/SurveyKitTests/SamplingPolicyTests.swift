import Foundation
import Testing
@testable import SurveyKit

// Note: Swift Testing's #expect/#require macros can't wrap calls to mutating members,
// so results are hoisted into locals throughout.

@Suite("SamplingPolicy")
struct SamplingPolicyTests {

    @Test func tokenBucketEnforcesCeiling() {
        var bucket = TokenBucket(capacity: 6, refillPerSecond: 0.1, at: 0)
        let c1 = bucket.tryConsume(2, at: 0)
        let c2 = bucket.tryConsume(2, at: 0)
        let c3 = bucket.tryConsume(2, at: 0)
        let c4 = bucket.tryConsume(2, at: 0)      // empty
        let c5 = bucket.tryConsume(2, at: 10)     // +1 token, still short
        let c6 = bucket.tryConsume(2, at: 20)     // +2 tokens
        #expect(c1 && c2 && c3)
        #expect(!c4 && !c5)
        #expect(c6)

        // Floor keeps a reserve for manual actions.
        var reserved = TokenBucket(capacity: 6, refillPerSecond: 0.1, at: 0)
        let r1 = reserved.tryConsume(2, at: 0, floor: 2)
        let r2 = reserved.tryConsume(2, at: 0, floor: 2)
        let r3 = reserved.tryConsume(2, at: 0, floor: 2)  // would breach the floor
        let r4 = reserved.tryConsume(2, at: 0)            // manual path may use it
        #expect(r1 && r2)
        #expect(!r3)
        #expect(r4)
    }

    @Test func tierControllerNeedsDwellAndHysteresis() {
        var tiers = TierController()
        // Instant spike doesn't switch: dwell required.
        let t1 = tiers.update(speed: 20, at: 0)
        let t2 = tiers.update(speed: 20, at: 3)
        let t3 = tiers.update(speed: 20, at: 5.1)
        #expect(t1 == .fine && t2 == .fine)
        #expect(t3 == .coarse)

        // Dropping to 13 m/s stays coarse (hysteresis: exit is < 12).
        let t4 = tiers.update(speed: 13, at: 10)
        let t5 = tiers.update(speed: 13, at: 20)
        #expect(t4 == .coarse && t5 == .coarse)

        // Sustained 11.5 m/s falls back to medium.
        _ = tiers.update(speed: 11.5, at: 25)
        let t6 = tiers.update(speed: 11.5, at: 30.1)
        #expect(t6 == .medium)

        // Invalid speed keeps the current tier and resets the candidate.
        let t7 = tiers.update(speed: nil, at: 31)
        let t8 = tiers.update(speed: -1, at: 32)
        #expect(t7 == .medium && t8 == .medium)
    }

    /// The scenario from the bug report: highway driving. The old system transmitted
    /// ~45 times/minute; the policy must keep a sustained drive at or under the
    /// bucket's sustained rate (6 tokens/min = ≤ 3 probe cycles/min) while still
    /// making progress through novel cells.
    @Test func highwayDriveStaysWithinBudget() {
        var policy = SamplingPolicy(at: 0)
        let speed = 30.0 // m/s ≈ 108 km/h
        var transmissionTokens = 0.0
        var probes = 0

        // Drive due north for 10 minutes, location update every 2 s.
        for tick in 0...300 {
            let now = TimeInterval(tick * 2)
            let coordinate = GeoCoordinate(
                latitude: 30.0 + (speed * now) / 111_320.0,
                longitude: -97.7431
            )
            if let plan = policy.locationUpdate(coordinate: coordinate, speed: speed, at: now) {
                probes += 1
                transmissionTokens += 2 + (plan.includeFlood ? 2 : 0)
                // Simulate a response landing so the cell is marked sampled.
                policy.recordSample(in: plan.baseCell)
            }
        }

        let minutes = 10.0
        #expect(probes > 3)                                  // still surveying
        #expect(Double(probes) / minutes <= 3.0)             // ≤ 3 cycles/min
        #expect(transmissionTokens / minutes <= 6.0)         // hard TX ceiling honored
    }

    @Test func walkingProbesNovelCellsButNotRevisits() throws {
        var policy = SamplingPolicy(at: 0)
        let home = GeoCoordinate(latitude: 30.2672, longitude: -97.7431)

        let firstPlan = policy.locationUpdate(coordinate: home, speed: 1.2, at: 10)
        let plan = try #require(firstPlan)
        #expect(plan.tier == .fine)
        policy.recordSample(in: plan.baseCell)

        // Same spot again: sampled → no probe, even after the cadence gap.
        let revisit = policy.locationUpdate(coordinate: home, speed: 1.2, at: 100)
        #expect(revisit == nil)

        // ~500 m away: novel cell → probe.
        let away = GeoCoordinate(latitude: 30.2717, longitude: -97.7431)
        let awayPlan = policy.locationUpdate(coordinate: away, speed: 1.2, at: 120)
        #expect(awayPlan != nil)
    }

    @Test func samplesPerCellAllowsASeriesThenStops() throws {
        var config = SamplingPolicy.Config()
        config.bucketCapacity = 100
        config.samplesPerCell = 3
        config.minProbeInterval = 1
        config.stationaryRetryInterval = 5
        var policy = SamplingPolicy(config: config, at: 0)
        let home = GeoCoordinate(latitude: 30.2672, longitude: -97.7431)

        var planned = 0
        var now: TimeInterval = 10
        for _ in 0..<10 {
            if let plan = policy.locationUpdate(coordinate: home, speed: 1.2, at: now) {
                planned += 1
                policy.recordSample(in: plan.baseCell)
            }
            now += 6 // clears both the min interval and the stationary retry
        }
        // Exactly samplesPerCell probes, then the cell stops being novel.
        #expect(planned == 3)
    }

    @Test func markCoveredSaturatesRegardlessOfQuota() throws {
        var config = SamplingPolicy.Config()
        config.bucketCapacity = 100
        config.samplesPerCell = 5
        var policy = SamplingPolicy(config: config, at: 0)
        let home = GeoCoordinate(latitude: 30.2672, longitude: -97.7431)
        let baseCell = try #require(SurveyGrid.cell(containing: home))

        policy.markCovered(baseCell)
        // Despite a quota of 5 and zero recorded samples, the warm-passed cell
        // never probes again this session.
        let plan = policy.locationUpdate(coordinate: home, speed: 1.2, at: 100)
        #expect(plan == nil)
    }

    @Test func fineSamplesExhaustTheCoarserParents() throws {
        // Deliberate cross-tier semantics: quota filled at fine tier also fills the
        // medium/coarse parents, so a tier flip doesn't re-survey the same ground.
        var config = SamplingPolicy.Config()
        config.bucketCapacity = 100
        config.samplesPerCell = 2
        config.minProbeInterval = 1
        config.stationaryRetryInterval = 2
        var policy = SamplingPolicy(config: config, at: 0)
        let home = GeoCoordinate(latitude: 30.2672, longitude: -97.7431)

        var now: TimeInterval = 10
        var planned = 0
        for _ in 0..<6 {
            if let plan = policy.locationUpdate(coordinate: home, speed: 1.2, at: now) {
                planned += 1
                policy.recordSample(in: plan.baseCell)
            }
            now += 3
        }
        #expect(planned == 2)

        // Force the coarse tier at the same spot: parents are already at quota.
        policy.tierOverride = .coarse
        let coarsePlan = policy.locationUpdate(coordinate: home, speed: 1.2, at: now + 10)
        #expect(coarsePlan == nil)
    }

    @Test func minIntervalGatesEvenNovelCells() {
        // Big bucket so only the cadence gate is under test here.
        var config = SamplingPolicy.Config()
        config.bucketCapacity = 100
        var policy = SamplingPolicy(config: config, at: 0)
        let a = GeoCoordinate(latitude: 30.2672, longitude: -97.7431)
        let b = GeoCoordinate(latitude: 30.2717, longitude: -97.7431)
        let first = policy.locationUpdate(coordinate: a, speed: 1, at: 10)
        // 3 s later in a different novel cell: min interval (8 s) blocks it.
        let tooSoon = policy.locationUpdate(coordinate: b, speed: 1, at: 13)
        let afterGap = policy.locationUpdate(coordinate: b, speed: 1, at: 18.5)
        #expect(first != nil)
        #expect(tooSoon == nil)
        #expect(afterGap != nil)
    }

    @Test func floodQuotaIsOncePerTierCell() throws {
        var policy = SamplingPolicy(at: 0)
        let spot = GeoCoordinate(latitude: 30.2672, longitude: -97.7431)

        let firstPlan = policy.manualProbe(coordinate: spot, at: 0)
        let first = try #require(firstPlan)
        #expect(first.includeFlood)
        // Wait for full refill, probe the same spot: flood quota spent.
        let secondPlan = policy.manualProbe(coordinate: spot, at: 120)
        let second = try #require(secondPlan)
        #expect(!second.includeFlood)
    }

    @Test func manualProbeUsesReserveButRespectsBucket() {
        var policy = SamplingPolicy(at: 0)
        let spot = GeoCoordinate(latitude: 30.2672, longitude: -97.7431)
        // Drain: manual probes cost 2 (+2 flood on the first).
        let p1 = policy.manualProbe(coordinate: spot, at: 0)   // -4 → 2 left
        let p2 = policy.manualProbe(coordinate: spot, at: 0)   // -2 → 0 left
        let p3 = policy.manualProbe(coordinate: spot, at: 0)   // empty: refused
        #expect(p1 != nil)
        #expect(p2 != nil)
        #expect(p3 == nil)
    }
}
