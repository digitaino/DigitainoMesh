#if DEBUG
  import Foundation
  import MapperRawLog
  import MC1Services
  import MeshCore
  import SurveyKit

  /// Fixture rows for the card and repeater-detail previews.
  ///
  /// Deliberately fed through the *real* builders (``SignalMapperSnapshotBuilder``,
  /// ``SignalMapperCardBuilder``) rather than hand-assembled display models: a preview that
  /// invents its own numbers can look right while the arithmetic under it is wrong, which on
  /// a screen with no data in the simulator is the only check anyone gets before a ride.
  enum SignalMapperPreviewFixtures {
    /// A real res-9 index, so `SurveyGrid` returns a boundary rather than nothing.
    static let cellRaw: UInt64 = 0x0892_8308_280F_FFFF
    static let now = Date(timeIntervalSince1970: 1_756_900_000)
    static let since = now.addingTimeInterval(-3600)

    static let summary = MapperCellSummaryDTO(
      cellRaw: cellRaw,
      rxBestSnr: 13,
      rxSnrSum: 61,
      rxSnrCount: 10,
      rxLastAt: now.addingTimeInterval(-8),
      txBestSnr: 13,
      txSnrSum: 39,
      txSnrCount: 3,
      txLastAt: now.addingTimeInterval(-8),
      echoCount: 2,
      echoLastAt: now.addingTimeInterval(-120),
      probesSent: 6,
      sentCount: 4,
      heardCount: 1048,
      firstAt: since,
      lastAt: now.addingTimeInterval(-8)
    )

    /// Nil only if the fixture index ever stops being a valid H3 cell — which is exactly the
    /// case a preview should show as "nothing" rather than crash on.
    static var cell: SignalMapperMapCell? {
      SignalMapperSnapshotBuilder.build(summaries: [summary]).cells.first
    }

    static var cardData: SignalMapperCardData? {
      guard let h3 = H3Cell(rawValue: cellRaw) else { return nil }
      return SignalMapperCardBuilder().build(
        cell: h3,
        scope: .allTime,
        since: since,
        rows: rows,
        now: now
      )
    }

    static var rows: [MapperRawSampleDTO] {
      var seq: Int64 = 0
      func row(
        _ offset: TimeInterval,
        _ kind: MapperRawSampleKind,
        hexID: String?,
        rxSnr: Double? = nil,
        txSnr: Double? = nil,
        rssi: Int? = nil,
        hops: Int? = nil,
        route: RouteType? = nil,
        payload: PayloadType? = nil,
        pathHashes: [String]? = nil
      ) -> MapperRawSampleDTO {
        seq += 1
        return MapperRawSampleDTO(
          runID: nil,
          seq: seq,
          timestamp: now.addingTimeInterval(offset),
          kindRaw: kind.rawValue,
          rxSnr: rxSnr,
          txSnr: txSnr,
          rssi: rssi,
          hopCount: hops,
          routeTypeRaw: route.map { Int($0.rawValue) },
          payloadTypeRaw: payload.map { Int($0.rawValue) },
          pathHashes: pathHashes,
          repeaterHexID: hexID,
          cellRaw: cellRaw,
          gateOutcomeRaw: MapperGateOutcome.accepted.rawValue
        )
      }

      // Every step of the six-step scale the map paints hexagons with appears here, on one
      // leg or the other, so one screenshot of the card shows the bars glyphs and the
      // leading rail at each colour instead of three greens: 0C13 excellent, 4F70 good
      // (mint), 77B2 fair (yellow), 5E44 poor (orange), B107 very poor (red), and D3F1 with
      // no downlink reading at all — the unknown rail beside a measured uplink, which is the
      // asymmetry the Reach layer exists to show.
      return [
        row(-8, .passiveRx, hexID: "0C13", rxSnr: 12.5, rssi: -72, hops: 2, route: .flood),
        // The same repeater under a 1-byte path hash. MeshCore sends 1- or 2-byte hop
        // hashes depending on the packet, and keying on the raw string made the card list
        // "Digitaino Central 0C13" and "Digitaino Central 0C" as two repeaters (Rafael's
        // ride, 2026-09-05). Here it must fold into 0C13 and appear once, so the preview
        // shows the merge rather than the defect.
        row(-30, .passiveRx, hexID: "0C", rxSnr: 11, rssi: -75, hops: 1, route: .flood),
        row(-70, .probeTraceReply, hexID: "0C", txSnr: 9),
        row(-45, .probeDiscoverResponse, hexID: "0C13", rxSnr: 12, txSnr: 13),
        row(-95, .txHeard, hexID: "0C13", rxSnr: 12, pathHashes: ["0C13"]),
        row(-160, .passiveRx, hexID: "0C13", rxSnr: 13, rssi: -70, hops: 0, payload: .advert),
        row(-120, .passiveRx, hexID: "9A21", rxSnr: 9, rssi: -88, hops: 1, route: .flood),
        row(-300, .passiveRx, hexID: "9A21", rxSnr: 11.5, rssi: -80, hops: 1, route: .flood),
        row(-360, .txHeard, hexID: "9A21", rxSnr: 8, pathHashes: ["9A21"]),
        row(-380, .passiveRx, hexID: "4F70", rxSnr: 7.5, rssi: -95, hops: 3, route: .flood),
        row(-400, .probeTraceReply, hexID: "4F70", rxSnr: 7, txSnr: 7),
        // Answered a trace, never measured by this radio: no downlink numbers, a real
        // uplink one. Its rail is grey on Hear and mint on Reach.
        row(-150, .probeTraceReply, hexID: "D3F1", txSnr: 6),
        row(-200, .passiveRx, hexID: "5E44", rxSnr: -3.5, rssi: -112, hops: 4, route: .flood),
        row(-260, .probeDiscoverResponse, hexID: "5E44", rxSnr: -4, txSnr: -6),
        row(-320, .passiveRx, hexID: "B107", rxSnr: -13, rssi: -119, hops: 5, route: .flood),
        // The stale case: outside §1's ten-minute "now", so the whole row — rail, bars and
        // numbers together — steps back to 55%.
        row(-2500, .passiveRx, hexID: "77B2", rxSnr: 4.5, rssi: -101, hops: 2, route: .flood),
        row(-2600, .probeAttempt, hexID: nil)
      ]
    }
  }
#endif
