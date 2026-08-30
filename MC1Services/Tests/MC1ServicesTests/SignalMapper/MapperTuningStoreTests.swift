import Foundation
@testable import MC1Services
import Testing

/// The §2.5 tuning constants and the M0 capture flag, as the debug panel reads and writes
/// them. Each test runs against its own `UserDefaults` suite so nothing touches the
/// developer's own settings or leaks between tests.
@Suite("MapperTuningStore")
struct MapperTuningStoreTests {
  private func makeDefaults() throws -> UserDefaults {
    let suiteName = "com.pocketmesh.tests.signalMapper.\(UUID().uuidString)"
    return try #require(UserDefaults(suiteName: suiteName))
  }

  @Test
  func `An untouched store reads the documented defaults`() throws {
    let store = try MapperTuningStore(defaults: makeDefaults())

    #expect(store.tuning == MapperTuning.defaults)
    // The M3.5 ride-review defaults (docs/ACTIVE_SURVEY_M3_5.md §2.9).
    #expect(store.tuning.fixMaxAgeSeconds == 30)
    #expect(store.tuning.fixMaxAccuracyMeters == 50)
    #expect(store.tuning.probeIntervalSeconds == 4)
    #expect(store.tuning.probeBurst == 4)
    #expect(store.tuning.samplesPerCellPerSession == 3)
    #expect(store.tuning.communityFreshnessDays == 0)
    #expect(store.tuning.focusProbeIntervalSeconds == 20)
    #expect(store.tuning.rawSampleCapPerSession == 50000)
    #expect(store.tuning.rawRetentionDays == 30)
    #expect(store.tuning.rideKeepsScreenAwake == true)
    #expect(store.tuning.uploadBatchMinCells == 25)
  }

  @Test
  func `Capture is off until something turns it on`() throws {
    let store = try MapperTuningStore(defaults: makeDefaults())

    #expect(store.isCaptureEnabled == false)
    store.setCaptureEnabled(true)
    #expect(store.isCaptureEnabled)
  }

  @Test
  func `Saved tuning round-trips`() throws {
    let store = try MapperTuningStore(defaults: makeDefaults())
    var tuning = MapperTuning.defaults
    tuning.fixMaxAgeSeconds = 45
    tuning.fixMaxAccuracyMeters = 30
    tuning.flushIntervalSeconds = 5
    tuning.flushEntryCount = 7
    tuning.probeBurst = 1

    store.save(tuning)

    #expect(store.tuning == tuning)
  }

  @Test
  func `Reset restores the defaults without stopping capture`() throws {
    let store = try MapperTuningStore(defaults: makeDefaults())
    var tuning = MapperTuning.defaults
    tuning.fixMaxAgeSeconds = 45
    store.save(tuning)
    store.setCaptureEnabled(true)

    store.resetToDefaults()

    #expect(store.tuning == MapperTuning.defaults)
    #expect(store.isCaptureEnabled, "resetting the numbers is not a request to stop capturing")
  }

  @Test
  func `A constant with no stored value falls back on its own default, not on the whole struct`() throws {
    let defaults = try makeDefaults()
    let store = MapperTuningStore(defaults: defaults)
    var tuning = MapperTuning.defaults
    tuning.fixMaxAgeSeconds = 45
    tuning.probeBurst = 9
    store.save(tuning)

    // Stand in for a key that a later build introduces: the value is simply absent.
    defaults.removeObject(forKey: "com.pocketmesh.signalMapper.probeBurst")

    #expect(store.tuning.fixMaxAgeSeconds == 45, "the tester's other values survive")
    #expect(store.tuning.probeBurst == MapperTuning.defaults.probeBurst)
  }
}
