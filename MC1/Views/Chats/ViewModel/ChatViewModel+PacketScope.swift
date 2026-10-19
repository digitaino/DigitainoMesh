import Foundation
import MC1Services
import os.log

/// Every pass the observer-count loop makes, at `.info`, so the next report of a
/// badge that sits still can be answered with a Console log rather than a guess.
/// Content hashes go in the clear: 16 hex characters that were on the air already,
/// and useless without them. Message text never appears here.
private let observerCountLog = Logger(subsystem: "com.mc1", category: "ObserverCounts")

/// Automatic observer-count lookups for the eye badge on the user's own sent
/// bubbles.
///
/// ## Why the loop is conversation-scoped
/// This is the one place in the app that talks to CoreScope without the user
/// pressing anything, so the window in which it can do so is deliberately narrow:
/// the loop starts on the conversation's `.onAppear` and is cancelled on
/// `.onDisappear` and in `deinit`. Nothing polls in the background, on the
/// conversation list, or after the screen is gone.
///
/// ## What goes on the wire
/// Nothing but 16-hex content hashes, and only for messages this phone sent —
/// `PacketScopeObserverCounts.candidates` filters on `isOutgoing`, and
/// `PacketScopeService` independently re-checks the master opt-in and validates
/// every hash. Both gates are re-read from `UserDefaults` on each turn of the
/// loop, so flipping either switch off stops the requests without a restart.
extension ChatViewModel {
  /// The pass's one database write, injectable.
  ///
  /// Production always uses the default, which goes to `dataStore`. The seam
  /// exists because the ordering of that write against the in-flight in-memory
  /// update is the whole of the reload-race fix in ``runObserverCountPass(using:sweeping:persist:)``
  /// and `PersistenceStore` is an actor — from outside it, nothing can tell which
  /// of the two happened first.
  typealias ObserverCountPersist = @MainActor (UUID, Int, Date) async -> Void

  /// One pass's result: what it did, and what it did it to, ready for the log.
  struct ObserverCountPassReport {
    let outcome: PacketScopeObserverCounts.PassOutcome
    /// Candidate count, hashes sent, and `hash previous→reported→written` for each
    /// one. Built even for a pass that wrote nothing — an empty pass is precisely
    /// the case the owner's reports are about, and "candidates=0" is the evidence.
    let detail: String
  }

  /// Begins the conversation-scoped polling loop. Idempotent: a second call while
  /// a loop is already running is a no-op, so a re-`onAppear` does not stack loops.
  func startObserverCountPolling() {
    guard observerCountTask == nil else { return }
    guard Self.observerCountsEnabled() else {
      // Not an error: with the switches off there is nothing to poll for. The
      // settings-change path re-enters through `applyEnvInputs`.
      return
    }

    observerCountTask = Task { @MainActor [weak self] in
      let service = PacketScopeService()
      // The first pass ignores the cadence. Nothing polls while a conversation is
      // closed, so whatever is on screen when it opens may have been last checked
      // an hour ago and be showing a number the mesh moved past long since; the
      // sweep is what makes opening a chat mean "these figures are current".
      var isOpeningSweep = true
      while !Task.isCancelled {
        guard let model = self else { return }
        // Re-read the switches every turn rather than capturing them: turning
        // Packet Scope off mid-conversation must stop the requests immediately.
        var delay = PacketScopeObserverCounts.idleInterval
        if Self.observerCountsEnabled() {
          let sweeping = isOpeningSweep
          let report = await model.runObserverCountPass(using: service, sweeping: sweeping)
          // Only a pass that reached the server spends the sweep. `.idle` used to
          // spend it too, which lost the sweep on every cold open — see
          // `retainsOpeningSweep(after:)`.
          if !PacketScopeObserverCounts.retainsOpeningSweep(after: report.outcome) {
            isOpeningSweep = false
          }
          // Ask the same rule that picks candidates when the next one comes due, so
          // the badge's resolution is the cadence and not the sleep.
          delay = PacketScopeObserverCounts.delay(
            after: report.outcome,
            in: model.messages,
            now: Date()
          )
          observerCountLog.info(
            """
            pass sweep=\(sweeping, privacy: .public) \
            \(report.detail, privacy: .public) \
            outcome=\(String(describing: report.outcome), privacy: .public) \
            next=\(delay, format: .fixed(precision: 1), privacy: .public)s
            """
          )
        }
        guard await Self.waitForNextPass(
          seconds: delay,
          after: model.observerCountNudge,
          model: { self }
        ) else {
          return
        }
      }
    }
  }

  /// Sleeps `seconds` in one-second slices, returning early once
  /// `observerCountNudge` moves past `seen`. Returns `false` when the task was
  /// cancelled or the view model went away, which ends the loop.
  ///
  /// Slices rather than one long sleep because the loop is a poller, not a timer:
  /// `Task.sleep` cannot be woken, and a send landing mid-sleep has to be able to
  /// cut the wait short.
  ///
  /// The view model is re-read through a closure rather than captured strongly so
  /// a dismissed conversation is not kept alive for the length of the interval.
  @MainActor
  private static func waitForNextPass(
    seconds: TimeInterval,
    after seen: Int,
    model: @MainActor () -> ChatViewModel?
  ) async -> Bool {
    let slices = max(1, Int(seconds.rounded(.up)))
    for _ in 0..<slices {
      do {
        try await Task.sleep(for: .seconds(1))
      } catch {
        return false // cancelled
      }
      guard let current = model() else { return false }
      if current.observerCountNudge != seen { return true }
    }
    return true
  }

  /// Cancels the loop. Safe to call when nothing is running.
  func stopObserverCountPolling() {
    observerCountTask?.cancel()
    observerCountTask = nil
  }

  /// Asks the loop to run its next pass now instead of at the end of the current
  /// sleep. Used when an echo has just stamped a message's content hash, which is
  /// the moment a bubble first becomes lookup-able.
  ///
  /// A counter rather than a restart: restarting would cancel an in-flight request,
  /// and a burst of echoes for one send would otherwise starve every pass.
  func requestObserverCountPass() {
    observerCountNudge &+= 1
  }

  /// Both Packet Scope switches, ANDed. Read from `UserDefaults.standard` (the
  /// same store `@AppStorage` writes) rather than from `EnvInputs`, so the loop
  /// does not depend on a bake having happened.
  static func observerCountsEnabled(_ defaults: UserDefaults = .standard) -> Bool {
    func bool(_ key: AppStorageKey, _ fallback: Bool) -> Bool {
      defaults.object(forKey: key.rawValue) as? Bool ?? fallback
    }
    return bool(.packetScopeEnabled, AppStorageKey.defaultPacketScopeEnabled)
      && bool(.packetScopeObserverCountsEnabled, AppStorageKey.defaultPacketScopeObserverCountsEnabled)
  }

  /// One pass: pick candidates, ask for at most one batch, write what came back.
  ///
  /// A thrown error (feature disabled mid-flight, server unreachable, malformed
  /// response) leaves every cached count exactly as it was — a stale number is
  /// better than a bubble that flips to `…` whenever the network blips — and the
  /// loop simply tries again next turn.
  func runObserverCountPass(
    using service: some PacketScopeServicing,
    sweeping: Bool = false,
    persist: ObserverCountPersist? = nil
  ) async -> ObserverCountPassReport {
    let now = Date()
    let candidates = PacketScopeObserverCounts.candidates(in: messages, now: now, ignoringCadence: sweeping)
    guard !candidates.isEmpty else {
      return ObserverCountPassReport(outcome: .idle, detail: "candidates=0")
    }

    let hashes = Array(Set(candidates.compactMap(\.packetContentHash)))
    guard !hashes.isEmpty else {
      return ObserverCountPassReport(outcome: .idle, detail: "candidates=\(candidates.count) hashes=0")
    }

    let observationsByHash: [String: [PacketScopeObservation]]
    do {
      observationsByHash = try await service.observations(for: hashes)
    } catch {
      return ObserverCountPassReport(
        outcome: .failed,
        detail: "candidates=\(candidates.count) hashes=\(hashes.count) error=\(error)"
      )
    }
    guard !Task.isCancelled else {
      return ObserverCountPassReport(
        outcome: .failed,
        detail: "candidates=\(candidates.count) hashes=\(hashes.count) cancelled"
      )
    }

    let write = persist ?? { [self] id, count, checkedAt in
      try? await dataStore?.setMessageObserverCount(id: id, count: count, checkedAt: checkedAt)
    }

    let checkedAt = Date()
    var writes: [String] = []
    for candidate in candidates {
      guard let hash = candidate.packetContentHash else { continue }
      // A hash the server has never seen yields no rows, which is an honest zero
      // for this instance's observer network — not a missing answer. Except inside
      // the hot window: the server ingests with a lag of seconds to a minute, and a
      // "0" flashing up right after a send reads as the message having died. There
      // the badge keeps its "…", only the check time moves (so the loop keeps
      // asking on the hot cadence), and nothing is persisted, so a relaunch asks
      // again rather than trusting a zero that was only ever "not yet".
      let previous = candidate.packetObserverCount
      let reported = PacketScopeObserverCounts.distinctObservers(observationsByHash[hash] ?? [])
      let age = checkedAt.timeIntervalSince(candidate.senderDate)
      let isHot = age <= PacketScopeObserverCounts.hotWindow
      let isWarm = age <= PacketScopeObserverCounts.warmWindow
      if reported == 0, isHot {
        updateMessage(id: candidate.id) { $0.packetObserversCheckedAt = checkedAt }
        writes.append("\(hash) \(Self.describeCount(previous))→0→held")
        continue
      }
      // While a packet is still spreading the badge only ever climbs. Observers
      // accumulate on the server, so a smaller answer is a partial page or a slow
      // shard, not observers going away — and at a four-second cadence letting it
      // fall would show as a badge flickering down and back up mid-send.
      let count = isWarm ? max(reported, previous ?? 0) : reported
      // Persisted **before** the in-memory update, and the order is load-bearing.
      // Every echo fires `.heardRepeatRecorded`, which enqueues a reload: an async
      // re-fetch that replaces this row's in-memory DTO with the database's. With
      // the in-memory write first, a reload landing in the gap put the *older*
      // count and check time back on the bubble — the badge visibly reverting and
      // then, a cadence later, jumping again. Writing the row first means the worst
      // a reload can do is fetch the number this pass just established.
      //
      // Written when the number moved, and once more once the message has settled:
      // the timestamp is what keeps a settled message from being re-requested on
      // every relaunch, and a message still being polled every few seconds does not
      // need a database write each time to say it has not changed.
      if count != previous || !isWarm {
        await write(candidate.id, count, checkedAt)
      }
      updateMessage(id: candidate.id) {
        $0.packetObserverCount = count
        $0.packetObserversCheckedAt = checkedAt
      }
      writes.append("\(hash) \(Self.describeCount(previous))→\(reported)→\(count)")
    }
    return ObserverCountPassReport(
      outcome: .completed,
      detail: "candidates=\(candidates.count) hashes=\(hashes.count) [\(writes.joined(separator: ", "))]"
    )
  }

  /// A never-looked-up count for the log, where `nil` and `0` mean very different
  /// things and must not print the same.
  private static func describeCount(_ count: Int?) -> String {
    count.map(String.init) ?? "none"
  }
}
