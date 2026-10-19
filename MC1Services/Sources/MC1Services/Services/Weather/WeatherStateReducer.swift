import Foundation
import MeshWX

/// What applying one message did to a bot's state. The UI re-reads state on any change; the
/// cases exist so tests can pin every rule in spec §2.4 and §3–§8 individually.
public enum WeatherStateChange: Sendable, Hashable {
  /// A copy of a message already accepted — the same `seq` and the same content: the bot's
  /// second transmission of an unechoed packet, or a copy delivered late. Nothing else in the
  /// message is looked at.
  case duplicate(seq: UInt8)
  /// `seq` skipped ahead: at least one message was missed.
  case sequenceGap(expected: UInt8, received: UInt8)
  /// `seq` fell further behind than reordering explains, or repeated the newest `seq` with new
  /// content: the bot's counter started again. A revision 2 bot picks a random start every time it
  /// starts; a revision 3 bot saves its counter, so this is rare from one. A new stream starts at
  /// this message, which is applied normally; what went out around the restart is unknown, so it
  /// counts as a gap.
  case sequenceRestart(last: UInt8, received: UInt8)
  /// A `seq` a little behind the newest accepted one and not a known copy: a late resend or a
  /// reordered delivery. It is applied where it cannot undo something newer (`apply`), and the
  /// gap it reveals asks for a digest.
  case outOfOrder(seq: UInt8)
  case warningStored(MeshWXWarningIdentity, replacedExisting: Bool)
  /// A held warning ended. `reason` is the cancel's, or nil when a digest omitted it.
  case warningRemoved(MeshWXWarningIdentity, reason: MeshWXCancelReason?)
  /// A cancel for an identity the app never held; nothing to remove.
  case cancelForUnknown(MeshWXWarningIdentity)
  case digestApplied(missing: [MeshWXWarningIdentity], removed: [MeshWXWarningIdentity])
  /// The digest was built before the one already held — a late drain from the radio's queue —
  /// so it changed nothing.
  case digestIgnoredOlder(builtMinutes: UInt32)
  case observationsStored(stations: [UInt16])
  case forecastStored(point: UInt16)
  /// The held forecast for that point was issued later than this one; kept the held one.
  case forecastIgnoredOlder(point: UInt16)
  case textChunkStored(group: UInt8, index: UInt8, isComplete: Bool)
  /// The bot stated what it carries (spec §10); it replaces any statement held.
  case coverageStored
  /// A statement that arrived out of order behind one already held: the held one came in a
  /// message the bot sent later, so it stands.
  case coverageIgnoredOlder
  /// One packet of a national area sweep landed (spec §12).
  case areaSweepStored(group: UInt8, index: UInt8, isComplete: Bool)
  /// The sweep was built before something already held that speaks for everything it would say
  /// — a newer national sweep, or a newer scoped one whose scope contains this one's — so it
  /// changed nothing. Usually a backlog drained from the radio's queue at connect.
  case areaSweepIgnoredOlder(builtMinutes: UInt32)
  /// A radar frame landed: a picture of that square of earth at that minute, older or newer than
  /// what was held (spec revision 11, §13; revision 13, §13.5).
  case radarStored(tile: MeshWXRadarTile, takenMinutes: UInt32)
  /// A radar frame that changed nothing: the phone already holds that minute of that square at
  /// the same or a finer detail, or the frame is older than everything retention keeps.
  case radarIgnoredOlder(tile: MeshWXRadarTile, takenMinutes: UInt32)
  case notAvailable(MeshWXNotAvailable)
  case unknownType(rawType: UInt8)
  /// The message's own time — a digest's `now`, a batch's `ts`, a forecast's issue, a sweep's
  /// build, a picture's `taken`, a warning's issue — is more than
  /// ``WeatherStateReducer/futureTolerance`` ahead of the phone's clock (spec §17.5). No bot sends
  /// that honestly: every one of them is a time something already happened. A digest, batch,
  /// forecast, sweep or picture is dropped whole, because kept it would stand as "newest" over
  /// everything real until the clock caught up — one digest stamped `0xFFFFFF00` would make every
  /// real digest "older", and its empty list would end every warning held. A warning is still
  /// stored, without the issue time (it is still a warning), and the change comes before its
  /// `warningStored`.
  case futureTimeRejected(minutes: UInt32)
}

/// The bundle's centre of one county or zone, by the fields an area run carries, or nil for an
/// area the bundle does not know: what the reducer judges a county against a bot's stated circle
/// with (spec §5, 17 October 2026). The reducer reads no tables of its own; the service hands it
/// this, built from them (`WeatherService.areaCentres`).
public typealias WeatherAreaCentre =
  @Sendable (_ stateIndex: UInt8, _ isCounty: Bool, _ number: UInt16) -> MeshWXCoordinate?

/// Pure state transitions for one bot. No clock, no I/O, no tables: every input is in the
/// arguments, which is what makes each spec rule a one-line test.
public enum WeatherStateReducer {
  /// How many accepted messages count as "already seen".
  static let duplicateWindow = 16
  /// After this long without hearing the bot, a repeated `seq` is a new message that wrapped
  /// around, not a copy.
  static let duplicateWindowReset: TimeInterval = 6 * 60 * 60
  /// How far behind the newest accepted `seq` a message may be and still be the same stream
  /// arriving out of order. The bot resends an unechoed packet once, 8–10 s later, while other
  /// packets go out every 2 s, so a resend lands a handful of places back. Anything further
  /// behind is a restart: a revision 2 bot starts its counter at a random value every time it
  /// starts (revision 3 saves it, and saves past a batch before sending it).
  static let reorderWindow: UInt8 = 32
  /// A digest speaks only for warnings that arrived before it was built. Arrival is on the
  /// phone's clock and building on the bot's, so a margin absorbs the difference between the two
  /// clocks and the minute the bot truncates `now` to. Nothing else: the bot keeps no answer
  /// cache (spec §14, revision 2), so a digest is built when it is sent.
  static let digestMargin: TimeInterval = 2 * 60
  /// How long a cancel is remembered, so a late copy of the warning it ended is not stored again.
  static let recentCancelRetention: TimeInterval = 60 * 60
  /// How far ahead of the phone's clock a time on the wire may be and still be a time (spec
  /// §17.5, 17 October 2026). Every time a bot sends is something that already happened, so this
  /// only absorbs a bot's clock and the phone's disagreeing — and the bot truncating to the minute.
  static let futureTolerance: TimeInterval = 15 * 60
  /// The furthest ahead an expiry is believed, from when the warning was heard (spec §17.5). A
  /// product in force until further notice reaches the phone with an expiry the bot invented 12
  /// hours ahead (spec §3), re-sent as it moves, and every real product ends well inside this; an
  /// expiry past it is clamped here, so a forged or corrupt one cannot pin a warning to the screen
  /// for years. Measured from receipt rather than from the issue time: the until-further-notice
  /// flood warning keeps its original issue time, and a cap from that would end a warning the
  /// bot still says is in force.
  static let warningHorizon: TimeInterval = 14 * 24 * 60 * 60
  /// How far past a bot's stated circle the centre of a county may lie and the county still reach
  /// into it (``touchesCoverage(_:_:areaCentre:)``). The bot covers every county whose outline
  /// meets the circle; the phone has only the county's centre, so the margin is half a county of
  /// the plains. Where it is short the error is the safe one: a watch the list was not speaking
  /// for ends by its cancel or its expiry instead of by the list.
  static let countyReachKilometres: Double = 25
  /// For a statement with no circle (an area made of states or offices): how near a warning must
  /// come to the centre of a stated area to touch it (``touchesCoverage(_:_:areaCentre:)``).
  static let areaReachKilometres: Double = 25
  /// How recently a held warning must have arrived for its `seq` to be compared with a late one:
  /// `seq` wraps, so an old copy's number says nothing about order.
  static let reorderRecency: TimeInterval = 10 * 60

  private enum Position {
    case next
    case ahead
    case behind
    case restart
  }

  /// Where a `seq` falls against the newest accepted one, from `forward = seq − last` mod 256:
  /// 1 is the next message; 2…128 is ahead, past a gap; 224…255 is behind by at most
  /// `reorderWindow`, out of order. 129…223 is behind by more than reordering explains, and 0 —
  /// which only gets this far when the content differs from the message accepted under that
  /// `seq` — is the newest `seq` again with something new in it: both are a restart.
  private static func position(forward: UInt8) -> Position {
    switch forward {
    case 1: .next
    case 2...128: .ahead
    case (UInt8.max - reorderWindow + 1)...: .behind
    default: .restart
    }
  }

  /// Applies `message` (already known to be from `state.botID`) and reports what changed.
  ///
  /// Out of order, a message is applied unless it could roll back something newer: a warning is
  /// stored only when this identity is neither held (the held copy came in a newer message) nor
  /// cancelled in the last hour (the warning was sent before its cancel); a cancel always applies,
  /// because an ETN is never reissued; a digest goes through the same build-time check as any
  /// other; observations, forecasts and text already keep the newest by their own times; a
  /// coverage statement has no time of its own, so it yields to one already held.
  public static func apply(
    _ message: MeshWXMessage,
    to state: inout WeatherBotState,
    receivedAt: Date,
    areaCentre: WeatherAreaCentre? = nil
  ) -> [WeatherStateChange] {
    let seq = message.header.seq
    let fingerprint = fingerprint(of: message)
    let isLongSilence = state.lastHeardAt.map { receivedAt.timeIntervalSince($0) > duplicateWindowReset } ?? false
    if isLongSilence { state.recentMessages = [] }
    if state.recentMessages.contains(where: { $0.isCopy(seq: seq, fingerprint: fingerprint) }) {
      return [.duplicate(seq: seq)]
    }

    var changes: [WeatherStateChange] = []
    var isOutOfOrder = false
    if let lastSeq = state.lastSeq {
      let forward = seq &- lastSeq
      // After a long silence nothing about the old `seq` can be trusted: anything but the next
      // number is a gap.
      switch isLongSilence && forward != 1 ? .ahead : position(forward: forward) {
      case .next:
        state.lastSeq = seq
      case .ahead:
        changes.append(.sequenceGap(expected: lastSeq &+ 1, received: seq))
        markGap(&state, at: receivedAt)
        state.lastSeq = seq
      case .behind:
        isOutOfOrder = true
        changes.append(.outOfOrder(seq: seq))
        markGap(&state, at: receivedAt)
      case .restart:
        changes.append(.sequenceRestart(last: lastSeq, received: seq))
        markGap(&state, at: receivedAt)
        state.lastSeq = seq
        state.recentMessages = []
      }
    } else {
      state.lastSeq = seq
    }
    state.recentMessages.append(WeatherSeenMessage(seq: seq, fingerprint: fingerprint))
    if state.recentMessages.count > duplicateWindow {
      state.recentMessages.removeFirst(state.recentMessages.count - duplicateWindow)
    }
    state.lastHeardAt = max(state.lastHeardAt ?? receivedAt, receivedAt)
    state.recentCancels = state.recentCancels.filter { receivedAt.timeIntervalSince($0.value) < recentCancelRetention }

    // Where the bot got what it is about to say (spec §2.2, revision 7). It rides on the header,
    // so every `store` below is handed it rather than digging it out of a body that does not
    // carry it. `.unstated` for a bot older than revision 7, and for a Cancel always.
    let source = message.header.dataSource

    // A message whose own time is in the future is not stored as the newest of anything (spec
    // §17.5). A warning's is its issue time, and that one costs only the issue time.
    if let minutes = ownMinutes(of: message.payload), isAhead(minutes, of: receivedAt) {
      changes.append(.futureTimeRejected(minutes: minutes))
      guard case .warning = message.payload else { return changes }
    }

    switch message.payload {
    case let .warning(warning):
      if !(isOutOfOrder && wouldRollBack(warning, seq: seq, state: state, receivedAt: receivedAt)) {
        changes.append(store(
          cappedWarning(warning, receivedAt: receivedAt), in: &state, receivedAt: receivedAt, seq: seq,
          source: source))
      }
    case let .cancel(cancel):
      changes.append(remove(cancel, from: &state, receivedAt: receivedAt, isOutOfOrder: isOutOfOrder))
    case let .digest(digest):
      changes.append(applyDigest(digest, to: &state, receivedAt: receivedAt, areaCentre: areaCentre))
    case let .observations(batch):
      changes.append(store(batch, in: &state, receivedAt: receivedAt, source: source))
    case let .forecast(forecast):
      changes.append(store(forecast, in: &state, receivedAt: receivedAt, source: source))
    case let .text(chunk):
      changes.append(store(chunk, in: &state, receivedAt: receivedAt, source: source))
    case let .coverage(coverage):
      changes.append(store(coverage, in: &state, receivedAt: receivedAt, isOutOfOrder: isOutOfOrder))
    case let .areaSweep(sweep):
      changes.append(store(sweep, in: &state, receivedAt: receivedAt, source: source))
    case let .radar(radar):
      changes.append(store(radar, in: &state, receivedAt: receivedAt, source: source))
    case let .notAvailable(notAvailable):
      changes.append(.notAvailable(notAvailable))
    case .request:
      // Another phone's `>` request, heard because requests are flooded on `#meshwx` now (spec
      // §11). `WeatherService.ingest` drops one before it ever reaches here: it is somebody
      // else's question, it is not the bot, and nothing in it is this bot's state.
      break
    case .unknown:
      changes.append(.unknownType(rawType: message.header.rawType))
    }
    return changes
  }

  /// Whether a warning arriving out of order would undo something newer: its identity was cancelled
  /// in the last hour (the warning went out before its cancel), or the held copy came in a message
  /// sent after this one (a `seq` up to `reorderWindow` ahead, received recently). A held copy
  /// from an earlier message is older, so the bot's late resend of an update replaces it; so does
  /// one saved before copies carried a `seq`.
  private static func wouldRollBack(
    _ warning: MeshWXWarning,
    seq: UInt8,
    state: WeatherBotState,
    receivedAt: Date
  ) -> Bool {
    if state.recentCancels[warning.identity] != nil { return true }
    guard let held = state.warnings[warning.identity], let heldSeq = held.seq else { return false }
    let heldAhead = heldSeq &- seq
    return (1...reorderWindow).contains(heldAhead)
      && receivedAt.timeIntervalSince(held.receivedAt) < reorderRecency
  }

  /// FNV-1a over the message's wire bytes: the same for the bot's byte-identical resend, and
  /// different for a new message that reuses a `seq` after a restart. Nil for a type the codec
  /// cannot re-encode, which is then matched on `seq` alone.
  static func fingerprint(of message: MeshWXMessage) -> UInt64? {
    guard let bytes = try? MeshWXEncoder.encode(message) else { return nil }
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for byte in bytes {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01B3
    }
    return hash
  }

  private static func markGap(_ state: inout WeatherBotState, at date: Date) {
    state.needsDigest = true
    state.gapDetectedAt = max(state.gapDetectedAt ?? date, date)
  }

  // MARK: - Times ahead of the phone's clock (spec §17.5)

  /// The time a message states for itself, which a future one must not be: nil for a message
  /// with none (Cancel, Text, Coverage, Not available) and for a warning without an issue time. A
  /// warning's expiry is in the future by nature and is capped instead (``cappedWarning(_:receivedAt:)``).
  private static func ownMinutes(of payload: MeshWXPayload) -> UInt32? {
    switch payload {
    case let .digest(digest): digest.nowMinutes
    case let .observations(batch): batch.timestampMinutes
    case let .forecast(forecast): forecast.issuedMinutes
    case let .areaSweep(sweep): sweep.builtMinutes
    case let .radar(radar): radar.takenMinutes
    case let .warning(warning): warning.issuedMinutes
    default: nil
    }
  }

  /// Whether a wire time in Unix minutes is more than ``futureTolerance`` ahead of `now`.
  static func isAhead(_ minutes: UInt32, of now: Date) -> Bool {
    Date(unixMinutes: minutes) > now.addingTimeInterval(futureTolerance)
  }

  /// The latest expiry believed of a warning heard at `receivedAt`, in Unix minutes.
  private static func expiryCeiling(heardAt receivedAt: Date) -> UInt32 {
    let minutes = Int64((receivedAt.timeIntervalSince1970 / 60).rounded(.down)) + Int64(warningHorizon / 60)
    return UInt32(clamping: minutes)
  }

  /// A warning as the phone may believe it, heard at `receivedAt`: an issue time ahead of the
  /// clock is dropped, and the start with it, since both ride on the same expiry; an expiry past
  /// ``warningHorizon`` is clamped to it; and a start that no longer falls before the expiry goes.
  /// The wire's relative fields are re-stated against the clamped expiry, so the issue time and
  /// the start read back as the same instants. Unchanged when nothing needed changing.
  static func cappedWarning(_ warning: MeshWXWarning, receivedAt: Date) -> MeshWXWarning {
    var issued = warning.issuedMinutes
    var begins = warning.beginsMinutes
    if let minutes = issued, isAhead(minutes, of: receivedAt) {
      issued = nil
      begins = nil
    }
    let expires = min(warning.expiresMinutes, expiryCeiling(heardAt: receivedAt))
    if let minutes = begins, minutes >= expires { begins = nil }
    guard expires != warning.expiresMinutes || issued != warning.issuedMinutes
      || begins != warning.beginsMinutes
    else { return warning }
    var capped = warning
    capped.expiresMinutes = expires
    capped.issuedBeforeMinutes = issued.map { UInt16(clamping: Int64(expires) - Int64($0)) }
    capped.beginsBeforeMinutes = issued == nil
      ? nil : begins.map { UInt16(clamping: Int64(expires) - Int64($0)) }
    return capped
  }

  /// Takes out of persisted state anything stamped ahead of `now`: state saved before the phone
  /// checked (spec §17.5). A digest built in the future is forgotten with the list it named — or
  /// it would go on turning every real digest away as older — and so are readings, forecasts,
  /// sweeps and radar pictures from the future, which would go on standing as the newest. A held
  /// warning keeps its place, capped as ``cappedWarning(_:receivedAt:)`` would have capped it on
  /// arrival.
  public static func dropFutureTimes(_ state: inout WeatherBotState, now: Date) {
    func ahead(_ minutes: UInt32?) -> Bool { minutes.map { isAhead($0, of: now) } ?? false }
    if let digest = state.digest, ahead(digest.digest.nowMinutes) {
      state.digest = nil
      state.missingFromDigest = []
    }
    for (index, stored) in state.observations {
      if ahead(stored.timestampMinutes) {
        state.observations.removeValue(forKey: index)
      } else if ahead(stored.lastBatchMinutes) {
        state.observations[index]?.lastBatchMinutes = nil
      }
    }
    state.forecasts = state.forecasts.filter { !ahead($0.value.forecast.issuedMinutes) }
    state.unbundledForecasts = state.unbundledForecasts.filter { !ahead($0.value.forecast.issuedMinutes) }
    state.areaSweeps.removeAll { ahead($0.builtMinutes) }
    state.radarTiles.removeAll { ahead($0.takenMinutes) }

    let futureAt = now.addingTimeInterval(futureTolerance)
    for (identity, stored) in state.warnings {
      var next = stored
      next.warning = cappedWarning(stored.warning, receivedAt: now)
      // The start rides on the issue time (spec §3), so it goes with one from the future.
      if let issuedAt = stored.issuedAt, issuedAt > futureAt {
        next.issuedAt = nil
        next.beginsAt = nil
      }
      if let beginsAt = next.beginsAt, beginsAt >= next.expiresAt { next.beginsAt = nil }
      if next != stored { state.warnings[identity] = next }
    }
  }

  // MARK: - What a digest speaks for (spec §5, 17 October 2026)

  /// Whether this bot's digest speaks for a held warning, so that its absence from the list ends
  /// it. A bot answers a place-named `>w` anywhere in the country (spec §14), but its digest lists
  /// only what is active in its own coverage, so a warning the phone fetched from it for a place
  /// outside that coverage is absent from every digest it will ever send — and is not over. With
  /// the bot's own complete statement of its area held (Coverage, spec §10), a digest ends only
  /// what touches that area; a warning outside it ends by its expiry, its cancel, or a fresh
  /// answer. Without a complete statement nothing says where the area stops, and the digest speaks
  /// for everything, as it always did.
  ///
  /// Without `areaCentre` a county is judged by the stated runs alone.
  static func digestSpeaksFor(
    _ warning: MeshWXWarning, coverage: MeshWXCoverage?, areaCentre: WeatherAreaCentre?
  ) -> Bool {
    guard let coverage, coverage.isComplete else { return true }
    return touchesCoverage(warning, coverage, areaCentre: areaCentre)
  }

  /// Whether a warning's area touches a bot's stated coverage, by the bot's own rule (its
  /// `_in_coverage`): a zone it lists; for a product without a polygon (a watch by county), a
  /// county it covers; for a storm-based warning, the polygon against the circle — the counties on
  /// such a warning are only the ones its polygon crosses, so they do not count on their own.
  ///
  /// The statement lists zones, not the counties the bot derives from its circle, so a county is
  /// judged by its centre against the circle, ``countyReachKilometres`` generous. A statement
  /// without a circle is an area of states or offices, and there the warning must come within
  /// ``areaReachKilometres`` of a stated area's centre. Nothing here ever reads an office: WX-AUS
  /// lists HGX because a few Houston zones reach its circle, and Houston is not in its area.
  static func touchesCoverage(
    _ warning: MeshWXWarning, _ coverage: MeshWXCoverage, areaCentre: WeatherAreaCentre?
  ) -> Bool {
    if coverage.hasNoAreaFilter { return true }
    let polygon = warning.polygon ?? []
    let hasPolygon = polygon.count >= 3
    let runs = warning.areas ?? []
    for run in runs where !(run.isCounty && hasPolygon) {
      if coverage.areas.contains(where: { runsOverlap(run, $0) }) { return true }
    }
    let counties = hasPolygon ? [] : centres(of: runs.filter(\.isCounty), areaCentre: areaCentre)
    if let centre = coverage.centre, coverage.radiusKilometres > 0 {
      if hasPolygon { return reaches(polygon, centre, within: Double(coverage.radiusKilometres)) }
      let reach = Double(coverage.radiusKilometres) + countyReachKilometres
      if counties.contains(where: { kilometres($0, centre) <= reach }) { return true }
    }
    if !hasPolygon, counties.isEmpty { return false }
    let stated = centres(of: coverage.areas, areaCentre: areaCentre)
    if hasPolygon { return stated.contains { reaches(polygon, $0, within: areaReachKilometres) } }
    return counties.contains { county in stated.contains { kilometres(county, $0) <= areaReachKilometres } }
  }

  /// Two area runs of one kind in one state that share a number.
  private static func runsOverlap(_ lhs: MeshWXAreaRun, _ rhs: MeshWXAreaRun) -> Bool {
    lhs.stateIndex == rhs.stateIndex && lhs.isCounty == rhs.isCounty
      && Int(lhs.start) < Int(rhs.start) + Int(rhs.run) && Int(rhs.start) < Int(lhs.start) + Int(lhs.run)
  }

  /// The bundle centres of every county or zone in `runs`, those it knows.
  private static func centres(of runs: [MeshWXAreaRun], areaCentre: WeatherAreaCentre?) -> [MeshWXCoordinate] {
    guard let areaCentre else { return [] }
    return runs.flatMap { run in run.numbers.compactMap { areaCentre(run.stateIndex, run.isCounty, $0) } }
  }

  private static func kilometres(_ lhs: MeshWXCoordinate, _ rhs: MeshWXCoordinate) -> Double {
    MeshWXGeo.distanceKilometres(
      fromLat: lhs.latitude, lon: lhs.longitude, toLat: rhs.latitude, lon: rhs.longitude)
  }

  /// Whether a polygon comes within `radius` kilometres of a point: the point is inside it, or one
  /// of its edges passes that close. On a flat projection around the point, which over a warning's
  /// few tens of kilometres is far inside the margins used.
  private static func reaches(
    _ polygon: [MeshWXCoordinate], _ point: MeshWXCoordinate, within radius: Double
  ) -> Bool {
    let cosLatitude = cos(point.latitude * .pi / 180)
    let planar: [(x: Double, y: Double)] = polygon.map { vertex in
      var east = vertex.longitude - point.longitude
      if east > 180 { east -= 360 } else if east < -180 { east += 360 }
      return (x: east * 111.32 * cosLatitude, y: (vertex.latitude - point.latitude) * 110.574)
    }
    var inside = false
    var previous = planar.count - 1
    for index in planar.indices {
      let a = planar[index]
      let b = planar[previous]
      if (a.y > 0) != (b.y > 0), a.x + (b.x - a.x) * -a.y / (b.y - a.y) > 0 { inside.toggle() }
      previous = index
    }
    if inside { return true }
    return planar.indices.contains { index in
      segmentDistance(planar[index], planar[(index + 1) % planar.count]) <= radius
    }
  }

  /// The distance from the origin to the segment `a`–`b`.
  private static func segmentDistance(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double {
    let dx = b.x - a.x
    let dy = b.y - a.y
    let length = dx * dx + dy * dy
    let along = length == 0 ? 0 : max(0, min(1, -(a.x * dx + a.y * dy) / length))
    return hypot(a.x + along * dx, a.y + along * dy)
  }

  /// Drops warnings that expired before `cutoff`, returning what went. Expiry is judged at
  /// read time everywhere else; this exists so persisted state does not grow without bound.
  @discardableResult
  public static func pruneExpired(
    _ state: inout WeatherBotState,
    expiredBefore cutoff: Date
  ) -> [MeshWXWarningIdentity] {
    let expired = state.warnings.values
      .filter { $0.isExpired(at: cutoff) }
      .map(\.identity)
      .sorted(by: identityOrder)
    for identity in expired {
      state.warnings.removeValue(forKey: identity)
    }
    return expired
  }

  /// Forgets upgrade markers older than `cutoff`: long enough that the replacement, if it was
  /// ever sent, has been listed by a digest or has itself expired.
  public static func prunePendingUpgrades(_ state: inout WeatherBotState, olderThan cutoff: Date) {
    state.pendingUpgrades = state.pendingUpgrades.filter { $0.value.cancelledAt >= cutoff }
  }

  // MARK: - Retention
  //
  // Answers on `#meshwx` reach every phone, so a phone that never asks for anything still
  // accumulates other people's replies and other people's forecasts. Readings have had an age
  // and a ceiling from the start (`WeatherService.trim`); these give texts and forecasts the
  // same treatment, so the cache cannot grow for ever — while what a screen would actually show
  // survives both rules, however old it is.

  /// Drops text replies received before `cutoff`, then caps what is left at `limit`, newest
  /// kept. What the screens can still show (``shownTextGroups``) survives both.
  public static func pruneTexts(_ state: inout WeatherBotState, receivedBefore cutoff: Date, limit: Int) {
    let shown = shownTextGroups(state)
    var kept = state.texts.filter { shown.contains($0.key) || $0.value.lastReceivedAt >= cutoff }
    if kept.count > limit {
      let room = max(0, limit - shown.count)
      let spare = kept.keys.filter { !shown.contains($0) }
        .sorted { lhs, rhs in
          let left = kept[lhs]?.lastReceivedAt ?? .distantPast
          let right = kept[rhs]?.lastReceivedAt ?? .distantPast
          return left != right ? left > right : lhs < rhs
        }
        .prefix(room)
      let survivors = shown.union(spare)
      kept = kept.filter { survivors.contains($0.key) }
    }
    state.texts = kept
  }

  /// The text groups a screen can still put on the page (docs/MESHWX_UI.md §12): the newest
  /// reply on each subject, which is what a product screen falls back to when nobody here asked,
  /// and the newest reply on each subject that answered a request of this phone's, which is what
  /// it shows first. At most two per subject, so this can never hold the cache open.
  static func shownTextGroups(_ state: WeatherBotState) -> Set<UInt8> {
    var newest: [MeshWXTextSubject: WeatherTextAssembly] = [:]
    var newestOwn: [MeshWXTextSubject: WeatherTextAssembly] = [:]
    for assembly in state.texts.values {
      if (newest[assembly.subject]?.lastReceivedAt ?? .distantPast) < assembly.lastReceivedAt {
        newest[assembly.subject] = assembly
      }
      guard assembly.request != nil else { continue }
      if (newestOwn[assembly.subject]?.lastReceivedAt ?? .distantPast) < assembly.lastReceivedAt {
        newestOwn[assembly.subject] = assembly
      }
    }
    return Set(newest.values.map(\.group)).union(newestOwn.values.map(\.group))
  }

  /// Drops forecasts received before `cutoff`, then caps what is left at `limit`. The place's own
  /// forecast (``shownForecastPoints``) survives both, and under the ceiling the forecasts this
  /// phone asked for outlast the ones the channel happened to carry.
  public static func pruneForecasts(_ state: inout WeatherBotState, receivedBefore cutoff: Date, limit: Int) {
    let shown = shownForecastPoints(state)
    var kept = state.forecasts.filter { shown.contains($0.key) || $0.value.receivedAt >= cutoff }
    if kept.count > limit {
      let room = max(0, limit - shown.count)
      let spare = kept.filter { !shown.contains($0.key) }
        .sorted { lhs, rhs in
          if lhs.value.requestedHere != rhs.value.requestedHere { return lhs.value.requestedHere }
          if lhs.value.receivedAt != rhs.value.receivedAt { return lhs.value.receivedAt > rhs.value.receivedAt }
          return lhs.key < rhs.key
        }
        .prefix(room)
        .map(\.key)
      let survivors = shown.union(spare)
      kept = kept.filter { survivors.contains($0.key) }
    }
    state.forecasts = kept
  }

  /// The forecast the Forecast card is holding open: the newest this phone asked for, which is
  /// the place's own (docs/MESHWX_UI.md §9). One point, so this too is bounded.
  static func shownForecastPoints(_ state: WeatherBotState) -> Set<UInt16> {
    let own = state.forecasts
      .filter { $0.value.requestedHere }
      .max { lhs, rhs in
        lhs.value.receivedAt != rhs.value.receivedAt
          ? lhs.value.receivedAt < rhs.value.receivedAt : lhs.key < rhs.key
      }
    return Set([own?.key].compactMap { $0 })
  }

  // MARK: - Warnings

  private static func store(
    _ warning: MeshWXWarning,
    in state: inout WeatherBotState,
    receivedAt: Date,
    seq: UInt8,
    source: MeshWXDataSource
  ) -> WeatherStateChange {
    // Spec §2.4: keyed by identity, not by seq — a known identity is replaced either way,
    // whether or not the bot set the update flag.
    let existing = state.warnings[warning.identity]
    state.warnings[warning.identity] = WeatherStoredWarning(
      warning: warning,
      receivedAt: receivedAt,
      updateCount: existing.map { $0.updateCount + 1 } ?? 0,
      seq: seq,
      // Spec §3: the issue time is the product's own, kept across continuations, so an identity's
      // issuance never moves. A replacement that does not carry one — an older bot, or a message
      // sent before the bot spoke revision 5 — therefore leaves what is already known alone
      // rather than erasing it.
      issuedAt: warning.issuedMinutes.map { Date(unixMinutes: $0) } ?? existing?.issuedAt,
      // Spec §3, revision 12: the start, resolved once and kept the same way. A later copy
      // without one (a second, older bot, or a message from before the bot spoke revision 12)
      // does not erase it; a copy with a moved start replaces it, since a moved start is a
      // material change the bot resends for.
      beginsAt: warning.beginsMinutes.map { Date(unixMinutes: $0) } ?? existing?.beginsAt,
      source: source
    )
    state.missingFromDigest.removeAll { $0 == warning.identity }
    // The replacement for an upgraded warning comes from the same office over the same
    // ground. Anything else from that office leaves the marker in place.
    state.pendingUpgrades = state.pendingUpgrades.filter { _, pending in
      !(pending.warning.office == warning.office && areasOverlap(pending.warning, warning))
    }
    return .warningStored(warning.identity, replacedExisting: existing != nil)
  }

  private static func remove(
    _ cancel: MeshWXCancel,
    from state: inout WeatherBotState,
    receivedAt: Date,
    isOutOfOrder: Bool
  ) -> WeatherStateChange {
    state.missingFromDigest.removeAll { $0 == cancel.identity }
    state.recentCancels[cancel.identity] = receivedAt
    guard let removed = state.warnings.removeValue(forKey: cancel.identity) else {
      return .cancelForUnknown(cancel.identity)
    }
    if cancel.reason == .upgraded {
      // Out of order, the replacement may already be held from a newer message; a marker would
      // then ask for something that has arrived.
      let replacementHeld = isOutOfOrder && state.warnings.values.contains {
        $0.warning.office == removed.warning.office && areasOverlap($0.warning, removed.warning)
      }
      if !replacementHeld {
        state.pendingUpgrades[cancel.identity] = WeatherPendingUpgrade(
          warning: removed.warning, cancelledAt: receivedAt)
      }
    }
    return .warningRemoved(cancel.identity, reason: cancel.reason)
  }

  /// Whether two warnings cover shared ground: a common county or zone, or overlapping polygon
  /// boxes. Deliberately generous — a false "yes" only clears an upgrade marker a little early
  /// when the office issues something nearby, a false "no" keeps it until the next digest.
  static func areasOverlap(_ lhs: MeshWXWarning, _ rhs: MeshWXWarning) -> Bool {
    if !areaKeys(lhs).isDisjoint(with: areaKeys(rhs)) { return true }
    guard let lhsPolygon = lhs.polygon, let rhsPolygon = rhs.polygon,
          let lhsBox = MeshWXGeometry.Box([lhsPolygon]),
          let rhsBox = MeshWXGeometry.Box([rhsPolygon])
    else { return false }
    return lhsBox.minLatitude <= rhsBox.maxLatitude && rhsBox.minLatitude <= lhsBox.maxLatitude
      && lhsBox.minLongitude <= rhsBox.maxLongitude && rhsBox.minLongitude <= lhsBox.maxLongitude
  }

  private struct AreaKey: Hashable {
    let state: UInt8
    let isCounty: Bool
    let number: UInt16
  }

  private static func areaKeys(_ warning: MeshWXWarning) -> Set<AreaKey> {
    Set((warning.areas ?? []).flatMap { run in
      run.numbers.map { AreaKey(state: run.stateIndex, isCounty: run.isCounty, number: $0) }
    })
  }

  // MARK: - Digest

  private static func applyDigest(
    _ digest: MeshWXDigest,
    to state: inout WeatherBotState,
    receivedAt: Date,
    areaCentre: WeatherAreaCentre?
  ) -> WeatherStateChange {
    if let held = state.digest, digest.nowMinutes < held.digest.nowMinutes {
      return .digestIgnoredOlder(builtMinutes: digest.nowMinutes)
    }
    let speaksBefore = Date(unixMinutes: digest.nowMinutes).addingTimeInterval(-digestMargin)
    let listed = Set(digest.entries.map(\.identity))
    // A full list is sorted soonest expiry first and cut (at 25 by older bots, 24 under the send
    // limit), so it says nothing about a warning expiring at or after its last entry: that one may
    // be among the cut (ties included, since the cut can fall between equal expiries).
    let horizon: UInt32? = digest.entries.count >= MeshWXWire.digestMayBeCutAt
      ? digest.entries.map(\.expiresMinutes).max()
      : nil

    // The list speaks only for the bot's own area (spec §5, 17 October 2026): what the bot stated
    // about itself, when it stated all of it.
    let coverage = state.coverage?.coverage
    func speaksFor(_ warning: MeshWXWarning) -> Bool {
      digestSpeaksFor(warning, coverage: coverage, areaCentre: areaCentre)
    }

    // Spec §5: "an identity the app holds that is absent from the digest has ended" — for
    // identities the list could have known about.
    let removed = state.warnings.values
      .filter { stored in
        !listed.contains(stored.identity) && stored.receivedAt < speaksBefore
          && !(horizon.map { stored.warning.expiresMinutes >= $0 } ?? false)
          && speaksFor(stored.warning)
      }
      .map(\.identity)
      .sorted(by: identityOrder)
    for identity in removed {
      state.warnings.removeValue(forKey: identity)
    }
    // The list's expiries are believed no further ahead than a warning's own (`cappedWarning`).
    let ceiling = expiryCeiling(heardAt: receivedAt)

    var missing: [MeshWXWarningIdentity] = []
    for entry in digest.entries {
      guard var held = state.warnings[entry.identity] else {
        missing.append(entry.identity)
        continue
      }
      // The digest's expiry is absolute (`now + rel`). It replaces the held one when the list
      // is newer than the warning message; otherwise it may only extend it.
      let expires = min(entry.expiresMinutes, ceiling)
      let replaces = held.receivedAt < speaksBefore
      if held.warning.expiresMinutes != expires, replaces || expires > held.warning.expiresMinutes {
        held.warning.expiresMinutes = expires
        state.warnings[entry.identity] = held
      }
    }

    // A marker outside the bot's area is not the list's to settle, for the same reason.
    state.pendingUpgrades = state.pendingUpgrades.filter {
      $0.value.cancelledAt >= speaksBefore || !speaksFor($0.value.warning)
    }
    if let gap = state.gapDetectedAt {
      if gap < speaksBefore {
        state.needsDigest = false
        state.gapDetectedAt = nil
      }
    } else {
      state.needsDigest = false
    }
    state.digest = WeatherStoredDigest(digest: digest, receivedAt: receivedAt)
    state.missingFromDigest = missing
    return .digestApplied(missing: missing, removed: removed)
  }

  // MARK: - Observations and forecasts

  private static func store(
    _ batch: MeshWXObservations,
    in state: inout WeatherBotState,
    receivedAt: Date,
    source: MeshWXDataSource
  ) -> WeatherStateChange {
    var stored: [UInt16] = []
    // More than one station is the bot's scheduled report, and the only thing that says where the
    // bot reports (docs/MESHWX_UI.md §6). A single-station answer to somebody's `>o KATT` carries
    // the newer reading and takes its place, but leaves that evidence as it found it.
    let isScheduled = batch.stations.count > 1
    for observation in batch.stations {
      // Spec §6.1: each station is stamped with its *own* report time, the batch `ts` less the
      // age it states, so "as of", staleness and the comparison below are per station rather than
      // per batch. A batch without the ages says only its `ts`, which is what every station in it
      // then reads — exactly what the app did before revision 5.
      let observedMinutes = batch.reportMinutes(for: observation)
      let held = state.observations[observation.stationIndex]
      // The batch's own time, not the station's: this is membership of a scheduled broadcast.
      let lastBatchMinutes = isScheduled
        ? max(batch.timestampMinutes, held?.lastBatchMinutes ?? 0)
        : held?.lastBatchMinutes
      // A reading older than what is held — a batch drained late from the radio's queue, a late
      // copy, or a station whose report this batch carries at a greater age than the last one did
      // — must not roll that station back. That it was in a scheduled batch still counts.
      if let held, held.timestampMinutes > observedMinutes {
        if lastBatchMinutes != held.lastBatchMinutes {
          state.observations[observation.stationIndex]?.lastBatchMinutes = lastBatchMinutes
        }
        continue
      }
      state.observations[observation.stationIndex] = WeatherStoredObservation(
        observation: observation,
        timestampMinutes: observedMinutes,
        receivedAt: receivedAt,
        batchSize: batch.stations.count,
        lastBatchMinutes: lastBatchMinutes,
        source: source
      )
      stored.append(observation.stationIndex)
    }
    return .observationsStored(stations: stored)
  }

  private static func store(
    _ forecast: MeshWXForecast,
    in state: inout WeatherBotState,
    receivedAt: Date,
    source: MeshWXDataSource
  ) -> WeatherStateChange {
    let held = state.forecasts[forecast.pointIndex]
    // "Older" is a comparison between two forecasts *of the same place*, which is what a bundled
    // point index is. `0xFFFF` is not a place: it is "somewhere the bundle has no point for", and
    // Santa Fe's 14:00 forecast followed by Taos's 13:00 one is two answers, not a stale copy of
    // one. Applying the check there would have made the second `>f <lat>,<lon>` of a session
    // silently do nothing (docs/MESHWX.md "State").
    if let held, !forecast.isUnbundledPoint, held.forecast.issuedMinutes > forecast.issuedMinutes {
      return .forecastIgnoredOlder(point: forecast.pointIndex)
    }
    // A fresh forecast for the unbundled slot is for whatever place was asked for last; the
    // service re-labels it when it settles the request that produced it. Whether this phone
    // asked about a bundled point survives the bot's next scheduled issue of it.
    let stored = WeatherStoredForecast(
      forecast: forecast,
      receivedAt: receivedAt,
      requestLabel: nil,
      requestedHere: forecast.isUnbundledPoint ? false : (held?.requestedHere ?? false),
      source: source
    )
    state.forecasts[forecast.pointIndex] = stored
    if forecast.isUnbundledPoint {
      // Nobody here has asked for it yet as far as the reducer can tell — it holds no requests —
      // so it goes in the one slot for an answer that is somebody else's question. `WeatherService`
      // moves it under the coordinate asked about when it settles a `.forecastAt` of this phone's,
      // and until then nothing may show it as a place's forecast.
      state.unbundledForecasts[WeatherBotState.unbundledAskKey] = stored
      pruneUnbundledForecasts(&state)
    }
    return .forecastStored(point: forecast.pointIndex)
  }

  /// Keeps ``WeatherBotState/unbundledForecasts`` at ``WeatherBotState/unbundledForecastLimit``,
  /// oldest received dropped. The unasked-for slot is nothing special here: it is one answer
  /// among the twelve, and an old one of somebody else's goes before a coordinate this phone
  /// asked about half an hour ago.
  static func pruneUnbundledForecasts(
    _ state: inout WeatherBotState, limit: Int = WeatherBotState.unbundledForecastLimit
  ) {
    guard state.unbundledForecasts.count > limit else { return }
    let keep = Set(state.unbundledForecasts
      .sorted { lhs, rhs in
        lhs.value.receivedAt != rhs.value.receivedAt
          ? lhs.value.receivedAt > rhs.value.receivedAt : lhs.key < rhs.key
      }
      .prefix(limit)
      .map(\.key))
    state.unbundledForecasts = state.unbundledForecasts.filter { keep.contains($0.key) }
  }

  // MARK: - Text

  private static func store(
    _ chunk: MeshWXText,
    in state: inout WeatherBotState,
    receivedAt: Date,
    source: MeshWXDataSource
  ) -> WeatherStateChange {
    var assembly: WeatherTextAssembly
    if let held = state.texts[chunk.group],
       held.subject == chunk.subject,
       held.total == chunk.total {
      assembly = held
    } else {
      // A different subject or chunk count under the same group byte is a new reply that
      // happens to reuse the byte (it wraps with `seq`); start over.
      assembly = WeatherTextAssembly(
        subject: chunk.subject,
        group: chunk.group,
        total: chunk.total,
        firstReceivedAt: receivedAt,
        lastReceivedAt: receivedAt
      )
    }
    assembly.chunks[chunk.index] = chunk.text
    assembly.lastReceivedAt = receivedAt
    // Spec §8, revision 7: the bot sets the cut flag on *every* chunk of a cut reply, so any
    // chunk saying so is the reply saying so — which is what makes the mark survive the one chunk
    // that never arrived.
    assembly.wasCut = assembly.wasCut || chunk.wasCut
    // One reply is built from one product, so the chunks agree. If a resend somehow disagrees,
    // this chunk is the newest word on it — but a chunk that states nothing (an older bot, or a
    // message with no product behind it) never erases a source already stated.
    if source != .unstated { assembly.source = source }
    state.texts[chunk.group] = assembly
    return .textChunkStored(group: chunk.group, index: chunk.index, isComplete: assembly.isComplete)
  }

  // MARK: - Coverage

  /// Spec §10: what the bot says about itself, newest first. The message carries no time of its
  /// own — it describes the bot at the moment it is sent — so receipt is the only order there is,
  /// and out of order the statement already held came in a message the bot sent later.
  private static func store(
    _ coverage: MeshWXCoverage,
    in state: inout WeatherBotState,
    receivedAt: Date,
    isOutOfOrder: Bool
  ) -> WeatherStateChange {
    if isOutOfOrder, state.coverage != nil { return .coverageIgnoredOlder }
    state.coverage = WeatherStoredCoverage(coverage: coverage, receivedAt: receivedAt)
    return .coverageStored
  }

  // MARK: - Area sweep

  /// Spec §12, as revision 10 left it: the packets of one sweep share a `group` and assemble like
  /// Text chunks, and several sweeps can be held at once because a scoped one covers only the
  /// states it names.
  ///
  /// Four rules, in this order, and the order is the point:
  ///
  /// - A packet of a sweep **already held** — same `group`, same build time, same `total` —
  ///   merges into it, whatever else has arrived since. This is what makes a `>part` resend land:
  ///   it is the same bytes under a new `seq` (spec §14.5), so it is not a duplicate,
  ///   and it fills the hole in the assembly it belongs to rather than starting a new one or
  ///   being turned away as old.
  /// - A sweep built **before** something already held that speaks for everything it would say
  ///   changes nothing: a national sweep built later is the newest word on every state, and a
  ///   scoped one built later is the newest word on the states it names. A backlog drained from
  ///   the radio at connect would otherwise repaint the map as it was an hour ago.
  /// - The **same** build time and scope under a different `group` or `total` is the bot sending
  ///   the sweep again; the packets in flight are of the new transmission, so that assembly
  ///   starts over.
  /// - Anything else is a new sweep and is kept beside the others, newest first, under
  ///   ``retained(_:limit:)``.
  private static func store(
    _ sweep: MeshWXAreaSweep,
    in state: inout WeatherBotState,
    receivedAt: Date,
    source: MeshWXDataSource
  ) -> WeatherStateChange {
    func merge(into assembly: inout WeatherAreaSweepAssembly) {
      assembly.packets[sweep.index] = sweep.entries
      assembly.lastReceivedAt = receivedAt
      // Set on every packet of a cut sweep (spec §12), so any packet saying so is the sweep
      // saying so — which is what makes the mark survive the packet that never arrived.
      assembly.wasCut = assembly.wasCut || sweep.wasCut
      // One sweep's breadth, so the packets agree; a packet that says advisories are in it is
      // taken at its word, and one that does not never narrows a breadth already stated.
      assembly.includesAdvisories = assembly.includesAdvisories || sweep.includesAdvisories
      // Likewise the scope flag, which every packet of a scoped sweep carries.
      assembly.isScoped = assembly.isScoped || sweep.isScoped
      // The states themselves ride only on the packet that carries the scope entries. Once it
      // has arrived the scope is known for good; until then it stays nil, and a packet that
      // names none never erases one that did.
      if !sweep.scope.isEmpty {
        assembly.scope = sweep.scope
      } else if assembly.isScoped, assembly.scope?.isEmpty == true {
        // A sweep that turns out to be scoped after a packet that did not say so: what it covers
        // is not the country, and is not yet known either.
        assembly.scope = nil
      }
      if source != .unstated { assembly.source = source }
    }

    if let index = state.areaSweeps.firstIndex(where: {
      $0.group == sweep.group && $0.builtMinutes == sweep.builtMinutes && $0.total == sweep.total
    }) {
      merge(into: &state.areaSweeps[index])
      let assembly = state.areaSweeps[index]
      state.areaSweeps = retained(state.areaSweeps)
      return .areaSweepStored(group: sweep.group, index: sweep.index, isComplete: assembly.isComplete)
    }

    if isSupersededOnArrival(sweep, by: state.areaSweeps) {
      return .areaSweepIgnoredOlder(builtMinutes: sweep.builtMinutes)
    }

    var assembly = WeatherAreaSweepAssembly(
      builtMinutes: sweep.builtMinutes,
      group: sweep.group,
      total: sweep.total,
      firstReceivedAt: receivedAt,
      lastReceivedAt: receivedAt,
      isScoped: sweep.isScoped,
      // Scoped and this packet carries no scope entries: which states it covers is not known yet.
      scope: sweep.isScoped ? (sweep.scope.isEmpty ? nil : sweep.scope) : []
    )
    merge(into: &assembly)
    if let resent = state.areaSweeps.firstIndex(where: { isSameSweepResent($0, sweep) }) {
      state.areaSweeps[resent] = assembly
    } else {
      state.areaSweeps.append(assembly)
    }
    state.areaSweeps = retained(state.areaSweeps)
    return .areaSweepStored(group: sweep.group, index: sweep.index, isComplete: assembly.isComplete)
  }

  /// Whether a sweep this phone has not seen a packet of is already spoken for by one it holds:
  /// a national sweep built later, or a scoped one built later whose scope contains all of this
  /// one's. Both mean the newer answer already covers everything this one would add.
  ///
  /// A scoped sweep whose own scope has not arrived yet claims nothing and is never superseded on
  /// that ground: it may name a state nothing else here covers.
  private static func isSupersededOnArrival(
    _ sweep: MeshWXAreaSweep, by held: [WeatherAreaSweepAssembly]
  ) -> Bool {
    if held.contains(where: { $0.isNational && $0.builtMinutes > sweep.builtMinutes }) { return true }
    guard sweep.isScoped, !sweep.scope.isEmpty else { return false }
    let asked = Set(sweep.scope)
    return held.contains { candidate in
      guard candidate.isScoped, candidate.builtMinutes > sweep.builtMinutes,
            let scope = candidate.scope
      else { return false }
      return asked.isSubset(of: Set(scope))
    }
  }

  /// Whether a packet is the bot transmitting a sweep this phone already holds a second time: the
  /// same build time and the same breadth under a new `group` or `total`. The packets in the air
  /// belong to the new transmission, so the held assembly starts over rather than keeping half of
  /// each.
  ///
  /// Two *different* scoped sweeps built in the same minute — two phones tapping a second apart —
  /// are told apart by their scopes where both are known. Where the arriving packet carries none
  /// (it is not the packet the scope rides on) there is nothing to tell them apart by, and the
  /// re-transmission reading is the one the old rule took.
  private static func isSameSweepResent(
    _ held: WeatherAreaSweepAssembly, _ sweep: MeshWXAreaSweep
  ) -> Bool {
    guard held.builtMinutes == sweep.builtMinutes, held.isScoped == sweep.isScoped else { return false }
    guard let heldScope = held.scope, !sweep.scope.isEmpty else { return true }
    return Set(heldScope) == Set(sweep.scope)
  }

  /// The sweeps worth keeping, newest first (docs/MESHWX.md "State").
  ///
  /// Three rules and nothing else:
  ///
  /// - A **national** sweep drops every sweep older than it. It is the newest word on every
  ///   state, so nothing older can add one.
  /// - A **scoped** sweep drops older scoped sweeps whose scope it fully contains. Asking for
  ///   Texas and Oklahoma replaces last hour's Texas; it does not touch last hour's Montana, and
  ///   it does not touch the national sweep under it, which still speaks for the other forty-nine.
  /// - At most `limit` are kept.
  ///
  /// "Older" is by build time, then by receipt: two transmissions of one sweep carry the same
  /// build time, and the one that arrived later is the one whose packets are still coming.
  public static func retained(
    _ sweeps: [WeatherAreaSweepAssembly], limit: Int = WeatherBotState.areaSweepLimit
  ) -> [WeatherAreaSweepAssembly] {
    var kept: [WeatherAreaSweepAssembly] = []
    for sweep in sweeps.sorted(by: isNewer) {
      // Everything in `kept` is newer than this one (or the same age and heard later), so a
      // national sweep in there is by definition a national sweep newer than this.
      if kept.contains(where: \.isNational) { continue }
      if sweep.isScoped, let scope = sweep.scope {
        let asked = Set(scope)
        let covered = kept.contains { candidate in
          guard candidate.isScoped, let wider = candidate.scope else { return false }
          return asked.isSubset(of: Set(wider))
        }
        if covered { continue }
      }
      kept.append(sweep)
    }
    return Array(kept.prefix(limit))
  }

  /// Newest first: build time, then when the last packet arrived, then the group byte so the
  /// order never depends on dictionary iteration.
  static func isNewer(_ lhs: WeatherAreaSweepAssembly, _ rhs: WeatherAreaSweepAssembly) -> Bool {
    if lhs.builtMinutes != rhs.builtMinutes { return lhs.builtMinutes > rhs.builtMinutes }
    if lhs.lastReceivedAt != rhs.lastReceivedAt { return lhs.lastReceivedAt > rhs.lastReceivedAt }
    return lhs.group < rhs.group
  }

  // MARK: - Radar

  /// Spec revision 13, "State": one **frame** per `(tile, taken)`, newest `taken` first.
  ///
  /// There is no assembly here and never will be — a radar answer is one packet, or the same tile
  /// at half the detail — so the whole rule is which pictures to keep. Three parts:
  ///
  /// - A **different** `taken` is another frame, older or newer, and is kept beside the others:
  ///   the loop plays them (§13.5). Until revision 13 an older one changed nothing.
  /// - The **same** `taken` follows revision 11: it replaces what is held, because the bot
  ///   re-sends a packet nothing echoed and a tile that arrives partial and then whole is the
  ///   same minute twice with more in it the second time — except that a **coarse** picture never
  ///   replaces a fine one of the same minute. The fine one is strictly more of the same storm.
  /// - Retention (``retainedRadarTiles(_:limit:)``) runs on every store, so nothing grows without
  ///   bound, and a frame it drops at once is reported as changing nothing.
  private static func store(
    _ radar: MeshWXRadar,
    in state: inout WeatherBotState,
    receivedAt: Date,
    source: MeshWXDataSource
  ) -> WeatherStateChange {
    let tile = radar.tile
    let taken = radar.takenMinutes
    func isSameFrame(_ stored: WeatherStoredRadarTile) -> Bool {
      stored.tile == tile && stored.takenMinutes == taken
    }
    if let held = state.radarTiles.first(where: isSameFrame), !replaces(radar, held: held.radar) {
      return .radarIgnoredOlder(tile: tile, takenMinutes: taken)
    }
    var kept = state.radarTiles.filter { !isSameFrame($0) }
    let arriving = WeatherStoredRadarTile(
      tile: tile, radar: radar, receivedAt: receivedAt, source: source)
    kept.append(arriving)
    let retained = retainedRadarTiles(kept)
    // Older than three hours behind this bot's newest picture, or the oldest of a full list: the
    // frame is gone as soon as it came, and the held pictures are exactly what they were.
    guard retained.contains(arriving) else {
      return .radarIgnoredOlder(tile: tile, takenMinutes: taken)
    }
    state.radarTiles = retained
    return .radarStored(tile: tile, takenMinutes: taken)
  }

  /// Whether an arriving tile is the one to keep, against the one held for the same square. Since
  /// revision 13 it is only ever asked about the same `taken`; a different one is another frame.
  static func replaces(_ arriving: MeshWXRadar, held: MeshWXRadar) -> Bool {
    if arriving.takenMinutes != held.takenMinutes {
      return arriving.takenMinutes > held.takenMinutes
    }
    // The same minute: the finer picture wins, and a second copy of the same one changes nothing
    // either way.
    return !(arriving.isCoarse && !held.isCoarse)
  }

  /// The frames worth keeping, newest `taken` first (docs/MESHWX.md "State"):
  /// nothing more than ``WeatherBotState/radarTileRetentionMinutes`` behind the bot's own clock,
  /// and at most `limit`, the oldest `taken` dropped.
  ///
  /// "The bot's clock" is the newest `taken` this bot has sent, which is the only clock of the
  /// bot's a radar packet carries. Measuring against the phone's would be measuring a picture's
  /// age with a clock that was never used to stamp it, and a phone whose time is a day out would
  /// then hold nothing or hold everything.
  ///
  /// A frame off the wire's lattice (``WeatherStoredRadarTile/isOnWireLattice``) is dropped before
  /// anything else, so it never sets the bot's clock either.
  public static func retainedRadarTiles(
    _ tiles: [WeatherStoredRadarTile], limit: Int = WeatherBotState.radarTileLimit
  ) -> [WeatherStoredRadarTile] {
    let ordered = tiles.filter(\.isOnWireLattice).sorted(by: isNewerTile)
    guard let newest = ordered.first?.takenMinutes else { return [] }
    let cutoff = newest > WeatherBotState.radarTileRetentionMinutes
      ? newest - WeatherBotState.radarTileRetentionMinutes : 0
    return Array(ordered.filter { $0.takenMinutes >= cutoff }.prefix(limit))
  }

  /// Newest first: the picture's own time, then when it arrived, then the tile itself so the
  /// order never depends on which packet the array happened to be built from.
  static func isNewerTile(_ lhs: WeatherStoredRadarTile, _ rhs: WeatherStoredRadarTile) -> Bool {
    if lhs.takenMinutes != rhs.takenMinutes { return lhs.takenMinutes > rhs.takenMinutes }
    if lhs.receivedAt != rhs.receivedAt { return lhs.receivedAt > rhs.receivedAt }
    if lhs.tile.zoom != rhs.tile.zoom { return lhs.tile.zoom < rhs.tile.zoom }
    if lhs.tile.south != rhs.tile.south { return lhs.tile.south < rhs.tile.south }
    return lhs.tile.west < rhs.tile.west
  }

  // MARK: - Ordering

  /// Deterministic order for identity lists in change records and pruning.
  static func identityOrder(_ lhs: MeshWXWarningIdentity, _ rhs: MeshWXWarningIdentity) -> Bool {
    if lhs.event != rhs.event { return lhs.event < rhs.event }
    if lhs.office != rhs.office { return lhs.office < rhs.office }
    return lhs.etn < rhs.etn
  }
}
