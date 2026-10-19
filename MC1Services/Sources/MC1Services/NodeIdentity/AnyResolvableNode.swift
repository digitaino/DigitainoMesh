import Foundation

/// Type-erased ``RepeaterResolvable`` so saved contacts and passively discovered nodes
/// can be ranked in a single pool.
public struct AnyResolvableNode: RepeaterResolvable, Sendable, Equatable {
  public let publicKey: Data
  public let latitude: Double
  public let longitude: Double
  public let hasLocation: Bool
  public let lastAdvertTimestamp: UInt32
  public let recencyDate: Date
  public let resolvableName: String
  public let expiresWhenStale: Bool

  public init(_ node: some RepeaterResolvable) {
    publicKey = node.publicKey
    latitude = node.latitude
    longitude = node.longitude
    hasLocation = node.hasLocation
    lastAdvertTimestamp = node.lastAdvertTimestamp
    recencyDate = node.recencyDate
    resolvableName = node.resolvableName
    expiresWhenStale = node.expiresWhenStale
  }
}
