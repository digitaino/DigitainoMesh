import Foundation
import MC1Services

/// The decision half of the automatic observer-count lookup: which of a
/// conversation's messages are worth asking the CoreScope server about right now,
/// and how many distinct observers a batch of observations represents.
///
/// Pure by design — no clock, no network, no store. The polling loop in
/// `ChatViewModel+PacketScope` supplies `now` and does the I/O, so the cadence
/// rules and the counting rule are testable at fixed dates.
enum PacketScopeObserverCounts {
  /// What one pass did, which is what decides how long to wait for the next one
  /// and whether the opening sweep has yet been spent.
  ///
  /// Lives here rather than on the loop so both decisions that read it are pure
  /// functions with tests — the loop is a `while` around a sleep and is not.
  enum PassOutcome: Equatable {
    /// The batch came back and every candidate was written.
    case completed
    /// Nothing was asked — no candidate, or no hash yet.
    case idle
    /// The request threw. Back off rather than retrying on the burst cadence.
    case failed
  }

  /// A send is "hot" for this long: the mesh is still repeating it and observers
  /// are still reporting fast, so the count moves while you watch.
  static let hotWindow: TimeInterval = 5 * 60
  /// The opening stretch of the hot window, when observers report in a rush.
  ///
  /// Rafael, 2026-09-04, from a live one: "right now we see one observer and then
  /// after some time it jumps up to whatever other number of observers. I would
  /// love for it to count up as the observations come in, not after some set time.
  /// It just looks like it's not working." A badge that steps 1 → 8 has told the
  /// truth twice and looked broken in between; the fix is to ask often enough that
  /// the arrivals show up as arrivals.
  static let burstWindow: TimeInterval = 90
  /// Re-poll interval inside the burst window — fast enough that a rush of
  /// receptions reads as a count climbing rather than one late jump.
  static let burstRefreshInterval: TimeInterval = 4
  /// Re-poll interval for the rest of the hot window, once the rush is over and
  /// stragglers are what is left.
  static let hotRefreshInterval: TimeInterval = 12
  /// Past the rush but still moving. Observers reach the server over MQTT and the
  /// server ingests with a lag of seconds to minutes, so a reception of a packet
  /// sent ten minutes ago is ordinary rather than surprising.
  ///
  /// Rafael, 2026-09-04, on the second look: "it just stays the same count for too
  /// long. Like it's not refreshing properly and after some time it then jumps."
  /// This tier is the answer. Before it the cadence fell off a cliff at the end of
  /// the hot window — a message four minutes old waited a full **hour** for its
  /// next pass, so every observer that reported in between was invisible until the
  /// hour was up, and then arrived all at once. Faster polling in the first ninety
  /// seconds could not fix that, because the stall happened after it.
  static let warmWindow: TimeInterval = 30 * 60
  /// Re-poll interval in the warm window. A minute is far below the rate at which
  /// late receptions land, and a chat left open all day costs one request a minute.
  static let warmRefreshInterval: TimeInterval = 60
  /// Beyond this age a send is settled: worth one confirmation pass if the app
  /// was not open when it landed, but not worth watching.
  static let coldWindow: TimeInterval = 24 * 60 * 60
  /// Re-poll interval in the cold window.
  static let coldRefreshInterval: TimeInterval = 60 * 60
  /// What the loop waits when no message is due — nothing to watch, so this is
  /// only how quickly a *newly sent* message gets its first pass if its echo
  /// arrives without nudging the loop.
  static let idleInterval: TimeInterval = 20
  /// How long the loop waits while a fresh channel send is still waiting for the
  /// echo that stamps its content hash.
  ///
  /// Rafael, third report, 2026-09-05: the badge sits on `…` for twenty seconds
  /// after a send and then arrives at its number in one step. The hash is stamped
  /// by the first echo and reaches `messages` only when the coalesced reload lands,
  /// which is normally *after* the `.heardRepeatRecorded` nudge — so the nudged pass
  /// finds no candidate, and the loop used to sleep the full ``idleInterval`` before
  /// looking again. Nothing goes on the wire until a hash exists, so re-scanning the
  /// list this often costs an in-memory filter and no request.
  static let hashPendingInterval: TimeInterval = 2
  /// The floor on a computed wait. Keeps a permanently-due message (one whose
  /// pass keeps failing) from becoming a spin.
  static let minimumInterval: TimeInterval = 1
  /// The server's per-request ceiling. Also the batch size here, so one pass is
  /// one request.
  static let maxBatchSize = 100

  /// How long a send of this age waits between passes, or nil once it is settled
  /// for good.
  ///
  /// Four tiers, and the shape matters more than any one number: each step up is
  /// at most a five-fold slowdown, so there is no age at which the badge stops
  /// moving for long enough to look broken. The tier that used to be missing is
  /// ``warmWindow`` — without it the wait went from 12 s to an hour in one step,
  /// which is precisely how a count comes to sit still and then jump.
  static func refreshInterval(forAge age: TimeInterval) -> TimeInterval? {
    if age <= burstWindow { return burstRefreshInterval }
    if age <= hotWindow { return hotRefreshInterval }
    if age <= warmWindow { return warmRefreshInterval }
    if age <= coldWindow { return coldRefreshInterval }
    return nil
  }

  /// Messages to look up on this pass, newest send first, capped at
  /// ``maxBatchSize``.
  ///
  /// Only the user's own sent messages with a known packet hash are eligible —
  /// a received message's hash is another node's business, and a message with no
  /// hash has no echo to look up. A candidate is then one of:
  ///
  /// - never checked (the count is nil), at any age;
  /// - due under ``refreshInterval(forAge:)`` — 4 s for the first 90 s, 12 s to
  ///   five minutes, a minute to half an hour, an hour inside the day.
  ///
  /// `ignoringCadence` drops the interval test and keeps everything else, which is
  /// what the loop's first pass uses. A conversation that has been closed polls
  /// nothing, so a message sent while you were elsewhere can be an hour into the
  /// cold tier by the time you look at it; without the sweep the badge would show
  /// you the number from before you left and wait out the rest of the hour.
  ///
  /// Anything older than a day is left alone once it has a count: the mesh has
  /// long since stopped repeating it and the figure will not move again.
  ///
  /// The newest-first sort is what makes the cap safe: in a conversation with
  /// more than 100 eligible sends, the ones the user is looking at win.
  static func candidates(
    in messages: [MessageDTO],
    now: Date,
    ignoringCadence: Bool = false
  ) -> [MessageDTO] {
    let eligible = messages.filter { message in
      guard message.isOutgoing, message.packetContentHash != nil else { return false }
      guard let checkedAt = message.packetObserversCheckedAt else { return true }
      guard let interval = refreshInterval(forAge: now.timeIntervalSince(message.senderDate)) else {
        return false
      }
      if ignoringCadence { return true }
      return now.timeIntervalSince(checkedAt) > interval
    }

    return Array(
      eligible
        .sorted { $0.senderDate > $1.senderDate }
        .prefix(maxBatchSize)
    )
  }

  /// How long the loop should wait before its next pass: the shortest time until
  /// any message on screen comes due, or ``idleInterval`` when none will.
  ///
  /// The loop used to sleep a flat twenty seconds, which set the badge's real
  /// resolution to twenty seconds however fast the tiers above said to poll —
  /// the whole reason the count arrived as one jump. Deriving the wait from the
  /// same rule ``candidates(in:now:)`` uses means the two can never disagree.
  ///
  /// One message that is not yet a candidate still sets the wait: a **channel**
  /// send inside the hot window whose hash has not been stamped. That message is
  /// about to become lookup-able and the loop has to be awake to notice — see
  /// ``hashPendingInterval``. DMs are excluded because they never get a hash at
  /// all (nothing repeats a DM, so no echo ever stamps one), and a chat full of
  /// them would otherwise re-scan every two seconds forever.
  ///
  /// Never returns less than ``minimumInterval``: a message whose pass keeps
  /// failing stays due forever, and a zero wait on that would be a spin.
  static func delayUntilNextPass(in messages: [MessageDTO], now: Date) -> TimeInterval {
    var soonest = idleInterval
    for message in messages {
      guard message.isOutgoing else { continue }
      guard message.packetContentHash != nil else {
        if message.isChannelMessage, now.timeIntervalSince(message.senderDate) <= hotWindow {
          soonest = Swift.min(soonest, hashPendingInterval)
        }
        continue
      }
      guard let checkedAt = message.packetObserversCheckedAt else { return minimumInterval }
      guard let interval = refreshInterval(forAge: now.timeIntervalSince(message.senderDate)) else {
        continue
      }
      soonest = Swift.min(soonest, interval - now.timeIntervalSince(checkedAt))
    }
    return Swift.max(minimumInterval, soonest)
  }

  /// Whether the opening sweep is still owed after a pass with this outcome.
  ///
  /// Only a pass that reached the server spends it. `.failed` was always exempt —
  /// a chat opened with no signal must still get its refresh once there is one —
  /// but `.idle` was not, and that was a defect: `startObserverCountPolling` runs
  /// on `.onAppear`, which on a cold conversation open happens *before* the first
  /// page of messages lands, so the sweep pass looked at an empty list, returned
  /// `.idle`, and the sweep was spent on nothing. The badge then showed whatever
  /// the database held until the ordinary cadence came round — up to an hour for
  /// a message sent while the user was elsewhere, which is exactly the sit-still-
  /// then-jump Rafael has reported three times.
  static func retainsOpeningSweep(after outcome: PassOutcome) -> Bool {
    outcome != .completed
  }

  /// How long the loop waits after a pass with this outcome.
  ///
  /// `.completed` and `.idle` both ask ``delayUntilNextPass(in:now:)``: an idle
  /// pass means nothing was *due*, not that nothing is coming, and the flat
  /// ``idleInterval`` it used to take is what made a fresh send with no hash yet
  /// wait twenty seconds for its first look. `.failed` keeps the flat interval as
  /// a back-off — a due message stays due, so deriving its wait from the cadence
  /// would retry every second for as long as the server is down.
  static func delay(
    after outcome: PassOutcome,
    in messages: [MessageDTO],
    now: Date
  ) -> TimeInterval {
    switch outcome {
    case .completed, .idle:
      delayUntilNextPass(in: messages, now: now)
    case .failed:
      idleInterval
    }
  }

  /// Distinct observers in one packet's observations.
  ///
  /// An observer reports the same packet many times (one row per reception path),
  /// so the raw count is not the answer. Ids are folded case-insensitively because
  /// the server's roster reports them uppercase and its observations lowercase —
  /// counting them raw would double one observer that appears in both casings.
  static func distinctObservers(_ observations: [PacketScopeObservation]) -> Int {
    Set(observations.map { $0.observerID.lowercased() }).count
  }
}
