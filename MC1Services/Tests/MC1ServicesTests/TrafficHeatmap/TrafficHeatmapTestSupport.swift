import Foundation
@testable import MC1Services
import MeshCore

/// Fixtures shared by the traffic heatmap suites.
enum TrafficFixture {
  /// Fixed clock so nothing in these tests depends on the wall clock.
  static let now = Date(timeIntervalSince1970: 1_700_000_000)
  static let nowTS: UInt32 = 1_700_000_000

  /// A 32-byte public key beginning with `prefix`, padded with `fill`.
  static func key(_ prefix: [UInt8], fill: UInt8 = 0x77) -> Data {
    Data(prefix) + Data(repeating: fill, count: 32 - prefix.count)
  }

  /// A resolvable node standing at `latitude`/`longitude`, or nowhere when both are nil.
  static func node(
    _ prefix: [UInt8],
    fill: UInt8 = 0x77,
    name: String = "node",
    latitude: Double? = nil,
    longitude: Double? = nil,
    advert: UInt32 = TrafficFixture.nowTS,
    expiresWhenStale: Bool = false
  ) -> AnyResolvableNode {
    AnyResolvableNode(TestNode(
      publicKey: key(prefix, fill: fill),
      latitude: latitude ?? 0,
      longitude: longitude ?? 0,
      hasLocation: latitude != nil && longitude != nil,
      lastAdvertTimestamp: advert,
      recencyDate: .distantPast,
      resolvableName: name,
      expiresWhenStale: expiresWhenStale
    ))
  }

  /// An RX log entry whose path field carries `hops`, one entry per hop hash.
  ///
  /// - Parameters:
  ///   - hops: hop hashes in path order, sender first. Every hash must be `hashSize` wide.
  ///   - snr: the SNR the radio measured on reception — describing the last hop only.
  static func entry(
    hops: [[UInt8]],
    hashSize: Int = 1,
    snr: Double? = nil,
    receivedAt: Date = TrafficFixture.now,
    payloadType: PayloadType = .textMessage
  ) -> RxLogEntryDTO {
    let pathNodes = hops.flatMap(\.self)
    return RxLogEntryDTO(
      radioID: UUID(),
      receivedAt: receivedAt,
      from: ParsedRxLogData(
        snr: snr,
        rssi: nil,
        rawPayload: Data(),
        routeType: .flood,
        payloadType: payloadType,
        payloadVersion: 1,
        payloadTypeBits: 0,
        transportCode: nil,
        pathLength: encodePathLen(hashSize: hashSize, hopCount: hops.count),
        pathNodes: pathNodes,
        packetPayload: Data(pathNodes)
      )
    )
  }

  private struct TestNode: RepeaterResolvable {
    var publicKey: Data
    var latitude: Double
    var longitude: Double
    var hasLocation: Bool
    var lastAdvertTimestamp: UInt32
    var recencyDate: Date
    var resolvableName: String
    var expiresWhenStale: Bool
  }
}
