import Foundation
import MeshCore

/// A MeshWX weather bot as the app knows it from its advert (docs/MESHWX.md, spec §20): a
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

  /// A contact is a bot when its advertised name carries the prefix and a city after it, **and it
  /// advertised as a chat node** (``isChatAdvert(_:)``).
  ///
  /// Only a chat advert counts (phase 2, 18 October 2026): a repeater or a room server renamed
  /// WX-AUS is not a weather radio, and with any contact type counting, one rename was enough to
  /// put a second "WX-AUS" in the list.
  public init?(contact: ContactDTO) {
    guard Self.isBotName(contact.name), Self.isChatAdvert(contact) else { return nil }
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

  /// A bot known only from its own packets: every v5 message carries the first two bytes of the
  /// bot's public key (spec §2.2), and a Request datagram names the bot asked by those same two
  /// bytes (§11). So a bot that has been heard can be asked without ever having been seen to
  /// advertise. It has no name, no position and no full key, which is why the DM fallback — the
  /// one path that needs the key — stays closed to it (``isAnnounced``).
  ///
  /// Found the hard way on 2026-09-21: the owner's client sat for a night on a radio that was
  /// itself named WX-AUS, which can never hear "itself" announce, with every ask blocked.
  public static func heardOnly(botID: UInt16) -> WeatherBot {
    WeatherBot(
      publicKey: Data([UInt8(botID & 0xFF), UInt8(botID >> 8)]),
      name: "", latitude: 0, longitude: 0, lastAdvert: nil)
  }

  /// The `bot` field every v5 message carries: the first two bytes of the public key as a
  /// little-endian u16 (spec §2.2).
  public var botID: UInt16 { Self.botID(for: publicKey) }

  /// Whether a contact advertised as a chat node: what a weather bot runs as (spec §20).
  public static func isChatAdvert(_ contact: ContactDTO) -> Bool {
    contact.typeRawValue == ContactType.chat.rawValue
  }

  /// The four hex digits a bot is told apart by on screen, "1D04": the first two bytes of its
  /// public key **in key order**, the way every MeshCore app prints a key. The `bot` field is the
  /// same two bytes read little-endian (0x041D), which is why this is not `String(botID, radix:)`.
  public static func idText(_ botID: UInt16) -> String {
    String(format: "%02X%02X", botID & 0xFF, botID >> 8)
  }

  /// What ``conflicts(among:)`` found for one id: the label the screen says it by, and why.
  public struct Conflict: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
      /// Two adverts with one name and two different keys. `label` is the name.
      case name
      /// Two whole keys that begin with the same two bytes. `label` is the four hex digits.
      case id
    }

    public let botID: UInt16
    public let label: String
    public let kind: Kind

    public init(botID: UInt16, label: String, kind: Kind) {
      self.botID = botID
      self.label = label
      self.kind = kind
    }
  }

  /// The bot ids two radios answer to (phase 2, 18 October 2026): two adverts with one name, or
  /// two whole keys that share the two bytes the wire names a bot by (spec §2.2), whose messages
  /// cannot then be told apart at all. For a shared name both ids are listed: nothing on the wire
  /// says which WX-AUS is the city's.
  ///
  /// Until signing (wire revision 14) the bytes are self-asserted, so this is the one thing the
  /// app can see of a second radio speaking under a name: it chooses neither of them
  /// automatically and notifies nothing from them until the user has picked one.
  public static func conflicts(among bots: [WeatherBot]) -> [UInt16: Conflict] {
    var byName: [String: [Data: WeatherBot]] = [:]
    var byID: [UInt16: Set<Data>] = [:]
    var nameOrder: [String] = []
    for bot in bots where bot.isAnnounced {
      let name = bot.name.uppercased()
      if byName[name] == nil { nameOrder.append(name) }
      byName[name, default: [:]][bot.publicKey] = bot
      byID[bot.botID, default: []].insert(bot.publicKey)
    }
    var out: [UInt16: Conflict] = [:]
    for (botID, keys) in byID where keys.count >= 2 {
      out[botID] = Conflict(botID: botID, label: idText(botID), kind: .id)
    }
    for name in nameOrder {
      guard let keys = byName[name], keys.count >= 2 else { continue }
      for bot in keys.values.sorted(by: { $0.botID < $1.botID }) where out[bot.botID] == nil {
        out[bot.botID] = Conflict(botID: bot.botID, label: bot.name, kind: .name)
      }
    }
    return out
  }

  /// Whether the bot's whole key is known, from an advert or a link: what a DM needs.
  public var isAnnounced: Bool { publicKey.count == 32 }

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

  /// The bots among `contacts`, nearest to `location` first (spec §20: "show the nearest; let
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
