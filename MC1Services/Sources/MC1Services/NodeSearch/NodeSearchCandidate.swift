import Foundation

/// A saved contact or a passively discovered node, searchable as one pool.
///
/// ``AnyResolvableNode`` already type-erases the two for *resolution*, but resolution
/// only ever needs the winner's ranking fields. Search hands its results to a list, and a
/// list needs identity and the original record to build a row from — so this keeps the
/// concrete value rather than flattening it.
public enum NodeSearchCandidate: RepeaterResolvable, Sendable, Equatable, Identifiable {
  case contact(ContactDTO)
  case discovered(DiscoveredNodeDTO)

  public var id: UUID {
    switch self {
    case let .contact(contact): contact.id
    case let .discovered(node): node.id
    }
  }

  /// The saved contact, when this candidate is one.
  public var contact: ContactDTO? {
    guard case let .contact(contact) = self else { return nil }
    return contact
  }

  /// The discovered node, when this candidate is one.
  public var discoveredNode: DiscoveredNodeDTO? {
    guard case let .discovered(node) = self else { return nil }
    return node
  }

  // MARK: - RepeaterResolvable

  public var publicKey: Data {
    switch self {
    case let .contact(contact): contact.publicKey
    case let .discovered(node): node.publicKey
    }
  }

  public var latitude: Double {
    switch self {
    case let .contact(contact): contact.latitude
    case let .discovered(node): node.latitude
    }
  }

  public var longitude: Double {
    switch self {
    case let .contact(contact): contact.longitude
    case let .discovered(node): node.longitude
    }
  }

  public var hasLocation: Bool {
    switch self {
    case let .contact(contact): contact.hasLocation
    case let .discovered(node): node.hasLocation
    }
  }

  public var lastAdvertTimestamp: UInt32 {
    switch self {
    case let .contact(contact): contact.lastAdvertTimestamp
    case let .discovered(node): node.lastAdvertTimestamp
    }
  }

  public var recencyDate: Date {
    switch self {
    case let .contact(contact): contact.recencyDate
    case let .discovered(node): node.recencyDate
    }
  }

  public var resolvableName: String {
    switch self {
    case let .contact(contact): contact.resolvableName
    case let .discovered(node): node.resolvableName
    }
  }

  public var expiresWhenStale: Bool {
    switch self {
    case let .contact(contact): contact.expiresWhenStale
    case let .discovered(node): node.expiresWhenStale
    }
  }
}
