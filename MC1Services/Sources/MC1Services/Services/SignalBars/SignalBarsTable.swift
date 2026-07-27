import Foundation

/// The repeater signal table: a pure value type holding every merge, ordering, eviction
/// and hide rule the signal-bars feature has.
///
/// It owns no clock and no radio — every mutating call takes the `now` it should use — so
/// the whole state machine can be driven straight from a test.
struct SignalBarsTable: Sendable, Equatable {
  /// The full table, ordered best link first.
  private(set) var repeaters: [RepeaterSignal] = []

  /// Repeaters the user hid, and when. A dismissal only suppresses an entry that has not
  /// been heard *since*, so this is a local hide that undoes itself the moment the radio
  /// hears the repeater again — the device's table and OLED are never touched.
  private(set) var dismissals: [NodeHexID: Date] = [:]

  var policy: SignalBarsPolicy

  init(policy: SignalBarsPolicy = SignalBarsPolicy()) {
    self.policy = policy
  }

  // MARK: - Lookup

  /// The index of the entry naming the same node as `id`, at any hash width.
  ///
  /// Exact matches win; otherwise the bidirectional prefix rule applies, so `"0C"` heard
  /// on a 1-byte path and `"0C13"` heard on a 2-byte path are one repeater.
  func index(of id: NodeHexID) -> Int? {
    if let exact = repeaters.firstIndex(where: { $0.id == id }) { return exact }
    return repeaters.firstIndex { $0.id.identifiesSameNode(as: id) }
  }

  subscript(id: NodeHexID) -> RepeaterSignal? {
    index(of: id).map { repeaters[$0] }
  }

  /// The best link — the head of the ordered table.
  var best: RepeaterSignal? {
    repeaters.first
  }

  // MARK: - Ingest

  /// What an ingest did: the entry it landed on, and whether the best link changed as a
  /// result (which the engine turns into a probe-queue promotion).
  struct Change: Sendable, Equatable {
    var id: NodeHexID
    var bestChanged: Bool
  }

  /// Folds a sighting into the table, returning where it landed.
  ///
  /// Merge rules, ported from the legacy service:
  /// - An RX SNR for an already-tracked repeater is smoothed 75/25 against the stored
  ///   value, matching the firmware's EMA so the app's bars are as steady as the OLED's.
  ///   A first sighting takes the raw value.
  /// - A wider hash upgrades the entry's ID; a narrower one leaves it alone.
  /// - A TX SNR (discover responses only) marks the TX leg measured.
  /// - `nil` fields never erase what is already known.
  /// - At capacity the least-recently-heard entry is evicted, as the firmware does.
  @discardableResult
  mutating func ingest(_ sighting: RepeaterSighting, now: Date) -> Change {
    let previousBest = repeaters.first?.id
    guard let index = index(of: sighting.id) else {
      insert(sighting, now: now)
      return Change(id: sighting.id, bestChanged: sort(previousBest: previousBest))
    }

    var entry = repeaters[index]
    entry.rxSnr = entry.rxSnr.map { ($0 * 3 + sighting.rxSnr) / 4 } ?? sighting.rxSnr
    entry.lastHeard = now
    if sighting.id.byteWidth > entry.id.byteWidth { entry.id = sighting.id }
    if let rssi = sighting.rssi { entry.rssi = rssi }
    if let publicKey = sighting.publicKey { entry.publicKey = publicKey }
    if let txSnr = sighting.txSnr {
      entry.txSnr = txSnr
      entry.txState = .measured(SNRQuality(snr: txSnr))
    }
    repeaters[index] = entry
    return Change(id: entry.id, bestChanged: sort(previousBest: previousBest))
  }

  private mutating func insert(_ sighting: RepeaterSighting, now: Date) {
    if repeaters.count >= policy.maxTrackedRepeaters,
       let oldest = repeaters.indices.min(by: { repeaters[$0].lastHeard < repeaters[$1].lastHeard }) {
      repeaters.remove(at: oldest)
    }
    repeaters.append(RepeaterSignal(
      id: sighting.id,
      rxSnr: sighting.rxSnr,
      txSnr: sighting.txSnr,
      txState: sighting.txSnr.map { .measured(SNRQuality(snr: $0)) } ?? .unknown,
      rssi: sighting.rssi,
      lastHeard: now,
      publicKey: sighting.publicKey
    ))
  }

  /// Replaces the table with the device's own, as decoded from the sync blob.
  ///
  /// The firmware emits its entries in canonical order (best first, matching the OLED
  /// Signals page), so the order is rendered verbatim rather than re-scored. Locally known
  /// facts the blob has no room for — resolved name, RSSI, public key, last probe time —
  /// survive the replacement for any entry that names the same node.
  mutating func apply(_ blob: SignalBarsBlob, now: Date) {
    repeaters = blob.entries.compactMap { entry -> RepeaterSignal? in
      guard let id = NodeHexID(entry.hexID) else { return nil }
      let existing = self[id]
      let txState: RepeaterTXState =
        if entry.hasTx {
          .measured(SNRQuality(snr: entry.txSnr))
        } else if entry.txFailed {
          .failed
        } else {
          .unknown
        }
      return RepeaterSignal(
        id: id,
        name: existing?.name,
        rxSnr: entry.rxSnr,
        txSnr: entry.txSnr,
        txState: txState,
        rssi: existing?.rssi,
        rttMs: entry.rttMs == 0 ? nil : Int(entry.rttMs),
        lastHeard: now.addingTimeInterval(-Double(entry.ageSeconds)),
        publicKey: existing?.publicKey,
        lastProbeAt: existing?.lastProbeAt,
        isDeviceBest: entry.isBest
      )
    }
  }

  // MARK: - Probe bookkeeping

  /// Marks a probe as sent: TX goes to `.measuring` and the probe clock starts.
  ///
  /// Deliberately does not re-order: a row must not jump down the list the moment the user
  /// taps "ping", only when the answer changes what it is worth.
  mutating func markProbeSent(_ id: NodeHexID, now: Date) {
    update(id) {
      $0.txState = .measuring
      $0.lastProbeAt = now
    }
  }

  /// Applies a probe reply.
  ///
  /// The local SNR is smoothed 75/25 like any other RX reading. A reply carrying the
  /// remote SNR measures the TX leg and clears the failure count; a reply without one
  /// leaves TX unmeasured and counts as a failure, so backoff keeps the engine from
  /// hammering a link that cannot report back.
  @discardableResult
  mutating func applyProbeReply(
    _ reply: RepeaterProbeReply,
    to id: NodeHexID,
    rttMs: Int,
    now: Date
  ) -> Bool {
    let previousBest = repeaters.first?.id
    update(id) { entry in
      entry.rttMs = rttMs
      entry.rxSnr = entry.rxSnr.map { ($0 * 3 + reply.localSnr) / 4 } ?? reply.localSnr
      entry.lastHeard = now
      if let remoteSnr = reply.remoteSnr {
        entry.txSnr = remoteSnr
        entry.txState = .measured(SNRQuality(snr: remoteSnr))
        entry.failCount = 0
      } else {
        entry.txState = .failed
        entry.failCount += 1
      }
    }
    return sort(previousBest: previousBest)
  }

  /// Records a probe that never came back.
  @discardableResult
  mutating func markProbeFailed(_ id: NodeHexID) -> Bool {
    let previousBest = repeaters.first?.id
    update(id) {
      $0.txState = .failed
      $0.failCount += 1
    }
    return sort(previousBest: previousBest)
  }

  /// Resets every entry for a full re-measurement pass.
  mutating func beginFullRefresh() {
    for index in repeaters.indices {
      repeaters[index].failCount = 0
      repeaters[index].txState = .measuring
    }
  }

  /// Fails whatever is still in flight at the end of a full refresh.
  mutating func failOutstandingMeasurements() {
    for index in repeaters.indices where repeaters[index].isMeasuring {
      repeaters[index].txState = .failed
      repeaters[index].failCount += 1
    }
    sort(previousBest: repeaters.first?.id)
  }

  /// Sets a resolved display name.
  mutating func setName(_ name: String?, for id: NodeHexID) {
    update(id) { $0.name = name }
  }

  // MARK: - Staleness

  /// Drops entries not heard within ``SignalBarsPolicy/staleThreshold``, returning what
  /// was removed so in-flight probes for them can be cancelled.
  @discardableResult
  mutating func pruneStale(now: Date) -> [NodeHexID] {
    let cutoff = now.addingTimeInterval(-policy.staleThreshold)
    let removed = repeaters.filter { $0.lastHeard < cutoff }.map(\.id)
    guard !removed.isEmpty else { return [] }
    repeaters.removeAll { $0.lastHeard < cutoff }
    return removed
  }

  /// The rows the list should render: the table minus entries older than
  /// ``SignalBarsPolicy/staleHideThreshold`` and minus dismissed entries not heard since.
  func displayed(now: Date) -> [RepeaterSignal] {
    let cutoff = policy.staleHideThreshold.map { now.addingTimeInterval(-$0) }
    return repeaters.filter { repeater in
      if let cutoff, repeater.lastHeard < cutoff { return false }
      if let dismissedAt = dismissal(for: repeater.id), repeater.lastHeard <= dismissedAt {
        return false
      }
      return true
    }
  }

  /// Hides one repeater until it is heard again.
  mutating func dismiss(_ id: NodeHexID, now: Date) {
    dismissals[self[id]?.id ?? id] = now
  }

  /// Hides every entry currently past the hide window in one action. With auto-hide off,
  /// "stale" falls back to ``SignalBarsPolicy/manualClearWindow``.
  mutating func clearStale(now: Date) {
    let cutoff = now.addingTimeInterval(-staleWindow)
    for repeater in repeaters where repeater.lastHeard < cutoff {
      dismissals[repeater.id] = now
    }
  }

  /// Whether anything is stale enough for ``clearStale(now:)`` to act on — that is, a row
  /// past the window that has not already been dismissed.
  ///
  /// Legacy answered this from age alone, so the flag stayed true forever once anything
  /// went quiet and the "clear stale" affordance never switched off. Taking dismissals
  /// into account makes the flag mean "this action would do something".
  func hasStale(now: Date) -> Bool {
    let cutoff = now.addingTimeInterval(-staleWindow)
    return repeaters.contains { repeater in
      guard repeater.lastHeard < cutoff else { return false }
      guard let dismissedAt = dismissal(for: repeater.id) else { return true }
      return repeater.lastHeard > dismissedAt
    }
  }

  private var staleWindow: TimeInterval {
    policy.staleHideThreshold ?? policy.manualClearWindow
  }

  /// The dismissal recorded for this node, at whatever hash width it was recorded under.
  private func dismissal(for id: NodeHexID) -> Date? {
    if let exact = dismissals[id] { return exact }
    return dismissals.first { $0.key.identifiesSameNode(as: id) }?.value
  }

  // MARK: - Ordering

  /// Re-orders best link first and reports whether the head changed since `previousBest`,
  /// which the engine uses to bump a newly promoted best link to the front of the probe
  /// queue. Callers capture the head *before* they mutate, so a first insertion counts as
  /// a change.
  @discardableResult
  private mutating func sort(previousBest: NodeHexID?) -> Bool {
    repeaters.sort(by: RepeaterSignal.isOrderedBefore)
    return repeaters.first?.id != previousBest
  }

  /// Clears the probe clock so the given repeater is due immediately.
  mutating func prioritizeNextProbe(for id: NodeHexID) {
    update(id) { $0.lastProbeAt = nil }
  }

  private mutating func update(_ id: NodeHexID, mutate: (inout RepeaterSignal) -> Void) {
    guard let index = index(of: id) else { return }
    mutate(&repeaters[index])
  }
}
