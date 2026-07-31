import Foundation

/// In-flight probe bookkeeping: which trace tag belongs to which repeater, when it went
/// out, and when it should be given up on.
///
/// Timeouts are data, not sleeping tasks — the engine sweeps ``expired(now:)`` on each
/// cycle. That makes a probe timeout something a test can produce by moving a fake clock
/// forward instead of by waiting.
struct SignalBarsProbeTracker: Sendable, Equatable {
  /// One outstanding probe.
  struct Probe: Sendable, Equatable {
    var tag: UInt32
    /// The repeater the probe was addressed to, at the hash width it was tracked under.
    var target: NodeHexID
    var sentAt: Date
    /// When the probe counts as lost; derived from the device's suggested timeout.
    var deadline: Date
  }

  private(set) var probes: [UInt32: Probe] = [:]

  var isEmpty: Bool {
    probes.isEmpty
  }

  var count: Int {
    probes.count
  }

  /// Records a probe as sent. A repeated tag replaces the older probe — the radio would
  /// not be able to tell their replies apart either.
  mutating func register(tag: UInt32, target: NodeHexID, now: Date, timeoutMs: Int) {
    probes[tag] = Probe(
      tag: tag,
      target: target,
      sentAt: now,
      deadline: now.addingTimeInterval(Double(timeoutMs) / 1000)
    )
  }

  /// Replaces an outstanding probe's deadline, keeping its original send time.
  ///
  /// A tag that is no longer outstanding — a reply already claimed it, or a sweep already
  /// wrote it off — is left alone: re-registering it would hand the next sweep a probe that
  /// is already resolved to fail.
  mutating func retime(tag: UInt32, timeoutMs: Int) {
    guard let probe = probes[tag] else { return }
    probes[tag] = Probe(
      tag: probe.tag,
      target: probe.target,
      sentAt: probe.sentAt,
      deadline: probe.sentAt.addingTimeInterval(Double(timeoutMs) / 1000)
    )
  }

  /// Claims the probe a reply belongs to, removing it. Returns `nil` for a tag that is not
  /// ours or has already timed out, so late and unsolicited replies are ignored.
  mutating func claim(tag: UInt32) -> Probe? {
    probes.removeValue(forKey: tag)
  }

  /// Removes and returns every probe whose deadline has passed.
  mutating func expired(now: Date) -> [Probe] {
    let lost = probes.values.filter { $0.deadline <= now }
    for probe in lost {
      probes.removeValue(forKey: probe.tag)
    }
    return lost.sorted { $0.sentAt < $1.sentAt }
  }

  /// Whether a probe is outstanding for this node, at any hash width.
  func hasProbe(for id: NodeHexID) -> Bool {
    probes.values.contains { $0.target.identifiesSameNode(as: id) }
  }

  /// Drops probes for repeaters that have left the table.
  mutating func cancelProbes(for ids: [NodeHexID]) {
    guard !ids.isEmpty else { return }
    probes = probes.filter { _, probe in
      !ids.contains { $0.identifiesSameNode(as: probe.target) }
    }
  }

  mutating func cancelAll() {
    probes.removeAll()
  }
}
