import Foundation
@testable import MC1Services
import MeshWX
import Testing

/// The rules the place page is built from, as the owner's answers of 16 September stated them
/// (docs/MESHWX_UI.md §3.2): the pages and their order, when a reading is good enough to be the
/// weather here, which alert the banner names, when the radio row turns orange, and what a Places
/// row shows.
@Suite("Weather place page")
struct WeatherPlacePageTests {
  private typealias P = WeatherPhoneFixture

  private var now: Date { P.now }

  private func saved(_ label: String, lat: Double = 30.5083, lon: Double = -97.6789,
                     watched: Bool = false, minutesAgo: Double = 0) -> WeatherSavedPlace {
    WeatherSavedPlace(
      label: label, latitude: lat, longitude: lon,
      chosenAt: now.addingTimeInterval(-minutesAgo * 60), isWatched: watched)
  }

  // MARK: - The pager (answer 12)

  @Test
  func `my location is always the first page, and the saved places follow in Places' order`() {
    let places = [saved("Austin, TX", lat: 30.27, lon: -97.74), saved("Round Rock, TX"), saved("Llano, TX", lat: 30.75, lon: -98.67)]
    let pages = WeatherPages.make(saved: places)
    #expect(pages.count == 4)
    #expect(pages[0] == .myLocation)
    #expect(pages[0].id == "here")
    #expect(pages.dropFirst().compactMap(\.label) == ["Austin, TX", "Round Rock, TX", "Llano, TX"])
  }

  /// With no place saved and no permission there is still a page: it is the one that offers to
  /// ask for a fix, and nothing asks first.
  @Test
  func `with nothing saved there is still my location`() {
    #expect(WeatherPages.make(saved: []) == [.myLocation])
  }

  @Test
  func `a page whose place was removed leaves the pager on my location`() {
    let pages = WeatherPages.make(saved: [saved("Austin, TX", lat: 30.27, lon: -97.74)])
    let austin = pages[1].id
    #expect(WeatherPages.selection(austin, in: pages) == austin)
    #expect(WeatherPages.selection(austin, in: [.myLocation]) == "here")
    #expect(WeatherPages.selection("here", in: pages) == "here")
  }

  /// Reordering in Places is the pager's order, so the dots and the sheet never disagree.
  @Test
  func `dragging a place in Places moves its page`() {
    let list = [saved("A"), saved("B"), saved("C"), saved("D")]
    func labels(_ places: [WeatherSavedPlace]) -> [String] { places.map(\.label) }

    // Down: the first row lands before the row that was fourth.
    #expect(labels(WeatherSavedPlaces.moving(fromOffsets: [0], toOffset: 3, in: list)) == ["B", "C", "A", "D"])
    // Up: the third row lands at the front.
    #expect(labels(WeatherSavedPlaces.moving(fromOffsets: [2], toOffset: 0, in: list)) == ["C", "A", "B", "D"])
    // To the end.
    #expect(labels(WeatherSavedPlaces.moving(fromOffsets: [1], toOffset: 4, in: list)) == ["A", "C", "D", "B"])
    // Two rows at once keep their own order.
    #expect(labels(WeatherSavedPlaces.moving(fromOffsets: [0, 1], toOffset: 4, in: list)) == ["C", "D", "A", "B"])
    // A drag that changes nothing changes nothing.
    #expect(labels(WeatherSavedPlaces.moving(fromOffsets: [1], toOffset: 1, in: list)) == ["A", "B", "C", "D"])
    #expect(labels(WeatherSavedPlaces.moving(fromOffsets: [], toOffset: 2, in: list)) == ["A", "B", "C", "D"])
  }

  @Test
  func `a new place goes to the front and the rest keep the order they were dragged into`() {
    let dragged = WeatherSavedPlaces.moving(fromOffsets: [2], toOffset: 0, in: [saved("A"), saved("B"), saved("C")])
    let list = WeatherSavedPlaces.remember(saved("D", lat: 31, lon: -97), in: dragged)
    #expect(list.map(\.label) == ["D", "C", "A", "B"])
  }

  // MARK: - A good reading (answer 11)

  private func reading(kilometres: Double?, icao: String, minutesAgo: Double) -> WeatherStationReading {
    let station = MeshWXTables.shared.station(icao: icao)!
    let minutes = UInt32((now.timeIntervalSince1970 - minutesAgo * 60) / 60)
    let stored = WeatherStoredObservation(
      observation: MeshWXStationObservation(stationIndex: 0, tempF: 86, sky: .few),
      timestampMinutes: minutes, receivedAt: now.addingTimeInterval(-minutesAgo * 60))
    return WeatherStationReading(
      index: MeshWXTables.shared.stationIndex(forICAO: icao)!,
      station: station, stored: stored, botID: P.botID,
      distanceKilometres: kilometres, direction: nil,
      isStale: stored.isStale(at: now), isInFootprint: true, isInLatestBatch: true)
  }

  private let nearby = WeatherNearbyStation(icao: "KAQO", name: "Llano Municipal Airport", kilometres: 4)

  @Test
  func `a reading within the threshold and not stale is the weather here`() {
    let good = reading(kilometres: WeatherConditions.goodReadingKilometres - 1, icao: "KATT", minutesAgo: 20)
    #expect(WeatherConditions.make(primary: .reading(good), nearbyStation: nearby) == .reading(good))
    // The threshold itself is inside it.
    let edge = reading(kilometres: WeatherConditions.goodReadingKilometres, icao: "KATT", minutesAgo: 20)
    #expect(WeatherConditions.make(primary: .reading(edge), nearbyStation: nearby) == .reading(edge))
  }

  /// Beyond 40 km there is no temperature at all — only the ask, and it names the nearest station
  /// rather than the far one whose reading is held: asking that one again would not bring it
  /// closer, and the packet the plan sends goes to the near one.
  @Test
  func `a reading from too far away is no temperature, and the ask names the nearest station`() {
    let far = reading(kilometres: 60, icao: "KATT", minutesAgo: 20)
    #expect(WeatherConditions.make(primary: .reading(far), nearbyStation: nearby)
      == .ask(icao: "KAQO", kilometres: 4))
    // With no nearer station there is nothing worth a packet: its answer would come back from 60
    // km and the page would refuse it again. It says there is no station near enough instead.
    #expect(WeatherConditions.make(primary: .reading(far), nearbyStation: nil) == .noStation(nearest: far))
  }

  // MARK: - 25 to 40 km: shown under the station's name (§3.1 U-2a)

  /// Wimberley: San Marcos is 25.5 km off. Fresh, it is shown — attributed, never as the town's.
  @Test
  func `a fresh reading between 25 and 40 km is shown under its station`() {
    let off = reading(kilometres: 25.5, icao: "KHYI", minutesAgo: 20)
    let same = WeatherNearbyStation(icao: "KHYI", name: "San Marcos", kilometres: 25.5)
    #expect(WeatherConditions.make(primary: .reading(off), nearbyStation: same) == .nearby(off, nearer: nil))
    #expect(WeatherConditions.make(primary: .reading(off), nearbyStation: nil) == .nearby(off, nearer: nil))
    #expect(WeatherConditions.make(primary: .reading(off), nearbyStation: same).reading == off)
    // The edge is inside.
    let edge = reading(kilometres: WeatherConditions.labelledReadingKilometres, icao: "KHYI", minutesAgo: 20)
    #expect(WeatherConditions.make(primary: .reading(edge), nearbyStation: nil) == .nearby(edge, nearer: nil))
  }

  /// A nearer bundled station could be the weather here: the page keeps what it holds, and names
  /// the nearer one for Update to ask about.
  @Test
  func `an attributed reading carries a nearer station worth asking about`() {
    let off = reading(kilometres: 30, icao: "KATT", minutesAgo: 20)
    #expect(WeatherConditions.make(primary: .reading(off), nearbyStation: nearby) == .nearby(off, nearer: nearby))
    // A "nearer" one past 40 km could never be shown, so it is not worth a packet.
    let tooFar = WeatherNearbyStation(icao: "KAQO", name: "Llano", kilometres: 45)
    #expect(WeatherConditions.make(primary: .reading(off), nearbyStation: tooFar) == .nearby(off, nearer: nil))
  }

  /// Stale in the band: the station itself is asked about again, as it would be at 6 km.
  @Test
  func `a stale reading between 25 and 40 km asks about its own station`() {
    let stale = reading(kilometres: 30, icao: "KATT", minutesAgo: 8 * 60)
    #expect(WeatherConditions.make(primary: .reading(stale), nearbyStation: nil)
      == .ask(icao: "KATT", kilometres: 30))
  }

  /// Nothing held in reach and the nearest bundled station past 40 km: asking would bring back a
  /// reading the page will not show.
  @Test
  func `with nothing held and every station past 40 km there is nothing to ask`() {
    let far = reading(kilometres: 190, icao: "KTPL", minutesAgo: 20)
    let distant = WeatherNearbyStation(icao: "KAQO", name: "Llano", kilometres: 55)
    #expect(WeatherConditions.make(primary: .noneNearby(nearest: far), nearbyStation: distant)
      == .noStation(nearest: far))
  }

  /// Near enough but stale: that station is the right one to ask about again.
  @Test
  func `a stale reading near the place asks about its own station`() {
    let stale = reading(kilometres: 6, icao: "KATT", minutesAgo: 8 * 60)
    #expect(stale.isStale)
    #expect(WeatherConditions.make(primary: .reading(stale), nearbyStation: nearby)
      == .ask(icao: stale.station.icao, kilometres: 6))
  }

  @Test
  func `nothing in reach asks about the nearest bundled station, and nothing at all waits for the batch`() {
    let far = reading(kilometres: 190, icao: "KTPL", minutesAgo: 20)
    #expect(WeatherConditions.make(primary: .noneNearby(nearest: far), nearbyStation: nearby)
      == .ask(icao: "KAQO", kilometres: 4))
    #expect(WeatherConditions.make(primary: .noneNearby(nearest: far), nearbyStation: nil)
      == .noStation(nearest: far))
    // Nothing has ever arrived: the hourly batch fills this in, and one packet brings all of it.
    #expect(WeatherConditions.make(primary: .noObservations, nearbyStation: nearby) == .noneYet)
    #expect(WeatherConditions.make(primary: .noPlace, nearbyStation: nearby) == .noPlace)
  }

  // MARK: - The banner (answer 7)

  private func alert(event: UInt8, rank: Int, placement: WeatherAlertPlacement, etn: UInt16,
                     expiresInMinutes: Int, kind: WeatherAlertItem.Kind = .active) -> WeatherAlertItem {
    let expires = UInt32((now.timeIntervalSince1970 + Double(expiresInMinutes) * 60) / 60)
    let warning = MeshWXWarning(
      identity: MeshWXWarningIdentity(event: event, office: 35, etn: etn), expiresMinutes: expires)
    return WeatherAlertItem(
      identity: warning.identity, warning: warning, kind: kind, placement: placement,
      rank: rank, botIDs: [P.botID], receivedAt: now)
  }

  @Test
  func `only an alert covering the place earns the banner`() {
    let near = alert(event: 14, rank: 0, placement: .near(kilometres: 8, direction: .north), etn: 1, expiresInMinutes: 40)
    let checking = alert(event: 14, rank: 0, placement: .checking, etn: 2, expiresInMinutes: 40)
    let elsewhere = alert(event: 14, rank: 0, placement: .elsewhere, etn: 3, expiresInMinutes: 40)
    #expect(WeatherWarningBanner.make([near, checking, elsewhere]) == nil)
    #expect(WeatherWarningBanner.make([]) == nil)
  }

  @Test
  func `the banner names the most important one covering the place and counts the rest`() {
    let advisory = alert(event: 30, rank: 8, placement: .here, etn: 1, expiresInMinutes: 200)
    let tornado = alert(event: 14, rank: 0, placement: .here, etn: 2, expiresInMinutes: 40)
    let flood = alert(event: 4, rank: 4, placement: .here, etn: 3, expiresInMinutes: 90)
    let banner = WeatherWarningBanner.make([advisory, tornado, flood])
    #expect(banner?.item == tornado)
    #expect(banner?.more == 2)
  }

  /// A warning that has just expired is still worth a strip, but never over a live one.
  @Test
  func `a live alert leads a recently expired one, whatever their ranks`() {
    let expiredTornado = alert(
      event: 14, rank: 0, placement: .here, etn: 1, expiresInMinutes: -3, kind: .expiredRecently)
    let liveAdvisory = alert(event: 30, rank: 8, placement: .here, etn: 2, expiresInMinutes: 200)
    #expect(WeatherWarningBanner.make([expiredTornado, liveAdvisory])?.item == liveAdvisory)
    #expect(WeatherWarningBanner.make([expiredTornado])?.item == expiredTornado)
  }

  @Test
  func `equal ranks are led by the soonest expiry`() {
    let later = alert(event: 4, rank: 4, placement: .here, etn: 1, expiresInMinutes: 120)
    let sooner = alert(event: 4, rank: 4, placement: .here, etn: 2, expiresInMinutes: 30)
    #expect(WeatherWarningBanner.make([later, sooner])?.item == sooner)
  }

  // MARK: - The radio row (answer 10)

  private func source() -> WeatherScreenSnapshot.Source {
    WeatherScreenSnapshot.Source(
      botID: P.botID, bot: nil, lastHeardAt: now.addingTimeInterval(-120),
      lastLiveHeardAt: now.addingTimeInterval(-120))
  }

  private func state(listMinutesAgo: Double?) -> WeatherBotState {
    var state = WeatherBotState(botID: P.botID)
    guard let listMinutesAgo else { return state }
    let built = UInt32((now.timeIntervalSince1970 - listMinutesAgo * 60) / 60)
    state.digest = WeatherStoredDigest(
      digest: MeshWXDigest(nowMinutes: built, feedHealth: 0, entries: []),
      receivedAt: now.addingTimeInterval(-listMinutesAgo * 60))
    return state
  }

  @Test
  func `a fresh list heard recently is not orange`() {
    let row = WeatherRadioRow.make(source: source(), state: state(listMinutesAgo: 20), now: now)
    #expect(row.listIsOld == false)
    #expect(row.missedMessages == false)
    #expect(row.needsAttention == false)
    #expect(row.heardAt == now.addingTimeInterval(-120))
  }

  /// The two things the row is orange for, and the case the page would otherwise say nothing
  /// about at all: no list has ever arrived.
  @Test
  func `an old list, a missed message and no list at all are all orange`() {
    #expect(WeatherRadioRow.make(source: source(), state: state(listMinutesAgo: 200), now: now).needsAttention)
    #expect(WeatherRadioRow.make(source: source(), state: state(listMinutesAgo: nil), now: now).listIsOld)
    #expect(WeatherRadioRow.make(source: source(), state: state(listMinutesAgo: nil), now: now).needsAttention)
    #expect(WeatherRadioRow.make(source: source(), state: nil, now: now).needsAttention)

    var gap = state(listMinutesAgo: 20)
    gap.needsDigest = true
    let row = WeatherRadioRow.make(source: source(), state: gap, now: now)
    #expect(row.missedMessages)
    #expect(row.listIsOld == false)
    #expect(row.needsAttention)

    var missing = state(listMinutesAgo: 20)
    missing.missingFromDigest = [MeshWXWarningIdentity(event: 14, office: 35, etn: 3)]
    #expect(WeatherRadioRow.make(source: source(), state: missing, now: now).needsAttention)
  }

  /// The cadence is three hours; the row waits the quarter-hour of grace the status line waits.
  @Test
  func `the list goes old on the same cadence the alert status uses`() {
    let justInside = WeatherAlertStatus.listFreshFor / 60 - 1
    #expect(WeatherRadioRow.make(source: source(), state: state(listMinutesAgo: justInside), now: now).listIsOld == false)
    #expect(WeatherRadioRow.make(source: source(), state: state(listMinutesAgo: justInside + 2), now: now).listIsOld)
  }

  // MARK: - A Places row (answer 9)

  @Test
  func `a places row holds the nearest reading, its condition and whether it is stale`() {
    let readings = WeatherStations.readings(
      states: [P.botID: P.state()], coverage: WeatherCoverage(stations: []), place: nil,
      tables: .shared, now: now)
    let row = WeatherPlaceRowReading.make(readings: readings, at: P.austin, now: now)
    #expect(row.isEmpty == false)
    #expect(row.tempF != nil)
    #expect(row.sky == .few)
    #expect(row.isStale == false)
    #expect(row.observedAt != nil)
  }

  /// **One rule for the row and the page** (docs/MESHWX_UI.md §3.1 U-2). A stale reading is not
  /// the weather here, so the page shows no temperature for it — and the row that opens that page
  /// must not show one either. Places read "86° Partly cloudy · 3 h old" beside a page that said
  /// "No current conditions", one tap apart.
  @Test
  func `a stale reading is no good for the row, exactly as it is no good for the page`() {
    let readings = WeatherStations.readings(
      states: [P.botID: P.state(observationsAgo: 8 * 3600)], coverage: WeatherCoverage(stations: []),
      place: nil, tables: .shared, now: now)
    let row = WeatherPlaceRowReading.make(readings: readings, at: P.austin, now: now)
    #expect(row.isEmpty)
    #expect(row.tempF == nil)
  }

  /// The other half of the same contradiction: a reading inside the readings' own 80 km reach but
  /// beyond the page's 40 km is not the row's either.
  @Test
  func `a reading beyond the page's reach is no good for the row`() throws {
    let readings = WeatherStations.readings(
      states: [P.botID: P.state()], coverage: WeatherCoverage(stations: []), place: nil,
      tables: .shared, now: now)
    // A point between the page's 40 km and the readings' own 80 km reach: the band where the row
    // used to show a temperature the page refused to.
    let between = try #require(
      stride(from: 0.1, through: 1.5, by: 0.05).lazy.map { offset in
        MeshWXCoordinate(latitude: P.austin.latitude + offset, longitude: P.austin.longitude)
      }.first { coordinate in
        guard let near = WeatherStations.nearestReading(in: readings, to: coordinate) else { return false }
        return near.kilometres > WeatherConditions.labelledReadingKilometres
      },
      "the fixture should hold a reading between 40 km and 80 km of somewhere north of Austin")
    #expect(WeatherPlaceRowReading.make(readings: readings, at: between, now: now).isEmpty)
  }

  /// From 25 to 40 km the page shows the reading under its station, so the row does too — with the
  /// station's name, never as the town's own temperature.
  @Test
  func `a reading between 25 and 40 km is the row's, under its station`() throws {
    let readings = WeatherStations.readings(
      states: [P.botID: P.state()], coverage: WeatherCoverage(stations: []), place: nil,
      tables: .shared, now: now)
    let band = try #require(
      stride(from: 0.1, through: 1.5, by: 0.02).lazy.map { offset in
        MeshWXCoordinate(latitude: P.austin.latitude + offset, longitude: P.austin.longitude)
      }.first { coordinate in
        guard let near = WeatherStations.nearestReading(in: readings, to: coordinate) else { return false }
        return near.kilometres > WeatherConditions.goodReadingKilometres
          && near.kilometres <= WeatherConditions.labelledReadingKilometres
      },
      "the fixture should hold a reading between 25 km and 40 km of somewhere north of Austin")
    let row = WeatherPlaceRowReading.make(readings: readings, at: band, now: now)
    #expect(!row.isEmpty)
    #expect(row.tempF != nil)
    #expect(row.attributedStation?.isEmpty == false)
    // Within 25 km it is the town's own, with no station named.
    #expect(WeatherPlaceRowReading.make(readings: readings, at: P.austin, now: now).attributedStation == nil)
  }

  /// Nothing held in reach: the row says so rather than printing a bare degree sign.
  @Test
  func `a place with nothing in reach holds nothing`() {
    let readings = WeatherStations.readings(
      states: [P.botID: P.state()], coverage: WeatherCoverage(stations: []), place: nil,
      tables: .shared, now: now)
    let row = WeatherPlaceRowReading.make(readings: readings, at: P.dallas, now: now)
    #expect(row.isEmpty)
    #expect(row.tempF == nil)
    #expect(WeatherPlaceRowReading.make(readings: [], at: P.austin, now: now).isEmpty)
  }
}
