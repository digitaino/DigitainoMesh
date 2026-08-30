import Foundation

/// The signal mapper's tunable constants — docs/SIGNAL_MAPPER_V2.md §2.5.
///
/// The doc is explicit that these are "beta-tunable defaults, not decisions": debug and
/// TestFlight builds expose every one of them for live adjustment and the final values
/// come out of field testing. That is why they are a value type read through a provider
/// rather than a `static let` scattered across the engines — a `static let` cannot be
/// turned by a tester standing in a dead spot.
///
/// M0 consumes only the fix and flush constants. The probe constants are defined now
/// because the manual-mode session engine (M3) reads the same struct, and a tester's
/// panel that grows fields per milestone is a panel nobody trusts.
public struct MapperTuning: Sendable, Equatable, Codable {
  // MARK: - Probe discipline (consumed in M3)

  /// Sustained seconds between probe cycles in a manual session. §2.5 shipped 10;
  /// M3.5's field review cut it to 4 — at ride speed the novelty refill must leave
  /// headroom beside the focus scheduler (ACTIVE_SURVEY_M3_5.md §2.9).
  public var probeIntervalSeconds: TimeInterval

  /// How many probes may go out back to back before the sustained rate applies. M3.5: 4.
  public var probeBurst: Int

  /// Samples collected for one cell before a session stops probing it. M3.5: 3 (live via SamplingPolicy counts).
  public var samplesPerCellPerSession: Int

  /// A cell with coverage newer than this is skipped by a survey session.
  /// M3.5: default 0 (warm pass off) — one week-old res-9 row used to mark its 920 m
  /// and 2.4 km tier parents as sampled, blanking the near field of a range ride.
  ///
  /// M3 applies it to *local* rows at exact-day precision (they never leave the device);
  /// M2 extends the same test to community freshness, read as month-granularity tiers
  /// only (§2.4). There is deliberately no flood constant here: the flood-discover
  /// exception was removed 2026-08-26 — survey sessions never transmit flood-routed,
  /// and a knob that could turn that back on is not a tuning, it is a design change.
  public var communityFreshnessDays: Int

  // MARK: - Focus probing (consumed in M3.5)

  /// Base seconds between directed traces to a locked-on focus target. The engine's
  /// loss-streak ladder scales this (×0.4 while a target is dropping probes at the
  /// coverage edge, ×3 once it is well and truly gone), so this is the healthy-link
  /// cadence, not a fixed rate. ACTIVE_SURVEY_M3_5.md §2.2: 20 s ≈ 3 replies/min
  /// forced out of one repeater — inside the app's own signal-bars discipline.
  public var focusProbeIntervalSeconds: TimeInterval

  // MARK: - Raw ride log (consumed in M3.5)

  /// Hard cap on raw rows one survey run may write. A 2 h ride writes ~6–16 k;
  /// the cap is a runaway backstop, not a target.
  public var rawSampleCapPerSession: Int

  /// Whether an active survey run keeps the screen awake (`isIdleTimerDisabled`).
  /// User-visible behaviour, not just a debug knob: a bar-mounted phone that sleeps
  /// mid-ride ends the ride (foreground-only capture).
  public var rideKeepsScreenAwake: Bool

  /// Days raw ride-log rows are kept before the launch purge removes them.
  /// 0 means keep forever — an explicit choice, deliberately **not** the default:
  /// a precise movement diary's analytic value decays in weeks while its exposure
  /// accrues forever (ACTIVE_SURVEY_M3_5.md §3.1). Unlike ``MapperTuningStore``'s
  /// anchor seed, this key IS reset by `resetToDefaults()` — the reset must restore
  /// the safe value, not preserve an override.
  public var rawRetentionDays: Int

  // MARK: - Fix policy (consumed in M0)

  /// Oldest a fix may be and still tag an observation, in seconds. M3.5: 30 s (live fixes are ~1 s old; 120 only masked a stalled stream).
  public var fixMaxAgeSeconds: TimeInterval

  /// Worst horizontal accuracy that still tags an observation, in meters. M3.5: 50 m.
  public var fixMaxAccuracyMeters: Double

  /// How far the phone may have travelled since a fix was captured before that fix stops
  /// describing where it is, in meters.
  ///
  /// This is the *speed-scaled* half of the fix gate: a fix reporting ground speed `v` is
  /// only tolerated up to an age of `fixMaxDisplacementMeters / v`, so a stationary phone
  /// keeps the whole ``fixMaxAgeSeconds`` and one on a motorway gets a couple of seconds.
  /// Without it, ``fixMaxAgeSeconds`` alone lets a 15 m/s phone attribute a packet to a
  /// cell nearly two kilometers behind it.
  ///
  /// The default is about half a res-9 cell across, so the worst tolerated error keeps an
  /// observation inside its own cell or the one next to it.
  public var fixMaxDisplacementMeters: Double

  // MARK: - Anchor exclusion (consumed in M1)

  /// Distinct days a cell must be seen on before dwell can make it an anchor. §2.7: 5.
  public var anchorMinDistinctDays: Int

  /// Share of a cell's observations that must have been captured while stationary for it
  /// to count as somewhere the user *stays* rather than passes through. §2.7: 0.6.
  public var anchorStationaryShare: Double

  /// Observation count that makes a cell an anchor on volume alone, whatever the movement
  /// hints said. The backstop for a phone with no motion authorization. §2.7: 2000.
  public var anchorObservationCount: Int

  /// How far an exclusion disc's centre is displaced from its anchor cell's centre, in
  /// meters (minimum and maximum of the per-install random draw). §2.7: 300–600 m.
  public var anchorOffsetMinMeters: Double
  public var anchorOffsetMaxMeters: Double

  /// An exclusion disc's radius, in meters (minimum and maximum of the per-install random
  /// draw). §2.7: 700–1200 m.
  public var anchorRadiusMinMeters: Double
  public var anchorRadiusMaxMeters: Double

  /// Flushes between anchor recomputations. Anchors move on a scale of days, so asking the
  /// store to re-derive them per packet would be pure cost.
  public var anchorRecomputeFlushCount: Int

  // MARK: - Flush policy (consumed in M0)

  /// Seconds between flushes of the in-memory aggregate to the store.
  public var flushIntervalSeconds: TimeInterval

  /// Entries buffered before a flush is forced, whichever comes first.
  public var flushEntryCount: Int

  // MARK: - Upload batching (consumed in M2)

  /// Cells that make a batch worth uploading. §2.5: 25.
  public var uploadBatchMinCells: Int

  /// Seconds after which a batch uploads regardless of size. §2.5: 24 h.
  public var uploadBatchMaxAgeSeconds: TimeInterval

  /// Maximum random delay added to an upload, in seconds, so arrival time cannot be
  /// correlated with movement (§3.4). §2.5: ±6 h.
  public var uploadJitterSeconds: TimeInterval

  public init(
    probeIntervalSeconds: TimeInterval = 4,
    probeBurst: Int = 4,
    samplesPerCellPerSession: Int = 3,
    communityFreshnessDays: Int = 0,
    focusProbeIntervalSeconds: TimeInterval = 20,
    rawSampleCapPerSession: Int = 50000,
    rawRetentionDays: Int = 30,
    rideKeepsScreenAwake: Bool = true,
    fixMaxAgeSeconds: TimeInterval = 30,
    fixMaxAccuracyMeters: Double = 50,
    fixMaxDisplacementMeters: Double = 60,
    anchorMinDistinctDays: Int = 5,
    anchorStationaryShare: Double = 0.6,
    anchorObservationCount: Int = 2000,
    anchorOffsetMinMeters: Double = 300,
    anchorOffsetMaxMeters: Double = 600,
    anchorRadiusMinMeters: Double = 700,
    anchorRadiusMaxMeters: Double = 1200,
    anchorRecomputeFlushCount: Int = 20,
    flushIntervalSeconds: TimeInterval = 30,
    flushEntryCount: Int = 50,
    uploadBatchMinCells: Int = 25,
    uploadBatchMaxAgeSeconds: TimeInterval = 24 * 60 * 60,
    uploadJitterSeconds: TimeInterval = 6 * 60 * 60
  ) {
    self.probeIntervalSeconds = probeIntervalSeconds
    self.probeBurst = probeBurst
    self.samplesPerCellPerSession = samplesPerCellPerSession
    self.communityFreshnessDays = communityFreshnessDays
    self.focusProbeIntervalSeconds = focusProbeIntervalSeconds
    self.rawSampleCapPerSession = rawSampleCapPerSession
    self.rawRetentionDays = rawRetentionDays
    self.rideKeepsScreenAwake = rideKeepsScreenAwake
    self.fixMaxAgeSeconds = fixMaxAgeSeconds
    self.fixMaxAccuracyMeters = fixMaxAccuracyMeters
    self.fixMaxDisplacementMeters = fixMaxDisplacementMeters
    self.anchorMinDistinctDays = anchorMinDistinctDays
    self.anchorStationaryShare = anchorStationaryShare
    self.anchorObservationCount = anchorObservationCount
    self.anchorOffsetMinMeters = anchorOffsetMinMeters
    self.anchorOffsetMaxMeters = anchorOffsetMaxMeters
    self.anchorRadiusMinMeters = anchorRadiusMinMeters
    self.anchorRadiusMaxMeters = anchorRadiusMaxMeters
    self.anchorRecomputeFlushCount = anchorRecomputeFlushCount
    self.flushIntervalSeconds = flushIntervalSeconds
    self.flushEntryCount = flushEntryCount
    self.uploadBatchMinCells = uploadBatchMinCells
    self.uploadBatchMaxAgeSeconds = uploadBatchMaxAgeSeconds
    self.uploadJitterSeconds = uploadJitterSeconds
  }

  /// The §2.5 starting defaults, and what the reset button restores.
  public static let defaults = MapperTuning()
}

// MARK: - Provider

/// Supplies the current ``MapperTuning``.
///
/// Pull-based and read on every use rather than captured at construction, so a value
/// changed in the debug panel takes effect on the next packet instead of the next launch.
public protocol MapperTuningProviding: Sendable {
  var tuning: MapperTuning { get }
}

/// A fixed tuning. The engine's default, and what tests inject.
public struct StaticMapperTuningProvider: MapperTuningProviding {
  public let tuning: MapperTuning

  public init(_ tuning: MapperTuning = .defaults) {
    self.tuning = tuning
  }
}

// MARK: - UserDefaults-backed store

/// `UserDefaults`-backed ``MapperTuning``, plus the M0 capture flag.
///
/// Keys live in their own `com.pocketmesh.signalMapper.*` namespace rather than in
/// ``AppStorageKey``: these are field-tuning knobs and a debug flag, not user preferences,
/// and they are deliberately *not* carried by backup/restore — a value dialled in for one
/// phone's testing session has no business following the user onto new hardware.
///
/// `@unchecked Sendable` for the reason ``LastConnectionStore`` is: the only stored
/// property is a `UserDefaults`, which is documented thread-safe.
public struct MapperTuningStore: MapperTuningProviding, MapperAnchorSeedProviding, @unchecked Sendable {
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  // MARK: - Anchor seed

  /// The per-install seed the anchor exclusion discs are drawn from, created on first read.
  ///
  /// Deliberately **not** a tuning key: ``resetToDefaults()`` leaves it alone, because
  /// re-rolling it would move every exclusion disc, and two differently-placed voids over
  /// the same home intersect much closer to the truth than either one alone
  /// (``MapperAnchorPolicy``). For the same reason it is never displayed, exported or
  /// uploaded — this is the only accessor.
  ///
  /// Stored as `Int` bit pattern because that is the widest integer `UserDefaults` carries
  /// losslessly. Zero is treated as "not set", which costs one value out of 2⁶⁴.
  public var anchorSeed: UInt64 {
    if let stored = defaults.object(forKey: Key.anchorSeed) as? Int, stored != 0 {
      return UInt64(bitPattern: Int64(stored))
    }
    let seed = UInt64.random(in: 1...UInt64.max)
    defaults.set(Int(bitPattern: UInt(seed)), forKey: Key.anchorSeed)
    return seed
  }

  // MARK: - Capture flag

  /// Whether the passive capture engine runs. The M0 debug flag: **off** unless a tester
  /// turns it on, so no build captures anything by accident.
  public var isCaptureEnabled: Bool {
    defaults.bool(forKey: Key.captureEnabled)
  }

  public func setCaptureEnabled(_ enabled: Bool) {
    defaults.set(enabled, forKey: Key.captureEnabled)
  }

  // MARK: - Tuning

  /// The stored tuning, falling back per-field to the §2.5 default. Per-field rather than
  /// all-or-nothing so a constant added in a later build gets its new default instead of
  /// resetting everything the tester had already dialled in.
  public var tuning: MapperTuning {
    let defaultValue = MapperTuning.defaults
    return MapperTuning(
      probeIntervalSeconds: double(Key.probeInterval, defaultValue.probeIntervalSeconds),
      probeBurst: int(Key.probeBurst, defaultValue.probeBurst),
      samplesPerCellPerSession: int(Key.samplesPerCell, defaultValue.samplesPerCellPerSession),
      communityFreshnessDays: int(Key.communityFreshnessDays, defaultValue.communityFreshnessDays),
      focusProbeIntervalSeconds: double(Key.focusProbeInterval, defaultValue.focusProbeIntervalSeconds),
      rawSampleCapPerSession: int(Key.rawSampleCap, defaultValue.rawSampleCapPerSession),
      rawRetentionDays: int(Key.rawRetentionDays, defaultValue.rawRetentionDays),
      rideKeepsScreenAwake: bool(Key.rideKeepsScreenAwake, defaultValue.rideKeepsScreenAwake),
      fixMaxAgeSeconds: double(Key.fixMaxAge, defaultValue.fixMaxAgeSeconds),
      fixMaxAccuracyMeters: double(Key.fixMaxAccuracy, defaultValue.fixMaxAccuracyMeters),
      fixMaxDisplacementMeters: double(Key.fixMaxDisplacement, defaultValue.fixMaxDisplacementMeters),
      anchorMinDistinctDays: int(Key.anchorMinDistinctDays, defaultValue.anchorMinDistinctDays),
      anchorStationaryShare: double(Key.anchorStationaryShare, defaultValue.anchorStationaryShare),
      anchorObservationCount: int(Key.anchorObservationCount, defaultValue.anchorObservationCount),
      anchorOffsetMinMeters: double(Key.anchorOffsetMin, defaultValue.anchorOffsetMinMeters),
      anchorOffsetMaxMeters: double(Key.anchorOffsetMax, defaultValue.anchorOffsetMaxMeters),
      anchorRadiusMinMeters: double(Key.anchorRadiusMin, defaultValue.anchorRadiusMinMeters),
      anchorRadiusMaxMeters: double(Key.anchorRadiusMax, defaultValue.anchorRadiusMaxMeters),
      anchorRecomputeFlushCount: int(Key.anchorRecomputeFlushCount, defaultValue.anchorRecomputeFlushCount),
      flushIntervalSeconds: double(Key.flushInterval, defaultValue.flushIntervalSeconds),
      flushEntryCount: int(Key.flushEntryCount, defaultValue.flushEntryCount),
      uploadBatchMinCells: int(Key.uploadBatchMinCells, defaultValue.uploadBatchMinCells),
      uploadBatchMaxAgeSeconds: double(Key.uploadBatchMaxAge, defaultValue.uploadBatchMaxAgeSeconds),
      uploadJitterSeconds: double(Key.uploadJitter, defaultValue.uploadJitterSeconds)
    )
  }

  public func save(_ tuning: MapperTuning) {
    defaults.set(tuning.probeIntervalSeconds, forKey: Key.probeInterval)
    defaults.set(tuning.probeBurst, forKey: Key.probeBurst)
    defaults.set(tuning.samplesPerCellPerSession, forKey: Key.samplesPerCell)
    defaults.set(tuning.communityFreshnessDays, forKey: Key.communityFreshnessDays)
    defaults.set(tuning.focusProbeIntervalSeconds, forKey: Key.focusProbeInterval)
    defaults.set(tuning.rawSampleCapPerSession, forKey: Key.rawSampleCap)
    defaults.set(tuning.rawRetentionDays, forKey: Key.rawRetentionDays)
    defaults.set(tuning.rideKeepsScreenAwake, forKey: Key.rideKeepsScreenAwake)
    defaults.set(tuning.fixMaxAgeSeconds, forKey: Key.fixMaxAge)
    defaults.set(tuning.fixMaxAccuracyMeters, forKey: Key.fixMaxAccuracy)
    defaults.set(tuning.fixMaxDisplacementMeters, forKey: Key.fixMaxDisplacement)
    defaults.set(tuning.anchorMinDistinctDays, forKey: Key.anchorMinDistinctDays)
    defaults.set(tuning.anchorStationaryShare, forKey: Key.anchorStationaryShare)
    defaults.set(tuning.anchorObservationCount, forKey: Key.anchorObservationCount)
    defaults.set(tuning.anchorOffsetMinMeters, forKey: Key.anchorOffsetMin)
    defaults.set(tuning.anchorOffsetMaxMeters, forKey: Key.anchorOffsetMax)
    defaults.set(tuning.anchorRadiusMinMeters, forKey: Key.anchorRadiusMin)
    defaults.set(tuning.anchorRadiusMaxMeters, forKey: Key.anchorRadiusMax)
    defaults.set(tuning.anchorRecomputeFlushCount, forKey: Key.anchorRecomputeFlushCount)
    defaults.set(tuning.flushIntervalSeconds, forKey: Key.flushInterval)
    defaults.set(tuning.flushEntryCount, forKey: Key.flushEntryCount)
    defaults.set(tuning.uploadBatchMinCells, forKey: Key.uploadBatchMinCells)
    defaults.set(tuning.uploadBatchMaxAgeSeconds, forKey: Key.uploadBatchMaxAge)
    defaults.set(tuning.uploadJitterSeconds, forKey: Key.uploadJitter)
  }

  /// Clears every tuning key, so ``tuning`` reads back the §2.5 defaults. Leaves the
  /// capture flag alone — resetting the numbers is not a request to stop capturing.
  public func resetToDefaults() {
    for key in Key.tuningKeys {
      defaults.removeObject(forKey: key)
    }
  }

  // MARK: - Helpers

  private func double(_ key: String, _ fallback: Double) -> Double {
    defaults.object(forKey: key) as? Double ?? fallback
  }

  private func int(_ key: String, _ fallback: Int) -> Int {
    defaults.object(forKey: key) as? Int ?? fallback
  }

  private func bool(_ key: String, _ fallback: Bool) -> Bool {
    defaults.object(forKey: key) as? Bool ?? fallback
  }

  private enum Key {
    static let captureEnabled = "com.pocketmesh.signalMapper.captureEnabled"
    static let anchorSeed = "com.pocketmesh.signalMapper.anchorSeed"
    static let probeInterval = "com.pocketmesh.signalMapper.probeIntervalSeconds"
    static let probeBurst = "com.pocketmesh.signalMapper.probeBurst"
    static let samplesPerCell = "com.pocketmesh.signalMapper.samplesPerCellPerSession"
    static let communityFreshnessDays = "com.pocketmesh.signalMapper.communityFreshnessDays"
    static let focusProbeInterval = "com.pocketmesh.signalMapper.focusProbeIntervalSeconds"
    static let rawSampleCap = "com.pocketmesh.signalMapper.rawSampleCapPerSession"
    static let rawRetentionDays = "com.pocketmesh.signalMapper.rawRetentionDays"
    static let rideKeepsScreenAwake = "com.pocketmesh.signalMapper.rideKeepsScreenAwake"
    static let fixMaxAge = "com.pocketmesh.signalMapper.fixMaxAgeSeconds"
    static let fixMaxAccuracy = "com.pocketmesh.signalMapper.fixMaxAccuracyMeters"
    static let fixMaxDisplacement = "com.pocketmesh.signalMapper.fixMaxDisplacementMeters"
    static let anchorMinDistinctDays = "com.pocketmesh.signalMapper.anchorMinDistinctDays"
    static let anchorStationaryShare = "com.pocketmesh.signalMapper.anchorStationaryShare"
    static let anchorObservationCount = "com.pocketmesh.signalMapper.anchorObservationCount"
    static let anchorOffsetMin = "com.pocketmesh.signalMapper.anchorOffsetMinMeters"
    static let anchorOffsetMax = "com.pocketmesh.signalMapper.anchorOffsetMaxMeters"
    static let anchorRadiusMin = "com.pocketmesh.signalMapper.anchorRadiusMinMeters"
    static let anchorRadiusMax = "com.pocketmesh.signalMapper.anchorRadiusMaxMeters"
    static let anchorRecomputeFlushCount = "com.pocketmesh.signalMapper.anchorRecomputeFlushCount"
    static let flushInterval = "com.pocketmesh.signalMapper.flushIntervalSeconds"
    static let flushEntryCount = "com.pocketmesh.signalMapper.flushEntryCount"
    static let uploadBatchMinCells = "com.pocketmesh.signalMapper.uploadBatchMinCells"
    static let uploadBatchMaxAge = "com.pocketmesh.signalMapper.uploadBatchMaxAgeSeconds"
    static let uploadJitter = "com.pocketmesh.signalMapper.uploadJitterSeconds"

    static let tuningKeys = [
      probeInterval, probeBurst, samplesPerCell, communityFreshnessDays,
      focusProbeInterval, rawSampleCap, rawRetentionDays, rideKeepsScreenAwake,
      fixMaxAge, fixMaxAccuracy, fixMaxDisplacement,
      anchorMinDistinctDays, anchorStationaryShare, anchorObservationCount,
      anchorOffsetMin, anchorOffsetMax, anchorRadiusMin, anchorRadiusMax,
      anchorRecomputeFlushCount,
      flushInterval, flushEntryCount,
      uploadBatchMinCells, uploadBatchMaxAge, uploadJitter
    ]
  }
}
