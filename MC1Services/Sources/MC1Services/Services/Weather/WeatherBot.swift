import Foundation
import MeshCore

/// A MeshWX weather bot as the app knows it from its advert (docs/MESHWX.md, spec §12): a
/// chat node named `WX-<city>` whose position rides in the advert.
///
/// There is no discovery channel in v5. Every MeshCore app already collects adverts into
/// contacts, so "the bots I can hear" is a filter over the contact list, and the bot a
/// message came from is the first two bytes of that contact's public key.
public struct WeatherBot: Sendable, Hashable, Identifiable {
  /// Advert name prefix that marks a weather bot.
  public static let namePrefix = "WX-"

  public let publicKey: Data
  /// The advertised name, e.g. `WX-AUS`.
  public let name: String
  public let latitude: Double
  public let longitude: Double
  /// When the radio last heard this bot's advert, if it ever did.
  public let lastAdvert: Date?

  public var id: Data { publicKey }

  public init(publicKey: Data, name: String, latitude: Double, longitude: Double, lastAdvert: Date?) {
    self.publicKey = publicKey
    self.name = name
    self.latitude = latitude
    self.longitude = longitude
    self.lastAdvert = lastAdvert
  }

  /// A contact is a bot when its advertised name carries the prefix and a city after it.
  public init?(contact: ContactDTO) {
    guard Self.isBotName(contact.name) else { return nil }
    self.init(
      publicKey: contact.publicKey,
      name: contact.name,
      latitude: contact.latitude,
      longitude: contact.longitude,
      lastAdvert: contact.lastAdvertTimestamp == 0
        ? nil
        : Date(timeIntervalSince1970: TimeInterval(contact.lastAdvertTimestamp))
    )
  }

  /// The `bot` field every v5 message carries: the first two bytes of the public key as a
  /// little-endian u16 (spec §2.2).
  public var botID: UInt16 { Self.botID(for: publicKey) }

  /// The `WX-` prefix stripped: `AUS` for `WX-AUS`.
  public var city: String { String(name.dropFirst(Self.namePrefix.count)) }

  /// An advert with no position reports 0,0; treat that as unknown rather than the Gulf of
  /// Guinea.
  public var hasLocation: Bool { latitude != 0 || longitude != 0 }

  public static func isBotName(_ name: String) -> Bool {
    name.hasPrefix(namePrefix) && name.count > namePrefix.count
  }

  public static func botID(for publicKey: Data) -> UInt16 {
    guard publicKey.count >= 2 else { return 0 }
    let bytes = [UInt8](publicKey.prefix(2))
    return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
  }

  /// Great-circle distance in metres to a point, or nil when the bot has no position.
  public func distance(fromLatitude latitude: Double, longitude: Double) -> Double? {
    guard hasLocation else { return nil }
    return Self.haversineMetres(
      lat1: latitude, lon1: longitude, lat2: self.latitude, lon2: self.longitude
    )
  }

  /// The bots among `contacts`, nearest to `location` first (spec §12: "show the nearest; let
  /// the user pick"). Bots without a position sort after every located one, alphabetically;
  /// with no reference location the whole list is alphabetical so the order is at least stable.
  public static func bots(
    from contacts: [ContactDTO],
    near location: (latitude: Double, longitude: Double)?
  ) -> [WeatherBot] {
    let bots = contacts.compactMap(WeatherBot.init(contact:))
    return bots.sorted { lhs, rhs in
      let lhsDistance = location.flatMap { lhs.distance(fromLatitude: $0.latitude, longitude: $0.longitude) }
      let rhsDistance = location.flatMap { rhs.distance(fromLatitude: $0.latitude, longitude: $0.longitude) }
      switch (lhsDistance, rhsDistance) {
      case let (l?, r?) where l != r: return l < r
      case (.some, .none): return true
      case (.none, .some): return false
      default: return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
      }
    }
  }

  static func haversineMetres(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
    let earthRadius = 6_371_000.0
    let dLat = (lat2 - lat1) * .pi / 180
    let dLon = (lon2 - lon1) * .pi / 180
    let a = sin(dLat / 2) * sin(dLat / 2)
      + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
    return 2 * earthRadius * atan2(sqrt(a), sqrt(1 - a))
  }
}
