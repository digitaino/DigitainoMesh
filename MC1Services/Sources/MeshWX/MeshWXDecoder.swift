import Foundation

/// Why a v5 datagram could not be decoded.
///
/// Every case names what was being read and how far the bytes got, because the only
/// diagnostic an app has for a bad packet is the log line: the radio is gone by then
/// and the bot will not repeat itself on request.
public enum MeshWXDecodeError: Error, Sendable, Hashable {
  /// The payload ended before a field did.
  case truncated(what: String, need: Int, have: Int)
  /// A Text chunk's body was not valid UTF-8 (a chunk boundary in the wrong place, or
  /// a corrupted packet that still passed the frame MAC).
  case badUTF8
}

/// Decodes one v5 datagram (spec §3-§8).
///
/// A decoder is the one place in a radio app that must never trap: the bytes come off
/// the air, a neighbour's firmware may be older or newer, and the type nibble has eight
/// values reserved for products that do not exist yet. So every length is checked
/// before it is read, an unknown type yields ``MeshWXPayload/unknown`` rather than an
/// error (the header still decoded, and `(bot, seq)` tracking depends on it), and
/// nothing here force-unwraps.
public enum MeshWXDecoder {

  /// Decode one datagram — the `data` field of a `GRP_DATA` packet with
  /// `data_type == MeshWXWire.dataType`.
  public static func decode(_ data: Data) throws -> MeshWXMessage {
    // Copy into a zero-based array: `Data` sliced off a receive buffer keeps its parent
    // indices, and reading it as if it started at 0 is a classic out-of-bounds trap.
    //
    // Deliberately no upper-bound check: the reference decoder has none, and a bot that
    // one day overruns the 165-byte budget by a byte should still get its text read
    // rather than dropped. The *encoder* enforces the limit, which is where it matters.
    let bytes = [UInt8](data)
    let header = try decodeHeader(bytes)
    let payload: MeshWXPayload =
      switch header.type {
      case .warning: .warning(try decodeWarning(bytes, header: header))
      case .cancel: .cancel(try decodeCancel(bytes, header: header))
      case .digest: .digest(try decodeDigest(bytes))
      case .observations: .observations(try decodeObservations(bytes))
      case .forecast: .forecast(try decodeForecast(bytes))
      case .text: .text(try decodeText(bytes))
      case .notAvailable: .notAvailable(try decodeNotAvailable(bytes))
      case nil: .unknown
      }
    return MeshWXMessage(header: header, payload: payload)
  }

  /// Decode just the 4-byte common header, for dedupe and gap detection before the body
  /// is worth parsing.
  public static func decodeHeader(_ data: Data) throws -> MeshWXHeader {
    try decodeHeader([UInt8](data))
  }

  // MARK: - Header

  static func decodeHeader(_ bytes: [UInt8]) throws -> MeshWXHeader {
    try need(bytes, MeshWXWire.headerSize, "header")
    let typeByte = bytes[3]
    return MeshWXHeader(
      seq: bytes[0],
      bot: u16(bytes, 1),
      rawType: typeByte >> 4,
      flags: typeByte & 0x0F
    )
  }

  // MARK: - Warning (type 1, spec §3)

  static func decodeWarning(_ bytes: [UInt8], header: MeshWXHeader) throws -> MeshWXWarning {
    try need(bytes, MeshWXWire.warningFixedSize, "warning")
    let identity = MeshWXWarningIdentity(event: bytes[4], office: bytes[5], etn: u16(bytes, 6))
    let expires = u32(bytes, 8)
    let tags = bytes[12]

    var warning = MeshWXWarning(
      identity: identity,
      expiresMinutes: expires,
      tornado: MeshWXTornadoTag(rawValue: (tags >> 6) & 0x3) ?? .none,
      floodSource: MeshWXFloodSource(rawValue: (tags >> 4) & 0x3) ?? .none,
      floodDamage: MeshWXFloodDamage(rawValue: (tags >> 2) & 0x3) ?? .none,
      hailQuarterInches: bytes[13],
      windMph: bytes[14],
      isUpdate: header.flags & MeshWXWire.flagWarningUpdate != 0
    )

    var offset = MeshWXWire.warningFixedSize
    if tags & MeshWXWire.tagPolygon != 0 {
      warning.polygon = try decodePolygon(bytes, at: &offset)
    }
    if tags & MeshWXWire.tagAreas != 0 {
      warning.areas = try decodeAreas(bytes, at: &offset)
    }
    return warning
  }

  /// The anchor vertex is absolute at 0.0001°; every other vertex is a delta at 0.001°
  /// against the *reconstructed* previous one.
  ///
  /// Accumulation happens in whole 0.0001° units rather than in Double, which is what
  /// makes a re-encode reproduce the original deltas: walking the chain in floating
  /// point leaves each vertex a few ULPs off the grid, and a later `round(...×1000)`
  /// can then land on the wrong side of a half.
  private static func decodePolygon(
    _ bytes: [UInt8], at offset: inout Int
  ) throws -> [MeshWXCoordinate] {
    try need(bytes, offset + 1, "polygon count")
    let count = Int(bytes[offset])
    offset += 1
    let deltaCount = max(0, count - 1)
    try need(bytes, offset + 6 + 4 * deltaCount, "polygon")

    var latUnits = i24(bytes, offset)
    var lonUnits = i24(bytes, offset + 3)
    offset += 6

    var points = [MeshWXCoordinate(latitude: Double(latUnits) / 10000, longitude: Double(lonUnits) / 10000)]
    points.reserveCapacity(deltaCount + 1)
    for _ in 0..<deltaCount {
      // A 0.001° delta is ten 0.0001° units.
      latUnits += Int(i16(bytes, offset)) * 10
      lonUnits += Int(i16(bytes, offset + 2)) * 10
      offset += 4
      points.append(
        MeshWXCoordinate(latitude: Double(latUnits) / 10000, longitude: Double(lonUnits) / 10000))
    }
    return points
  }

  private static func decodeAreas(_ bytes: [UInt8], at offset: inout Int) throws -> [MeshWXAreaRun] {
    try need(bytes, offset + 1, "area count")
    let count = Int(bytes[offset])
    offset += 1
    try need(bytes, offset + 4 * count, "area runs")

    var runs: [MeshWXAreaRun] = []
    runs.reserveCapacity(count)
    for _ in 0..<count {
      let stateByte = bytes[offset]
      runs.append(
        MeshWXAreaRun(
          stateIndex: stateByte & 0x7F,
          isCounty: stateByte & MeshWXWire.areaCountyBit != 0,
          start: u16(bytes, offset + 1),
          run: bytes[offset + 3]
        ))
      offset += 4
    }
    return runs
  }

  // MARK: - Cancel (type 2, spec §4)

  static func decodeCancel(_ bytes: [UInt8], header: MeshWXHeader) throws -> MeshWXCancel {
    try need(bytes, MeshWXWire.cancelSize, "cancel")
    return MeshWXCancel(
      identity: MeshWXWarningIdentity(event: bytes[4], office: bytes[5], etn: u16(bytes, 6)),
      reason: MeshWXCancelReason(rawValue: header.flags)
    )
  }

  // MARK: - Digest (type 3, spec §5)

  static func decodeDigest(_ bytes: [UInt8]) throws -> MeshWXDigest {
    try need(bytes, MeshWXWire.digestFixedSize, "digest")
    let now = u32(bytes, 4)
    let feedHealth = bytes[8]
    let count = Int(bytes[9])
    try need(bytes, MeshWXWire.digestFixedSize + MeshWXWire.digestEntrySize * count, "digest entries")

    var entries: [MeshWXDigest.Entry] = []
    entries.reserveCapacity(count)
    var offset = MeshWXWire.digestFixedSize
    for _ in 0..<count {
      let relative = u16(bytes, offset + 4)
      entries.append(
        MeshWXDigest.Entry(
          identity: MeshWXWarningIdentity(
            event: bytes[offset], office: bytes[offset + 1], etn: u16(bytes, offset + 2)),
          expiresRelativeMinutes: relative,
          // `now` is a u32 of minutes since 1970 — around 29.8 million today — so the
          // sum cannot approach the u32 ceiling for another 8000 years. `&+` documents
          // that the arithmetic is the spec's, not a guess.
          expiresMinutes: now &+ UInt32(relative)
        ))
      offset += MeshWXWire.digestEntrySize
    }
    return MeshWXDigest(nowMinutes: now, feedHealth: feedHealth, entries: entries)
  }

  // MARK: - Observations (type 4, spec §6)

  static func decodeObservations(_ bytes: [UInt8]) throws -> MeshWXObservations {
    try need(bytes, MeshWXWire.observationsFixedSize, "observations")
    let timestamp = u32(bytes, 4)
    let count = Int(bytes[8])
    try need(
      bytes,
      MeshWXWire.observationsFixedSize + MeshWXWire.observationStationSize * count,
      "observation stations")

    var stations: [MeshWXStationObservation] = []
    stations.reserveCapacity(count)
    var offset = MeshWXWire.observationsFixedSize
    for _ in 0..<count {
      let directionAndSky = bytes[offset + 4]
      let pressure = bytes[offset + 8]
      stations.append(
        MeshWXStationObservation(
          stationIndex: u16(bytes, offset),
          tempF: signedOrNil(bytes[offset + 2], sentinel: MeshWXWire.temperatureUnknown),
          dewpointF: signedOrNil(bytes[offset + 3], sentinel: MeshWXWire.temperatureUnknown),
          windDirection: MeshWXCompass(nibble: directionAndSky >> 4),
          sky: MeshWXSky(nibble: directionAndSky),
          windMph: unsignedOrNil(bytes[offset + 5]),
          gustMph: bytes[offset + 6],
          visibilityMiles: unsignedOrNil(bytes[offset + 7]),
          // Exact two-decimal reconstruction: 29.00 + raw/100 built from integers is the
          // nearest Double to the decimal value, with none of the drift a float add has.
          pressureInHg: pressure == MeshWXWire.unsignedUnknown
            ? nil : Double(2900 + Int(pressure)) / 100,
          humidityPercent: unsignedOrNil(bytes[offset + 9]),
          feelsDeltaF: Int8(bitPattern: bytes[offset + 10])
        ))
      offset += MeshWXWire.observationStationSize
    }
    return MeshWXObservations(timestampMinutes: timestamp, stations: stations)
  }

  // MARK: - Forecast (type 5, spec §7)

  static func decodeForecast(_ bytes: [UInt8]) throws -> MeshWXForecast {
    try need(bytes, MeshWXWire.forecastFixedSize, "forecast")
    let point = u16(bytes, 4)
    let issued = u32(bytes, 6)
    let first = bytes[10]
    let count = Int(bytes[11])
    try need(
      bytes, MeshWXWire.forecastFixedSize + MeshWXWire.forecastPeriodSize * count,
      "forecast periods")

    var periods: [MeshWXForecastPeriod] = []
    periods.reserveCapacity(count)
    var offset = MeshWXWire.forecastFixedSize
    for _ in 0..<count {
      let condition = bytes[offset + 3]
      let wind = bytes[offset + 4]
      periods.append(
        MeshWXForecastPeriod(
          highF: signedOrNil(bytes[offset], sentinel: MeshWXWire.forecastTemperatureNotGiven),
          lowF: signedOrNil(bytes[offset + 1], sentinel: MeshWXWire.forecastTemperatureNotGiven),
          popPercent: unsignedOrNil(bytes[offset + 2]),
          sky: MeshWXSky(nibble: condition),
          thunder: condition & 0x10 != 0,
          wintry: condition & 0x20 != 0,
          windy: condition & 0x40 != 0,
          fog: condition & 0x80 != 0,
          windDirection: MeshWXCompass(nibble: wind >> 4),
          windMph: (wind & 0x0F) * 5
        ))
      offset += MeshWXWire.forecastPeriodSize
    }
    return MeshWXForecast(
      pointIndex: point, issuedMinutes: issued, firstPeriod: first, periods: periods)
  }

  // MARK: - Text (type 6, spec §8.1)

  static func decodeText(_ bytes: [UInt8]) throws -> MeshWXText {
    try need(bytes, MeshWXWire.textFixedSize, "text")
    let body = bytes[MeshWXWire.textFixedSize...]
    guard let text = String(bytes: body, encoding: .utf8) else {
      throw MeshWXDecodeError.badUTF8
    }
    return MeshWXText(
      subject: MeshWXTextSubject(rawValue: bytes[4]),
      group: bytes[5],
      index: bytes[6],
      total: bytes[7],
      text: text
    )
  }

  // MARK: - Not available (type 7, spec §8.3)

  static func decodeNotAvailable(_ bytes: [UInt8]) throws -> MeshWXNotAvailable {
    try need(bytes, MeshWXWire.notAvailableSize, "not_available")
    return MeshWXNotAvailable(
      requestCode: bytes[4],
      reason: MeshWXNotAvailableReason(rawValue: bytes[5])
    )
  }

  // MARK: - Primitives
  //
  // Little-endian everywhere (spec §2.4), two's complement for signed. Hand-rolled
  // rather than `withUnsafeBytes(loadUnaligned:)` because these run on arbitrary
  // offsets into a received buffer and the byte order must be the wire's, not the CPU's.

  private static func need(_ bytes: [UInt8], _ end: Int, _ what: String) throws {
    guard bytes.count >= end else {
      throw MeshWXDecodeError.truncated(what: what, need: end, have: bytes.count)
    }
  }

  private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
  }

  private static func i16(_ bytes: [UInt8], _ offset: Int) -> Int16 {
    Int16(bitPattern: u16(bytes, offset))
  }

  private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8) | (UInt32(bytes[offset + 2]) << 16)
      | (UInt32(bytes[offset + 3]) << 24)
  }

  private static func i24(_ bytes: [UInt8], _ offset: Int) -> Int {
    let raw = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8) | (Int(bytes[offset + 2]) << 16)
    return raw & 0x80_0000 != 0 ? raw - (1 << 24) : raw
  }

  private static func signedOrNil(_ byte: UInt8, sentinel: Int8) -> Int8? {
    let value = Int8(bitPattern: byte)
    return value == sentinel ? nil : value
  }

  private static func unsignedOrNil(_ byte: UInt8) -> UInt8? {
    byte == MeshWXWire.unsignedUnknown ? nil : byte
  }
}
