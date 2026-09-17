import Foundation

/// Why a value could not be put on the wire.
///
/// The encoder is strict where the decoder is lenient. Nothing here is a user's input —
/// it is either the app fabricating traffic for a test or a future bot implementation,
/// and a silently clamped field would be a protocol bug that only shows up as a wrong
/// number on someone else's screen.
public enum MeshWXEncodeError: Error, Sendable, Hashable {
  /// A field was outside the range its wire type can hold.
  case outOfRange(field: String, value: Int)
  /// The datagram was over ``MeshWXWire/maxData``.
  case oversize(what: String, bytes: Int)
  /// A repeated field had the wrong number of elements (vertices, runs, periods…).
  case badCount(what: String, count: Int, allowed: ClosedRange<Int>)
  /// Some stations in a batch carried an age and some did not. The ages are all or nothing
  /// (spec §6.1): a batch that told the truth about a few stations and left the rest to be
  /// guessed at would be worse than one that says nothing.
  case partialObservationAges(known: Int, stations: Int)
  /// A polygon vertex was more than ±32.767° from the previous one, so the 0.001°
  /// delta does not fit in an i16. Re-anchor or split the polygon.
  case polygonDeltaTooLarge(vertex: Int, axis: String, degrees: Double)
  /// Text needed more than ``MeshWXWire/maxTextChunks`` chunks.
  case textTooLong(chunks: Int)
  /// A single code point was wider than a whole chunk (not reachable with UTF-8, kept
  /// so the chunker has no unreachable `fatalError`).
  case codePointTooLarge
  /// A not-available request string had no letter after the `>` prefix.
  case emptyRequest
}

/// Encodes v5 datagrams (spec §3-§8).
///
/// The app does not run a bot, so why encode at all? Because a codec that is only ever
/// exercised in one direction drifts: the nine official vectors are a round trip, and
/// the app's own tests need to fabricate a tornado warning without waiting for one.
///
/// Rounding follows the reference's Python `round()` — half to *even* — everywhere the
/// reference rounds. It matters in exactly one place (a polygon delta landing on an
/// exact half), and matching it is cheaper than reasoning about when it cannot happen.
public enum MeshWXEncoder {

  // MARK: - Header

  public static func header(
    seq: UInt8, bot: UInt16, type: MeshWXMessageType, flags: UInt8 = 0
  ) throws -> Data {
    try header(seq: seq, bot: bot, rawType: type.rawValue, flags: flags)
  }

  static func header(seq: UInt8, bot: UInt16, rawType: UInt8, flags: UInt8) throws -> Data {
    guard rawType <= 15 else { throw MeshWXEncodeError.outOfRange(field: "type", value: Int(rawType)) }
    guard flags <= 15 else { throw MeshWXEncodeError.outOfRange(field: "flags", value: Int(flags)) }
    var out = Data(capacity: MeshWXWire.maxData)
    out.append(seq)
    out.appendU16(bot)
    out.append((rawType << 4) | flags)
    return out
  }

  // MARK: - Warning (type 1, spec §3)

  public static func warning(
    seq: UInt8,
    bot: UInt16,
    identity: MeshWXWarningIdentity,
    expiresMinutes: UInt32,
    tornado: MeshWXTornadoTag = .none,
    floodSource: MeshWXFloodSource = .none,
    floodDamage: MeshWXFloodDamage = .none,
    hailQuarterInches: UInt8 = 0,
    windMph: UInt8 = 0,
    polygon: [MeshWXCoordinate]? = nil,
    areas: [MeshWXAreaRun]? = nil,
    isUpdate: Bool = false,
    issuedMinutes: UInt32? = nil
  ) throws -> Data {
    var tags =
      (tornado.rawValue << 6) | (floodSource.rawValue << 4) | (floodDamage.rawValue << 2)
    // An empty array is "no polygon", matching Python's truthiness test: a zero-vertex
    // polygon has no encoding, and setting the bit would promise bytes that follow.
    let hasPolygon = !(polygon ?? []).isEmpty
    let hasAreas = !(areas ?? []).isEmpty
    if hasPolygon { tags |= MeshWXWire.tagPolygon }
    if hasAreas { tags |= MeshWXWire.tagAreas }

    var flags: UInt8 = isUpdate ? MeshWXWire.flagWarningUpdate : 0
    if issuedMinutes != nil { flags |= MeshWXWire.flagWarningIssued }

    var out = try header(seq: seq, bot: bot, type: .warning, flags: flags)
    out.append(identity.event)
    out.append(identity.office)
    out.appendU16(identity.etn)
    out.appendU32(expiresMinutes)
    out.append(tags)
    out.append(hailQuarterInches)
    out.append(windMph)

    if hasPolygon, let polygon { out.append(try encodePolygon(polygon)) }
    if hasAreas, let areas { out.append(try encodeAreas(areas)) }
    // Last of all, so a revision 4 decoder stops after the area list (spec §3). The gap
    // saturates rather than wrapping, and a product issued after its own expiry — which no real
    // one is — encodes as 0 rather than failing the message over a bad clock.
    if let issuedMinutes {
      let before = Int(expiresMinutes) - Int(issuedMinutes)
      out.appendU16(
        UInt16(max(0, min(Int(MeshWXWire.issuedBeforeSaturatedMinutes), before))))
    }
    return try checkSize(out, "warning")
  }

  /// Convenience for the round trip: re-encode a decoded warning under a fresh header.
  public static func warning(seq: UInt8, bot: UInt16, _ warning: MeshWXWarning) throws -> Data {
    try self.warning(
      seq: seq,
      bot: bot,
      identity: warning.identity,
      expiresMinutes: warning.expiresMinutes,
      tornado: warning.tornado,
      floodSource: warning.floodSource,
      floodDamage: warning.floodDamage,
      hailQuarterInches: warning.hailQuarterInches,
      windMph: warning.windMph,
      polygon: warning.polygon,
      areas: warning.areas,
      isUpdate: warning.isUpdate,
      // Resolved and subtracted back: `expires − (expires − before)` is the same two bytes,
      // saturation included, so the round trip stays byte-identical.
      issuedMinutes: warning.issuedMinutes
    )
  }

  private static func encodePolygon(_ polygon: [MeshWXCoordinate]) throws -> Data {
    let count = polygon.count
    guard (MeshWXWire.minPolygonVertices...MeshWXWire.maxPolygonVertices).contains(count) else {
      throw MeshWXEncodeError.badCount(
        what: "polygon vertices", count: count,
        allowed: MeshWXWire.minPolygonVertices...MeshWXWire.maxPolygonVertices)
    }
    let anchor = polygon[0]
    let latAnchor = Int((anchor.latitude * 10000).rounded(.toNearestOrEven))
    let lonAnchor = Int((anchor.longitude * 10000).rounded(.toNearestOrEven))

    var out = Data()
    out.append(UInt8(count))
    try out.appendI24(latAnchor, field: "polygon lat0")
    try out.appendI24(lonAnchor, field: "polygon lon0")

    // Deltas run against the *reconstructed* previous vertex, never against the caller's
    // originals: that is what stops a 30-vertex chain from accumulating a quarter-mile
    // of drift by the time a decoder walks it.
    var previousLat = Double(latAnchor) / 10000
    var previousLon = Double(lonAnchor) / 10000
    for (position, vertex) in polygon.dropFirst().enumerated() {
      let deltaLat = ((vertex.latitude - previousLat) * 1000).rounded(.toNearestOrEven)
      let deltaLon = ((vertex.longitude - previousLon) * 1000).rounded(.toNearestOrEven)
      for (value, axis) in [(deltaLat, "lat"), (deltaLon, "lon")] {
        guard value >= -32768, value <= 32767 else {
          throw MeshWXEncodeError.polygonDeltaTooLarge(
            vertex: position + 1, axis: axis, degrees: value / 1000)
        }
      }
      out.appendI16(Int16(deltaLat))
      out.appendI16(Int16(deltaLon))
      previousLat += deltaLat / 1000
      previousLon += deltaLon / 1000
    }
    return out
  }

  /// The counted run list of spec §3. A warning sets the tag bit only when it has runs, so an
  /// empty list has no encoding there; a Coverage message counts them the same way but may
  /// legitimately carry none (`k` = 0, spec §7A), hence `allowingEmpty`.
  private static func encodeAreas(
    _ areas: [MeshWXAreaRun], what: String = "area runs", allowingEmpty: Bool = false
  ) throws -> Data {
    let allowed = (allowingEmpty ? 0 : 1)...MeshWXWire.maxAreaRuns
    guard allowed.contains(areas.count) else {
      throw MeshWXEncodeError.badCount(what: what, count: areas.count, allowed: allowed)
    }
    var out = Data()
    out.append(UInt8(areas.count))
    for area in areas {
      guard area.stateIndex <= 127 else {
        throw MeshWXEncodeError.outOfRange(field: "state index", value: Int(area.stateIndex))
      }
      guard area.run >= 1 else {
        throw MeshWXEncodeError.outOfRange(field: "run length", value: Int(area.run))
      }
      out.append((area.isCounty ? MeshWXWire.areaCountyBit : 0) | area.stateIndex)
      out.appendU16(area.start)
      out.append(area.run)
    }
    return out
  }

  // MARK: - Cancel (type 2, spec §4)

  public static func cancel(
    seq: UInt8, bot: UInt16, identity: MeshWXWarningIdentity,
    reason: MeshWXCancelReason = .cancelled
  ) throws -> Data {
    // The reason rides in the flags nibble, so it is capped there, not here.
    var out = try header(seq: seq, bot: bot, type: .cancel, flags: reason.rawValue)
    out.append(identity.event)
    out.append(identity.office)
    out.appendU16(identity.etn)
    return try checkSize(out, "cancel")
  }

  public static func cancel(seq: UInt8, bot: UInt16, _ cancel: MeshWXCancel) throws -> Data {
    try self.cancel(seq: seq, bot: bot, identity: cancel.identity, reason: cancel.reason)
  }

  // MARK: - Digest (type 3, spec §5)

  /// Entries carry an *absolute* expiry; the wire gets `expires − now`, clamped into a
  /// u16 (spec §5). A warning already expired when the digest was built encodes as 0
  /// rather than wrapping to 18 hours.
  public static func digest(
    seq: UInt8,
    bot: UInt16,
    nowMinutes: UInt32,
    feedHealth: UInt8,
    entries: [(identity: MeshWXWarningIdentity, expiresMinutes: UInt32)]
  ) throws -> Data {
    guard entries.count <= MeshWXWire.maxDigestEntries else {
      throw MeshWXEncodeError.badCount(
        what: "digest entries", count: entries.count, allowed: 0...MeshWXWire.maxDigestEntries)
    }
    var out = try header(seq: seq, bot: bot, type: .digest)
    out.appendU32(nowMinutes)
    out.append(feedHealth)
    out.append(UInt8(entries.count))
    for entry in entries {
      let relative = min(UInt32(UInt16.max), entry.expiresMinutes &- min(entry.expiresMinutes, nowMinutes))
      out.append(entry.identity.event)
      out.append(entry.identity.office)
      out.appendU16(entry.identity.etn)
      out.appendU16(UInt16(relative))
    }
    return try checkSize(out, "digest")
  }

  public static func digest(seq: UInt8, bot: UInt16, _ digest: MeshWXDigest) throws -> Data {
    try self.digest(
      seq: seq,
      bot: bot,
      nowMinutes: digest.nowMinutes,
      feedHealth: digest.feedHealth,
      entries: digest.entries.map { ($0.identity, $0.expiresMinutes) }
    )
  }

  // MARK: - Observations (type 4, spec §6)

  /// A station carrying ``MeshWXStationObservation/ageMinutes`` puts the batch into the
  /// revision 5 form: flags nibble bit 0 and a trailing block of age nibbles (spec §6.1). The
  /// ages are all or nothing, and because the block costs `ceil(n / 2)` bytes on top of an
  /// already 163-byte full batch, 14 stations with ages do not fit in one packet — the size
  /// check below is what refuses them (``MeshWXWire/maxStationsWithAges``).
  public static func observations(
    seq: UInt8, bot: UInt16, timestampMinutes: UInt32, stations: [MeshWXStationObservation]
  ) throws -> Data {
    guard (1...MeshWXWire.maxStations).contains(stations.count) else {
      throw MeshWXEncodeError.badCount(
        what: "observation stations", count: stations.count, allowed: 1...MeshWXWire.maxStations)
    }
    let ages = stations.map(\.ageMinutes)
    let known = ages.compactMap { $0 }
    guard known.isEmpty || known.count == stations.count else {
      throw MeshWXEncodeError.partialObservationAges(
        known: known.count, stations: stations.count)
    }
    let hasAges = known.count == stations.count

    var out = try header(
      seq: seq, bot: bot, type: .observations,
      flags: hasAges ? MeshWXWire.flagObservationAges : 0)
    out.appendU32(timestampMinutes)
    out.append(UInt8(stations.count))
    for station in stations {
      out.appendU16(station.stationIndex)
      out.append(UInt8(bitPattern: station.tempF ?? MeshWXWire.temperatureUnknown))
      out.append(UInt8(bitPattern: station.dewpointF ?? MeshWXWire.temperatureUnknown))
      out.append((station.windDirection.rawValue << 4) | station.sky.rawValue)
      out.append(station.windMph ?? MeshWXWire.unsignedUnknown)
      out.append(station.gustMph)
      out.append(station.visibilityMiles ?? MeshWXWire.unsignedUnknown)
      out.append(try pressureByte(station.pressureInHg))
      out.append(station.humidityPercent ?? MeshWXWire.unsignedUnknown)
      out.append(UInt8(bitPattern: station.feelsDeltaF))
    }
    if hasAges { out.append(encodeAges(known)) }
    return try checkSize(out, "observations")
  }

  public static func observations(
    seq: UInt8, bot: UInt16, _ observations: MeshWXObservations
  ) throws -> Data {
    try self.observations(
      seq: seq, bot: bot, timestampMinutes: observations.timestampMinutes,
      stations: observations.stations)
  }

  /// The per-station age block: one nibble each, two stations to a byte, station `i` in the low
  /// nibble of byte `i / 2` when `i` is even and the high nibble when it is odd. An odd station
  /// count leaves the last high nibble as 0 padding (spec §6.1).
  private static func encodeAges(_ ages: [UInt16]) -> Data {
    var block = [UInt8](repeating: 0, count: (ages.count + 1) / 2)
    for (index, age) in ages.enumerated() {
      let nibble = ageNibble(age)
      block[index / 2] |= index % 2 == 0 ? nibble : nibble << 4
    }
    return Data(block)
  }

  /// One station's age as a 10-minute step, 0…15, rounding half up — the reference's
  /// `_age_nibble`. To the nearest step rather than down, which keeps the error symmetric: a
  /// reading is never presented as more than 4 minutes fresher than it is. 15 is a saturation,
  /// so anything past 150 minutes clamps to "150 or more" instead of wrapping.
  private static func ageNibble(_ minutes: UInt16) -> UInt8 {
    let step = Int(MeshWXWire.observationAgeStepMinutes)
    return UInt8(min(15, (Int(minutes) + step / 2) / step))
  }

  /// `(inHg − 29.00) × 100`, so the byte covers 29.00 to 31.54 inHg. Sea-level pressure
  /// outside that window does not happen outside a hurricane eye, and 255 is taken.
  private static func pressureByte(_ inHg: Double?) throws -> UInt8 {
    guard let inHg else { return MeshWXWire.unsignedUnknown }
    let raw = ((inHg - 29.00) * 100).rounded(.toNearestOrEven)
    guard raw >= 0, raw <= 254 else {
      throw MeshWXEncodeError.outOfRange(field: "pressure_inhg", value: Int(raw))
    }
    return UInt8(raw)
  }

  // MARK: - Forecast (type 5, spec §7)

  public static func forecast(
    seq: UInt8, bot: UInt16, pointIndex: UInt16, issuedMinutes: UInt32, firstPeriod: UInt8,
    periods: [MeshWXForecastPeriod]
  ) throws -> Data {
    guard (1...MeshWXWire.maxPeriods).contains(periods.count) else {
      throw MeshWXEncodeError.badCount(
        what: "forecast periods", count: periods.count, allowed: 1...MeshWXWire.maxPeriods)
    }
    var out = try header(seq: seq, bot: bot, type: .forecast)
    out.appendU16(pointIndex)
    out.appendU32(issuedMinutes)
    out.append(firstPeriod)
    out.append(UInt8(periods.count))
    for period in periods {
      var condition = period.sky.rawValue
      if period.thunder { condition |= 0x10 }
      if period.wintry { condition |= 0x20 }
      if period.windy { condition |= 0x40 }
      if period.fog { condition |= 0x80 }
      // Speed is a nibble of 5 mph steps; 15 means "75 or more", so clamping up is the
      // spec's own behaviour rather than a lossy shortcut.
      let speedNibble = UInt8(min(15, (Double(period.windMph) / 5).rounded(.toNearestOrEven)))
      out.append(UInt8(bitPattern: period.highF ?? MeshWXWire.forecastTemperatureNotGiven))
      out.append(UInt8(bitPattern: period.lowF ?? MeshWXWire.forecastTemperatureNotGiven))
      out.append(period.popPercent ?? MeshWXWire.unsignedUnknown)
      out.append(condition)
      out.append((period.windDirection.rawValue << 4) | speedNibble)
    }
    return try checkSize(out, "forecast")
  }

  public static func forecast(seq: UInt8, bot: UInt16, _ forecast: MeshWXForecast) throws -> Data {
    try self.forecast(
      seq: seq, bot: bot, pointIndex: forecast.pointIndex, issuedMinutes: forecast.issuedMinutes,
      firstPeriod: forecast.firstPeriod, periods: forecast.periods)
  }

  // MARK: - Text (type 6, spec §8.1)

  public static func text(
    seq: UInt8, bot: UInt16, subject: MeshWXTextSubject, group: UInt8, index: UInt8, total: UInt8,
    text: String
  ) throws -> Data {
    guard (1...MeshWXWire.maxTextChunks).contains(Int(total)) else {
      throw MeshWXEncodeError.badCount(
        what: "text total", count: Int(total), allowed: 1...MeshWXWire.maxTextChunks)
    }
    guard index < total else {
      throw MeshWXEncodeError.outOfRange(field: "text index", value: Int(index))
    }
    let body = Data(text.utf8)
    guard body.count <= MeshWXWire.maxTextBytes else {
      throw MeshWXEncodeError.oversize(what: "text chunk", bytes: body.count)
    }
    var out = try header(seq: seq, bot: bot, type: .text)
    out.append(subject.rawValue)
    out.append(group)
    out.append(index)
    out.append(total)
    out.append(body)
    return try checkSize(out, "text")
  }

  public static func text(seq: UInt8, bot: UInt16, _ message: MeshWXText) throws -> Data {
    try text(
      seq: seq, bot: bot, subject: message.subject, group: message.group, index: message.index,
      total: message.total, text: message.text)
  }

  /// Split a reply into Text chunks.
  ///
  /// Chunks never split a UTF-8 code point — an accented place name cut in half is two
  /// unreadable chunks, not one — carry at most 157 text bytes, share
  /// `group = seqStart`, and take consecutive sequence numbers wrapping 255 → 0.
  public static func textChunks(
    seqStart: UInt8, bot: UInt16, subject: MeshWXTextSubject, text: String
  ) throws -> [Data] {
    let body = Array(text.utf8)
    var parts: [ArraySlice<UInt8>] = []
    var position = 0
    while position < body.count || parts.isEmpty {
      var end = min(position + MeshWXWire.maxTextBytes, body.count)
      // Back off to a code point boundary: continuation bytes are 0b10xxxxxx.
      while end > position, end < body.count, body[end] & 0xC0 == 0x80 {
        end -= 1
      }
      guard end > position || position >= body.count else {
        throw MeshWXEncodeError.codePointTooLarge
      }
      parts.append(body[position..<end])
      position = end
    }
    guard parts.count <= MeshWXWire.maxTextChunks else {
      throw MeshWXEncodeError.textTooLong(chunks: parts.count)
    }

    let total = UInt8(parts.count)
    return try parts.enumerated().map { offset, part in
      guard let chunk = String(bytes: part, encoding: .utf8) else {
        throw MeshWXEncodeError.codePointTooLarge
      }
      return try self.text(
        seq: seqStart &+ UInt8(offset), bot: bot, subject: subject, group: seqStart,
        index: UInt8(offset), total: total, text: chunk)
    }
  }

  // MARK: - Not available (type 7, spec §8.3)

  /// `request` is the request string (`">f round rock tx"`) or just its first letter;
  /// only the ASCII code of that letter goes on the wire.
  public static func notAvailable(
    seq: UInt8, bot: UInt16, request: String, reason: MeshWXNotAvailableReason
  ) throws -> Data {
    let stripped = request.drop { $0 == ">" }.drop(while: \.isWhitespace)
    guard let letter = stripped.first, let ascii = letter.asciiValue else {
      throw MeshWXEncodeError.emptyRequest
    }
    return try notAvailable(seq: seq, bot: bot, requestCode: ascii, reason: reason)
  }

  public static func notAvailable(
    seq: UInt8, bot: UInt16, requestCode: UInt8, reason: MeshWXNotAvailableReason
  ) throws -> Data {
    var out = try header(seq: seq, bot: bot, type: .notAvailable)
    out.append(requestCode)
    out.append(reason.rawValue)
    return try checkSize(out, "not_available")
  }

  public static func notAvailable(
    seq: UInt8, bot: UInt16, _ message: MeshWXNotAvailable
  ) throws -> Data {
    try notAvailable(
      seq: seq, bot: bot, requestCode: message.requestCode, reason: message.reason)
  }

  // MARK: - Coverage (type 8, spec §7A)

  /// The app never sends this — only a bot states its own coverage — but the vector round trip
  /// and the coverage tests both need the bytes, and a codec exercised in one direction drifts.
  ///
  /// The offices go out in the order given: the bot sends them ascending, and sorting them here
  /// would hide a caller that did not rather than reproduce what arrived.
  public static func coverage(
    seq: UInt8,
    bot: UInt16,
    latitude: Double,
    longitude: Double,
    radiusKilometres: UInt16,
    stationCap: UInt8,
    officeIndices: [UInt8],
    areas: [MeshWXAreaRun],
    areasCut: Bool = false,
    officesCut: Bool = false
  ) throws -> Data {
    guard officeIndices.count <= MeshWXWire.maxCoverageOffices else {
      throw MeshWXEncodeError.badCount(
        what: "coverage offices", count: officeIndices.count,
        allowed: 0...MeshWXWire.maxCoverageOffices)
    }
    var flags: UInt8 = 0
    if areasCut { flags |= MeshWXWire.flagCoverageZonesCut }
    if officesCut { flags |= MeshWXWire.flagCoverageOfficesCut }

    var out = try header(seq: seq, bot: bot, type: .coverage, flags: flags)
    try out.appendI24(Int((latitude * 10000).rounded(.toNearestOrEven)), field: "coverage lat")
    try out.appendI24(Int((longitude * 10000).rounded(.toNearestOrEven)), field: "coverage lon")
    out.appendU16(radiusKilometres)
    out.append(stationCap)
    out.append(UInt8(officeIndices.count))
    out.append(contentsOf: officeIndices)
    out.append(try encodeAreas(areas, what: "coverage runs", allowingEmpty: true))
    return try checkSize(out, "coverage")
  }

  public static func coverage(seq: UInt8, bot: UInt16, _ coverage: MeshWXCoverage) throws -> Data {
    try self.coverage(
      seq: seq,
      bot: bot,
      latitude: coverage.latitude,
      longitude: coverage.longitude,
      radiusKilometres: coverage.radiusKilometres,
      stationCap: coverage.stationCap,
      officeIndices: coverage.officeIndices,
      areas: coverage.areas,
      areasCut: coverage.areasCut,
      officesCut: coverage.officesCut
    )
  }

  // MARK: - Request (type 9, spec §7B)

  /// The app's own `>` request, as the datagram it is flooded on `#meshwx` as.
  ///
  /// The one message this app transmits, so this is the one encoder whose output goes on the
  /// air rather than into a test. Strict about all three variable things — a six-byte key
  /// prefix, a non-empty text that starts with `>`, and 40 bytes of it at most — because a
  /// request the bot cannot parse is silence, and silence is what the datagram exists to fix.
  ///
  /// - Parameters:
  ///   - seq: the **sender's** counter, repeated on a resend.
  ///   - bot: the bot asked; ``MeshWXRequest/anyBot`` asks them all.
  ///   - senderPrefix: the first six bytes of this phone's public key, in key order.
  ///   - timestamp: Unix seconds on the sender's clock; a resend repeats it.
  ///   - text: the §8.2 request, starting with `>`.
  public static func request(
    seq: UInt8, bot: UInt16, senderPrefix: Data, timestamp: UInt32, text: String
  ) throws -> Data {
    guard senderPrefix.count == MeshWXWire.requestSenderPrefixSize else {
      throw MeshWXEncodeError.badCount(
        what: "request sender", count: senderPrefix.count,
        allowed: MeshWXWire.requestSenderPrefixSize...MeshWXWire.requestSenderPrefixSize)
    }
    let bytes = Array(text.utf8)
    guard text.hasPrefix(">"), bytes.count > 1 else { throw MeshWXEncodeError.emptyRequest }
    guard bytes.count <= MeshWXWire.maxRequestTextBytes else {
      throw MeshWXEncodeError.oversize(what: "request text", bytes: bytes.count)
    }
    var out = try header(seq: seq, bot: bot, type: .request)
    out.append(senderPrefix)
    out.appendU32(timestamp)
    out.append(contentsOf: bytes)
    return try checkSize(out, "request")
  }

  /// The body's own fields under the header fields given, so a re-encode takes `seq` and `bot`
  /// from the message's header exactly as every other type does.
  public static func request(seq: UInt8, bot: UInt16, _ request: MeshWXRequest) throws -> Data {
    try self.request(
      seq: seq, bot: bot, senderPrefix: request.senderPrefix, timestamp: request.timestamp,
      text: request.text)
  }

  // MARK: - Round trip

  /// Re-encode a decoded message, header and all.
  ///
  /// This is what the vector suite runs: decode every official hex, encode it back, and
  /// compare the bytes. An ``MeshWXPayload/unknown`` body has no encoding — the decoder
  /// kept only the header — so it is refused rather than emitted as a 4-byte stub that
  /// would look like a valid message of a type we do not implement.
  public static func encode(_ message: MeshWXMessage) throws -> Data {
    let seq = message.header.seq
    let bot = message.header.bot
    switch message.payload {
    case .warning(let warning): return try self.warning(seq: seq, bot: bot, warning)
    case .cancel(let cancel): return try self.cancel(seq: seq, bot: bot, cancel)
    case .digest(let digest): return try self.digest(seq: seq, bot: bot, digest)
    case .observations(let obs): return try observations(seq: seq, bot: bot, obs)
    case .forecast(let forecast): return try self.forecast(seq: seq, bot: bot, forecast)
    case .text(let text): return try self.text(seq: seq, bot: bot, text)
    case .notAvailable(let na): return try notAvailable(seq: seq, bot: bot, na)
    case .coverage(let coverage): return try self.coverage(seq: seq, bot: bot, coverage)
    case .request(let request): return try self.request(seq: seq, bot: bot, request)
    case .unknown:
      throw MeshWXEncodeError.outOfRange(field: "type", value: Int(message.header.rawType))
    }
  }

  // MARK: - Primitives

  private static func checkSize(_ data: Data, _ what: String) throws -> Data {
    guard data.count <= MeshWXWire.maxData else {
      throw MeshWXEncodeError.oversize(what: what, bytes: data.count)
    }
    return data
  }
}

// Little-endian appenders (spec §2.4). Private to the module: nothing outside builds
// v5 bytes by hand.
extension Data {
  mutating func appendU16(_ value: UInt16) {
    append(UInt8(truncatingIfNeeded: value))
    append(UInt8(truncatingIfNeeded: value >> 8))
  }

  mutating func appendI16(_ value: Int16) {
    appendU16(UInt16(bitPattern: value))
  }

  mutating func appendU32(_ value: UInt32) {
    append(UInt8(truncatingIfNeeded: value))
    append(UInt8(truncatingIfNeeded: value >> 8))
    append(UInt8(truncatingIfNeeded: value >> 16))
    append(UInt8(truncatingIfNeeded: value >> 24))
  }

  mutating func appendI24(_ value: Int, field: String) throws {
    guard value >= -(1 << 23), value < (1 << 23) else {
      throw MeshWXEncodeError.outOfRange(field: field, value: value)
    }
    let raw = UInt32(bitPattern: Int32(value)) & 0xFF_FFFF
    append(UInt8(truncatingIfNeeded: raw))
    append(UInt8(truncatingIfNeeded: raw >> 8))
    append(UInt8(truncatingIfNeeded: raw >> 16))
  }
}
