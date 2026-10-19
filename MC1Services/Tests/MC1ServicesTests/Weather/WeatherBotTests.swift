import Foundation
@testable import MC1Services
import MeshCore
import Testing

@Suite("WeatherBot")
struct WeatherBotTests {
  private func contact(
    name: String,
    keyPrefix: [UInt8] = [0x7A, 0x4C],
    latitude: Double = 0,
    longitude: Double = 0,
    lastAdvert: UInt32 = 0
  ) -> ContactDTO {
    var key = Data(keyPrefix)
    key.append(Data(repeating: 0x11, count: 32 - keyPrefix.count))
    return ContactDTO.testContact(
      publicKey: key,
      name: name,
      lastAdvertTimestamp: lastAdvert,
      latitude: latitude,
      longitude: longitude
    )
  }

  /// The kit's vectors carry `bot = 19578` (0x4C7A) for a key starting `7A 4C`: little-endian.
  @Test
  func `the bot id is the first two key bytes little-endian`() throws {
    let bot = try #require(WeatherBot(contact: contact(name: "WX-AUS")))
    #expect(bot.botID == 19578)
    #expect(WeatherBot.botID(for: Data([0x01])) == 0)
    #expect(bot.city == "AUS")
  }

  @Test
  func `only WX- names with a city are bots`() {
    #expect(WeatherBot(contact: contact(name: "WX-AUS")) != nil)
    #expect(WeatherBot(contact: contact(name: "WX-")) == nil)
    #expect(WeatherBot(contact: contact(name: "wx-aus")) == nil)
    #expect(WeatherBot(contact: contact(name: "Rafael")) == nil)
    #expect(WeatherBot(contact: contact(name: "MyWX-Node")) == nil)
  }

  @Test
  func `an advert at 0,0 or never heard is reported as unknown`() throws {
    let unplaced = try #require(WeatherBot(contact: contact(name: "WX-NOWHERE")))
    #expect(!unplaced.hasLocation)
    #expect(unplaced.lastAdvert == nil)
    #expect(unplaced.distance(fromLatitude: 30, longitude: -97) == nil)

    let placed = try #require(WeatherBot(contact: contact(name: "WX-AUS", latitude: 30.27, longitude: -97.74, lastAdvert: 1_700_000_000)))
    #expect(placed.hasLocation)
    #expect(placed.lastAdvert == Date(timeIntervalSince1970: 1_700_000_000))
    let metres = try #require(placed.distance(fromLatitude: 30.27, longitude: -97.74))
    #expect(metres < 1)
  }

  @Test
  func `bots sort nearest first, then the unplaced ones by name`() {
    let contacts = [
      contact(name: "Rafael"),
      contact(name: "WX-SAT", keyPrefix: [0x01, 0x02], latitude: 29.42, longitude: -98.49),
      contact(name: "WX-ZED", keyPrefix: [0x03, 0x04]),
      contact(name: "WX-AUS", keyPrefix: [0x05, 0x06], latitude: 30.27, longitude: -97.74),
      contact(name: "WX-ALPHA", keyPrefix: [0x07, 0x08])
    ]
    let fromAustin = WeatherBot.bots(from: contacts, near: (latitude: 30.30, longitude: -97.70))
    #expect(fromAustin.map(\.name) == ["WX-AUS", "WX-SAT", "WX-ALPHA", "WX-ZED"])

    let fromSanAntonio = WeatherBot.bots(from: contacts, near: (latitude: 29.40, longitude: -98.50))
    #expect(fromSanAntonio.map(\.name) == ["WX-SAT", "WX-AUS", "WX-ALPHA", "WX-ZED"])

    let unlocated = WeatherBot.bots(from: contacts, near: nil)
    #expect(unlocated.map(\.name) == ["WX-ALPHA", "WX-AUS", "WX-SAT", "WX-ZED"])
  }
}
