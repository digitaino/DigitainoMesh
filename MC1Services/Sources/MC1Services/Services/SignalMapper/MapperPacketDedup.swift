import Foundation

/// Session-scoped "have I already counted this packet?" memory, keyed by
/// `RxLogEntryDTO.packetHash`.
///
/// The RX log can surface the same packet more than once — a re-decryption pass re-yields
/// an entry, and a flood packet reaching us by two paths shares a hash. Counting either
/// twice would inflate a cell's packet count without any new information about coverage.
///
/// Bounded FIFO rather than true LRU: entries are only ever inserted, never looked up
/// again after the first hit, so recency of *use* and recency of *insertion* are the same
/// thing here and the extra bookkeeping would buy nothing.
struct MapperPacketDedup {
  private var seen: Set<String> = []
  private var order: [String] = []
  private let capacity: Int

  init(capacity: Int = 512) {
    self.capacity = Swift.max(1, capacity)
    order.reserveCapacity(self.capacity)
  }

  /// Records a packet hash.
  /// - Returns: `true` when this hash is new (the caller should process the packet),
  ///   `false` when it has already been seen this session.
  mutating func admit(_ packetHash: String) -> Bool {
    guard seen.insert(packetHash).inserted else { return false }
    order.append(packetHash)
    if order.count > capacity {
      seen.remove(order.removeFirst())
    }
    return true
  }

  /// Forgets everything. Called when a capture session starts, so a new session re-counts
  /// packets it happened to see during the previous one.
  mutating func reset() {
    seen.removeAll(keepingCapacity: true)
    order.removeAll(keepingCapacity: true)
  }
}
