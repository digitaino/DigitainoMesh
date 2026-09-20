import Foundation
@testable import MC1
import MC1Services
import Testing

/// The decision half of the automatic observer-count lookup, pinned at fixed
/// dates: which messages a pass asks about, in what order, how many it may take,
/// and how a batch of observations collapses to a distinct-observer count.
///
/// Every date here is literal — the rules are all relative to `now`, so a test
/// that read the wall clock would be a test of the machine's timing.
@Suite("PacketScopeObserverCounts")
struct PacketScopeObserverCountsTests {
  /// Fixed "now" for every case below.
  private let now = Date(timeIntervalSince1970: 1_788_400_000)

  private func makeMessage(
    id: UUID = UUID(),
    isOutgoing: Bool = true,
    hash: String? = "286dcbdeab84b458",
    sentSecondsAgo: TimeInterval,
    checkedSecondsAgo: TimeInterval? = nil,
    count: Int? = nil,
    // nil makes it a DM, which never gets a hash at all.
    channelIndex: UInt8? = 3
  ) -> MessageDTO {
    let sentAt = now.addingTimeInterval(-sentSecondsAgo)
    return MessageDTO(
      id: id,
      radioID: UUID(),
      contactID: channelIndex == nil ? UUID() : nil,
      channelIndex: channelIndex,
      text: "hello mesh",
      // `senderDate` is derived from `timestamp`, which is what the candidate
      // rule reads as the send moment.
      timestamp: UInt32(sentAt.timeIntervalSince1970),
      createdAt: sentAt,
      direction: isOutgoing ? .outgoing : .incoming,
      status: .sent,
      textType: .plain,
      ackCode: nil,
      pathLength: 1,
      snr: nil,
      senderKeyPrefix: nil,
      senderNodeName: nil,
      isRead: true,
      replyToID: nil,
      roundTripTime: nil,
      heardRepeats: 0,
      retryAttempt: 0,
      maxRetryAttempts: 0,
      packetContentHash: hash,
      packetObserverCount: count,
      packetObserversCheckedAt: checkedSecondsAgo.map { now.addingTimeInterval(-$0) }
    )
  }

  private func makeObservation(id: Int, observerID: String) -> PacketScopeObservation {
    PacketScopeObservation(
      id: id,
      observerID: observerID,
      observerName: "Observer \(id)",
      observerIATA: nil,
      snr: nil,
      rssi: nil,
      pathHops: [],
      resolvedPath: [],
      timestamp: nil
    )
  }

  // MARK: - Eligibility

  @Test
  func `a received message is never a candidate, however fresh`() {
    let message = makeMessage(isOutgoing: false, sentSecondsAgo: 10)
    #expect(PacketScopeObserverCounts.candidates(in: [message], now: now).isEmpty)
  }

  @Test
  func `a sent message with no content hash is never a candidate`() {
    let message = makeMessage(hash: nil, sentSecondsAgo: 10)
    #expect(PacketScopeObserverCounts.candidates(in: [message], now: now).isEmpty)
  }

  // MARK: - The four branches of the candidate rule

  @Test
  func `a never-checked message is a candidate at any age`() {
    let fresh = makeMessage(sentSecondsAgo: 5)
    let ancient = makeMessage(sentSecondsAgo: 30 * 24 * 60 * 60)
    let picked = PacketScopeObserverCounts.candidates(in: [fresh, ancient], now: now)
    #expect(picked.count == 2)
  }

  @Test
  func `inside the burst window a message re-checks after four seconds, not before`() {
    let stale = makeMessage(sentSecondsAgo: 60, checkedSecondsAgo: 5, count: 2)
    let justChecked = makeMessage(sentSecondsAgo: 60, checkedSecondsAgo: 3, count: 2)

    #expect(PacketScopeObserverCounts.candidates(in: [stale], now: now).count == 1)
    #expect(PacketScopeObserverCounts.candidates(in: [justChecked], now: now).isEmpty)
  }

  @Test
  func `past the burst window the hot cadence slows to twelve seconds`() {
    // Two minutes old: out of the 90 s burst, still inside the three-minute hot window.
    let stale = makeMessage(sentSecondsAgo: 120, checkedSecondsAgo: 13, count: 2)
    let justChecked = makeMessage(sentSecondsAgo: 120, checkedSecondsAgo: 11, count: 2)

    #expect(PacketScopeObserverCounts.candidates(in: [stale], now: now).count == 1)
    // 5 s would have re-qualified it during the burst; past it, it waits.
    #expect(PacketScopeObserverCounts.candidates(in: [justChecked], now: now).isEmpty)
  }

  // MARK: - The wait between passes

  @Test
  func `a message never checked is due immediately`() {
    let fresh = makeMessage(sentSecondsAgo: 2)
    #expect(PacketScopeObserverCounts.delayUntilNextPass(in: [fresh], now: now) == 1)
  }

  @Test
  func `the wait is the time until the soonest message comes due`() {
    let burst = makeMessage(sentSecondsAgo: 30, checkedSecondsAgo: 1, count: 1)
    let cold = makeMessage(sentSecondsAgo: 4 * 60 * 60, checkedSecondsAgo: 60, count: 4)

    // The burst message is due 3 s from now; the cold one in the best part of an hour.
    #expect(PacketScopeObserverCounts.delayUntilNextPass(in: [cold, burst], now: now) == 3)
  }

  @Test
  func `a due message waits the floor rather than spinning`() {
    // Due 40 s ago and still unanswered — a failing pass must not become a spin.
    let overdue = makeMessage(sentSecondsAgo: 60, checkedSecondsAgo: 40, count: 1)
    #expect(PacketScopeObserverCounts.delayUntilNextPass(in: [overdue], now: now) == 1)
  }

  @Test
  func `nothing to watch means the idle wait`() {
    let settled = makeMessage(sentSecondsAgo: 3 * 24 * 60 * 60, checkedSecondsAgo: 10, count: 6)
    let incoming = makeMessage(isOutgoing: false, sentSecondsAgo: 10)

    #expect(
      PacketScopeObserverCounts.delayUntilNextPass(in: [settled, incoming], now: now)
        == PacketScopeObserverCounts.idleInterval
    )
    #expect(PacketScopeObserverCounts.delayUntilNextPass(in: [], now: now)
      == PacketScopeObserverCounts.idleInterval)
  }

  @Test
  func `the wait never exceeds the idle interval even when every message is cold`() {
    let cold = makeMessage(sentSecondsAgo: 2 * 60 * 60, checkedSecondsAgo: 1, count: 3)
    #expect(
      PacketScopeObserverCounts.delayUntilNextPass(in: [cold], now: now)
        <= PacketScopeObserverCounts.idleInterval
    )
  }

  @Test
  func `past the hot window the cadence slows to a minute, not to an hour`() {
    // Ten minutes old: out of the five-minute hot window, inside the warm one. The
    // defect this pins is the cliff Rafael saw twice — the wait used to jump from
    // 12 s straight to an hour here, so every observer reporting in between was
    // invisible until the hour was up and then arrived as one step.
    let stale = makeMessage(sentSecondsAgo: 10 * 60, checkedSecondsAgo: 61, count: 2)
    let justChecked = makeMessage(sentSecondsAgo: 10 * 60, checkedSecondsAgo: 45, count: 2)

    #expect(PacketScopeObserverCounts.candidates(in: [stale], now: now).count == 1)
    #expect(PacketScopeObserverCounts.candidates(in: [justChecked], now: now).isEmpty)
    #expect(PacketScopeObserverCounts.refreshInterval(forAge: 10 * 60) == 60)
  }

  @Test
  func `past the warm window the cadence drops to an hour`() {
    // Forty minutes old: out of the half-hour warm window, inside the day.
    let stale = makeMessage(sentSecondsAgo: 40 * 60, checkedSecondsAgo: 3601, count: 2)
    let recentlyChecked = makeMessage(sentSecondsAgo: 40 * 60, checkedSecondsAgo: 120, count: 2)

    #expect(PacketScopeObserverCounts.candidates(in: [stale], now: now).count == 1)
    // 120 s would have re-qualified it inside the warm window; past it, it waits.
    #expect(PacketScopeObserverCounts.candidates(in: [recentlyChecked], now: now).isEmpty)
  }

  @Test
  func `no tier step inside the moving window is big enough to look like a stall`() {
    // The shape is the guarantee, not any single number. While a count can still
    // move, no step up may slow the badge by more than five-fold: that is what
    // stops it going quiet for long enough to read as broken and then jumping,
    // which is the defect Rafael reported twice. The last step, warm to cold, is
    // deliberately exempt and is a sixty-fold one — half an hour after a send the
    // mesh has stopped repeating and the figure genuinely does not move again, so
    // an hourly confirmation is the honest cadence rather than a stall. What
    // covers a late arrival there is the opening sweep, not the interval.
    let movingWindow: [TimeInterval] = [0, 90, 5 * 60, 30 * 60]
    let intervals = movingWindow.compactMap { PacketScopeObserverCounts.refreshInterval(forAge: $0) }
    #expect(intervals.count == movingWindow.count)
    for (previous, next) in zip(intervals, intervals.dropFirst()) {
      #expect(next <= previous * 5)
    }
  }

  // MARK: - Waiting on a hash that has not landed yet

  @Test
  func `a fresh channel send with no hash yet is looked at again in two seconds`() {
    // Rafael's third report. The hash is stamped by the first echo and reaches
    // `messages` only when the coalesced reload lands — which is after the nudge
    // that echo fires, so the nudged pass finds nothing. Before this rule the loop
    // then slept the full idle interval, and a badge that could have been correct
    // in four seconds sat on `…` for twenty and then arrived at its number at once.
    let pending = makeMessage(hash: nil, sentSecondsAgo: 3)

    #expect(PacketScopeObserverCounts.candidates(in: [pending], now: now).isEmpty)
    #expect(
      PacketScopeObserverCounts.delayUntilNextPass(in: [pending], now: now)
        == PacketScopeObserverCounts.hashPendingInterval
    )
  }

  @Test
  func `a DM is never waited on for a hash it will never get`() {
    // Nothing repeats a DM, so no echo ever stamps one a content hash. A chat full
    // of them would otherwise re-scan every two seconds for the rest of the day.
    let dm = makeMessage(hash: nil, sentSecondsAgo: 3, channelIndex: nil)

    #expect(
      PacketScopeObserverCounts.delayUntilNextPass(in: [dm], now: now)
        == PacketScopeObserverCounts.idleInterval
    )
  }

  @Test
  func `past the hot window a hash that never arrived stops being waited for`() {
    // Six minutes on, no echo has been heard and none is coming: the two-second
    // scan is bounded by the hot window rather than running for the life of the chat.
    let abandoned = makeMessage(hash: nil, sentSecondsAgo: 6 * 60)

    #expect(
      PacketScopeObserverCounts.delayUntilNextPass(in: [abandoned], now: now)
        == PacketScopeObserverCounts.idleInterval
    )
  }

  @Test
  func `a received message with no hash never sets the wait`() {
    let incoming = makeMessage(isOutgoing: false, hash: nil, sentSecondsAgo: 3)

    #expect(
      PacketScopeObserverCounts.delayUntilNextPass(in: [incoming], now: now)
        == PacketScopeObserverCounts.idleInterval
    )
  }

  // MARK: - What a pass's outcome decides

  @Test
  func `only a pass that reached the server spends the opening sweep`() {
    // `.idle` used to spend it, which lost the sweep on every cold open:
    // `startObserverCountPolling` runs on `.onAppear`, before the first page of
    // messages has landed, so the sweep pass looked at an empty list and was gone.
    #expect(!PacketScopeObserverCounts.retainsOpeningSweep(after: .completed))
    #expect(PacketScopeObserverCounts.retainsOpeningSweep(after: .idle))
    #expect(PacketScopeObserverCounts.retainsOpeningSweep(after: .failed))
  }

  @Test
  func `an idle pass takes its wait from the cadence rather than the flat interval`() {
    let pending = makeMessage(hash: nil, sentSecondsAgo: 3)

    #expect(
      PacketScopeObserverCounts.delay(after: .idle, in: [pending], now: now)
        == PacketScopeObserverCounts.hashPendingInterval
    )
    #expect(
      PacketScopeObserverCounts.delay(after: .completed, in: [pending], now: now)
        == PacketScopeObserverCounts.hashPendingInterval
    )
  }

  @Test
  func `a failed pass backs off however soon a message is due`() {
    // A message due but unreachable stays due, so deriving the wait from the
    // cadence here would retry every second for as long as the server is down.
    let overdue = makeMessage(sentSecondsAgo: 30, checkedSecondsAgo: 20, count: 1)

    #expect(
      PacketScopeObserverCounts.delayUntilNextPass(in: [overdue], now: now)
        == PacketScopeObserverCounts.minimumInterval
    )
    #expect(
      PacketScopeObserverCounts.delay(after: .failed, in: [overdue], now: now)
        == PacketScopeObserverCounts.idleInterval
    )
  }

  // MARK: - The opening sweep

  @Test
  func `the opening sweep re-checks a message the cadence would have made wait`() {
    // A message sent while the conversation was closed: nothing polled it, and it is
    // now deep enough in the cold tier that the ordinary rule would leave it alone
    // for another 59 minutes while showing a number from before.
    let settling = makeMessage(sentSecondsAgo: 2 * 60 * 60, checkedSecondsAgo: 60, count: 1)

    #expect(PacketScopeObserverCounts.candidates(in: [settling], now: now).isEmpty)
    #expect(
      PacketScopeObserverCounts.candidates(in: [settling], now: now, ignoringCadence: true).count == 1
    )
  }

  @Test
  func `the opening sweep still refuses what is not ours and what is settled`() {
    // The sweep drops the interval test and nothing else: an incoming message, a
    // message with no hash to ask about, and one older than a day stay out of it.
    let incoming = makeMessage(isOutgoing: false, sentSecondsAgo: 60)
    let hashless = makeMessage(hash: nil, sentSecondsAgo: 60)
    let ancient = makeMessage(sentSecondsAgo: 3 * 24 * 60 * 60, checkedSecondsAgo: 10, count: 6)

    #expect(
      PacketScopeObserverCounts
        .candidates(in: [incoming, hashless, ancient], now: now, ignoringCadence: true)
        .isEmpty
    )
  }

  @Test
  func `a message older than a day is left alone once it has a count`() {
    let settled = makeMessage(
      sentSecondsAgo: 25 * 60 * 60,
      checkedSecondsAgo: 24 * 60 * 60,
      count: 5
    )
    #expect(PacketScopeObserverCounts.candidates(in: [settled], now: now).isEmpty)
  }

  // MARK: - Ordering and the batch cap

  @Test
  func `candidates come back newest send first`() {
    let oldest = makeMessage(sentSecondsAgo: 300)
    let middle = makeMessage(sentSecondsAgo: 200)
    let newest = makeMessage(sentSecondsAgo: 100)

    let picked = PacketScopeObserverCounts.candidates(in: [oldest, newest, middle], now: now)
    #expect(picked.map(\.id) == [newest.id, middle.id, oldest.id])
  }

  @Test
  func `the batch is capped at a hundred and the cap keeps the newest`() {
    // 150 never-checked sends, one per second going back from two minutes ago.
    let messages = (1...150).map { makeMessage(sentSecondsAgo: TimeInterval($0)) }
    let picked = PacketScopeObserverCounts.candidates(in: messages, now: now)

    #expect(picked.count == PacketScopeObserverCounts.maxBatchSize)
    #expect(picked.count == 100)
    // messages[0] is the newest (1 s ago); the 100 kept are the first 100 of them.
    #expect(picked.first?.id == messages[0].id)
    #expect(picked.last?.id == messages[99].id)
    let keptIDs = Set(picked.map(\.id))
    #expect(!keptIDs.contains(messages[149].id))
  }

  // MARK: - Distinct observers

  @Test
  func `no observations is zero, not a missing answer`() {
    #expect(PacketScopeObserverCounts.distinctObservers([]) == 0)
  }

  @Test
  func `one observer reporting a packet many times counts once`() {
    let observations = (1...6).map { makeObservation(id: $0, observerID: "obs-alpha") }
    #expect(PacketScopeObserverCounts.distinctObservers(observations) == 1)
  }

  @Test
  func `ids differing only in case are the same observer`() {
    // The roster reports ids uppercase and observations lowercase; counting them
    // raw would double every observer that turns up in both casings.
    let observations = [
      makeObservation(id: 1, observerID: "OBS-ALPHA"),
      makeObservation(id: 2, observerID: "obs-alpha"),
      makeObservation(id: 3, observerID: "Obs-Alpha"),
      makeObservation(id: 4, observerID: "obs-beta")
    ]
    #expect(PacketScopeObserverCounts.distinctObservers(observations) == 2)
  }

  @Test
  func `mixed repeats across several observers count once each`() {
    let observations = [
      makeObservation(id: 1, observerID: "obs-alpha"),
      makeObservation(id: 2, observerID: "OBS-BETA"),
      makeObservation(id: 3, observerID: "obs-alpha"),
      makeObservation(id: 4, observerID: "obs-gamma"),
      makeObservation(id: 5, observerID: "obs-beta"),
      makeObservation(id: 6, observerID: "obs-gamma")
    ]
    #expect(PacketScopeObserverCounts.distinctObservers(observations) == 3)
  }
}
