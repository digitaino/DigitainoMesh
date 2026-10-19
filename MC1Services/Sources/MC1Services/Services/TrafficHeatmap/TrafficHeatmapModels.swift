import CoreLocation
import Foundation

/// A point on the map a traffic aggregation placed something at.
///
/// Stored as two `Double`s rather than a `CLLocationCoordinate2D` so the aggregation's value
/// types get `Equatable`/`Hashable` for free and stay comparable in tests.
public struct TrafficCoordinate: Sendable, Hashable {
  public let latitude: Double
  public let longitude: Double

  public init(latitude: Double, longitude: Double) {
    self.latitude = latitude
    self.longitude = longitude
  }

  public init?(_ coordinate: CLLocationCoordinate2D) {
    guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
    self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
  }

  /// The located position of a node, or `nil` when it has none or its stored fix is invalid.
  public init?(node: some RepeaterResolvable) {
    guard node.hasLocation else { return nil }
    self.init(CLLocationCoordinate2D(latitude: node.latitude, longitude: node.longitude))
  }

  public var coordinate: CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  }

  /// Great-circle distance in metres.
  public func distance(to other: TrafficCoordinate) -> CLLocationDistance {
    CLLocation(latitude: latitude, longitude: longitude)
      .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
  }
}

/// One node's share of the traffic in an aggregation window.
public struct TrafficNodeLoad: Sendable, Hashable, Identifiable {
  /// The node's full public key — its identity here, since two nodes can share a hash.
  public let publicKey: Data
  public let name: String
  public let coordinate: TrafficCoordinate
  /// How many times this node appeared as a hop on a packet's path.
  public let packetCount: Int
  /// Mean SNR across the packets where this node was the **last** hop — the only ones our
  /// radio heard from it directly. `nil` when it was only ever an intermediate hop, or when
  /// those packets carried no SNR.
  public let averageSNR: Double?
  /// How many last-hop readings `averageSNR` averages.
  public let snrSampleCount: Int
  /// The most recent packet this node relayed.
  public let lastHeard: Date
  /// This node's traffic as a fraction of the busiest node's in the same snapshot (0...1).
  public let normalizedWeight: Double

  public var id: Data {
    publicKey
  }

  public init(
    publicKey: Data,
    name: String,
    coordinate: TrafficCoordinate,
    packetCount: Int,
    averageSNR: Double?,
    snrSampleCount: Int,
    lastHeard: Date,
    normalizedWeight: Double
  ) {
    self.publicKey = publicKey
    self.name = name
    self.coordinate = coordinate
    self.packetCount = packetCount
    self.averageSNR = averageSNR
    self.snrSampleCount = snrSampleCount
    self.lastHeard = lastHeard
    self.normalizedWeight = normalizedWeight
  }
}

/// A link between two nodes, weighted by how much traffic crossed it.
///
/// Undirected: a packet from A to B and one from B to A land on the same segment. Segments
/// carry no SNR — the radio only ever learns the quality of the final hop into itself, never
/// of a link between two remote repeaters.
public struct TrafficSegmentLoad: Sendable, Hashable, Identifiable {
  /// An endpoint of a segment: which node, and where it stands.
  public struct Endpoint: Sendable, Hashable {
    public let publicKey: Data
    public let name: String
    public let coordinate: TrafficCoordinate

    public init(publicKey: Data, name: String, coordinate: TrafficCoordinate) {
      self.publicKey = publicKey
      self.name = name
      self.coordinate = coordinate
    }
  }

  /// Stable across rebuilds: the two public keys in ascending order, so the same link keeps
  /// the same id whichever direction the next packet takes.
  public let id: String
  public let endpointA: Endpoint
  public let endpointB: Endpoint
  /// How many packets crossed this link in either direction.
  public let packetCount: Int
  /// This link's traffic as a fraction of the busiest link's in the same snapshot (0...1).
  public let normalizedWeight: Double

  public init(
    id: String,
    endpointA: Endpoint,
    endpointB: Endpoint,
    packetCount: Int,
    normalizedWeight: Double
  ) {
    self.id = id
    self.endpointA = endpointA
    self.endpointB = endpointB
    self.packetCount = packetCount
    self.normalizedWeight = normalizedWeight
  }
}

/// What one pass of ``TrafficHeatmapAggregator`` found: map-independent value types, ready to
/// be turned into whatever the renderer of the day wants.
public struct TrafficHeatmapSnapshot: Sendable, Hashable {
  /// Busiest first, then by public key so the order is total.
  public let nodes: [TrafficNodeLoad]
  /// Busiest first, then by id.
  public let segments: [TrafficSegmentLoad]
  /// Every entry inside the window, including ones that carried no usable path.
  public let analyzedEntryCount: Int
  /// Entries that contributed at least one placed hop.
  public let contributingEntryCount: Int
  /// Receive time of the oldest entry inside the window.
  public let oldestEntryDate: Date?

  public static let empty = TrafficHeatmapSnapshot(
    nodes: [],
    segments: [],
    analyzedEntryCount: 0,
    contributingEntryCount: 0,
    oldestEntryDate: nil
  )

  public var isEmpty: Bool {
    nodes.isEmpty && segments.isEmpty
  }

  public init(
    nodes: [TrafficNodeLoad],
    segments: [TrafficSegmentLoad],
    analyzedEntryCount: Int,
    contributingEntryCount: Int,
    oldestEntryDate: Date?
  ) {
    self.nodes = nodes
    self.segments = segments
    self.analyzedEntryCount = analyzedEntryCount
    self.contributingEntryCount = contributingEntryCount
    self.oldestEntryDate = oldestEntryDate
  }
}
