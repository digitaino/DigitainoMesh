import Foundation
@testable import MC1Services
import MeshWX
import Testing

/// The map, the selection, the cost and the parts offer: spec revision 10 (§1.1, §1.2) and
/// docs/MESHWX_UI.md §17.
@Suite("Weather alert map")
struct WeatherAlertMapTests {
  private typealias F = WeatherFixture
  private let states = MeshWXTables.shared.states

  /// Builds a bot's held sweeps by driving the reducer, so the picture is made of exactly what
  /// the wire would have left in state.
  private func held(_ packets: [MeshWXMessage]) -> [WeatherAreaSweepAssembly] {
    var state = WeatherBotState(botID: F.botID)
    for (step, packet) in packets.enumerated() {
      _ = WeatherStateReducer.apply(
        packet, to: &state, receivedAt: F.t0.addingTimeInterval(Double(step)))
    }
    return state.areaSweeps
  }

  @Test
  func `nothing held is an empty picture that speaks for no state`() {
    let picture = WeatherAlertMapPicture.make(sweeps: [], states: states, now: F.t0)
    #expect(picture.parts.isEmpty)
    #expect(picture.entries.isEmpty)
    #expect(!picture.coversWholeCountry)
    #expect(picture.nationalPart == nil)
  }

  /// One national sweep: "the rest of the country" is the whole of it, and its `stateCodes` are
  /// empty because it is not the newest word on a *list* of states — it is the newest word on
  /// everything nothing else claimed.
  @Test
  func `one national sweep covers the country and names no states`() {
    let picture = WeatherAlertMapPicture.make(
      sweeps: held([
        F.areaSweep(seq: 1, group: 1, index: 0, total: 1,
                    entries: [F.texasSweepEntry, F.montanaSweepEntry])
      ]),
      states: states, now: F.t0)
    #expect(picture.parts.count == 1)
    #expect(picture.coversWholeCountry)
    #expect(picture.parts[0].stateCodes.isEmpty)
    #expect(picture.parts[0].isWhole)
    #expect(picture.entries.map(\.entry) == [F.texasSweepEntry, F.montanaSweepEntry])
    #expect(picture.entries.map(\.part) == [0, 0])
    #expect(picture.entries.map(\.stateCode) == ["TX", "MT"])
  }

  /// **The rule.** For each state the newest sweep whose scope includes it wins, and only that
  /// sweep's entries for that state are drawn: Texas from the newer scoped sweep, everything else
  /// from the older national one. Merging them would draw this hour's tornado warning beside last
  /// hour's expired one.
  @Test
  func `the newest sweep covering a state wins it, and only its entries are drawn`() {
    let oldTexas = MeshWXAreaSweep.Entry(event: 1, stateIndex: F.texasState, isCounty: true, start: 453, run: 1)
    let picture = WeatherAlertMapPicture.make(
      sweeps: held([
        F.areaSweep(seq: 1, group: 1, index: 0, total: 1,
                    entries: [oldTexas, F.montanaSweepEntry]),
        F.areaSweep(
          seq: 2, builtMinutes: F.t0Minutes + 20, group: 2, index: 0, total: 1,
          entries: [F.texasSweepEntry], scope: [F.texasState])
      ]),
      states: states, now: F.t0)

    #expect(picture.parts.map(\.group) == [2, 1], "newest first")
    #expect(picture.parts[0].stateCodes == ["TX"])
    #expect(picture.parts[1].stateCodes.isEmpty, "the rest of the country")
    #expect(picture.coversWholeCountry)
    // Texas from the scoped sweep, Montana from the national one, and the old Texas entry gone.
    #expect(picture.entries.map(\.entry) == [F.texasSweepEntry, F.montanaSweepEntry])
    #expect(picture.entries.map(\.part) == [0, 1])
  }

  /// A scoped sweep whose packet 0 never arrived cannot say which states it was asked for, so it
  /// wins none — but a shaded area is evidence whatever the phone knows about the question, so
  /// its entries are still drawn.
  @Test
  func `a scoped sweep with no scope contributes entries and wins no state`() {
    let picture = WeatherAlertMapPicture.make(
      sweeps: held([
        F.areaSweep(seq: 1, group: 1, index: 0, total: 1, entries: [F.montanaSweepEntry]),
        F.areaSweep(
          seq: 2, builtMinutes: F.t0Minutes + 20, group: 2, index: 1, total: 2,
          entries: [F.texasSweepEntry], isScoped: true)
      ]),
      states: states, now: F.t0)
    #expect(picture.parts[0].scope == nil)
    #expect(picture.parts[0].stateCodes.isEmpty)
    #expect(picture.parts[0].missingIndexes == [0])
    #expect(picture.parts[0].receivedPackets == 1)
    #expect(picture.parts[0].totalPackets == 2)
    #expect(!picture.parts[0].isWhole)
    #expect(picture.entries.map(\.entry) == [F.texasSweepEntry, F.montanaSweepEntry])
    #expect(picture.entries.map(\.part) == [0, 1])
  }

  /// With nothing national held the map covers what its scopes name and nothing else: an
  /// unshaded state outside them is **unknown**, never clear, which is what the card has to say.
  @Test
  func `scoped sweeps alone do not cover the country`() {
    let picture = WeatherAlertMapPicture.make(
      sweeps: held([
        F.areaSweep(seq: 1, group: 1, index: 0, total: 1,
                    entries: [F.texasSweepEntry], scope: [F.texasState]),
        F.areaSweep(
          seq: 2, builtMinutes: F.t0Minutes + 5, group: 2, index: 0, total: 1,
          entries: [F.montanaSweepEntry], scope: [F.montanaState])
      ]),
      states: states, now: F.t0)
    #expect(!picture.coversWholeCountry)
    #expect(picture.nationalPart == nil)
    #expect(Set(picture.parts.flatMap(\.stateCodes)) == ["TX", "MT"])
  }

  /// The card's "4 of 7 parts arrived" and its cut line read off the part.
  @Test
  func `a part carries its packet count, its holes and its cut mark`() {
    let picture = WeatherAlertMapPicture.make(
      sweeps: held([
        F.areaSweep(seq: 1, group: 1, index: 0, total: 3, entries: [F.texasSweepEntry], wasCut: true),
        F.areaSweep(seq: 2, group: 1, index: 2, total: 3, entries: [F.montanaSweepEntry])
      ]),
      states: states, now: F.t0)
    let part = picture.parts[0]
    #expect(part.receivedPackets == 2)
    #expect(part.totalPackets == 3)
    #expect(part.missingIndexes == [1])
    #expect(part.wasCut, "set on every packet of a cut sweep, so one packet saying so is enough")
    #expect(!part.isWhole)
    #expect(part.firstReceivedAt == F.t0)
    #expect(part.lastReceivedAt == F.t0.addingTimeInterval(1))
    #expect(picture.incompleteParts.map(\.group) == [1])
  }
}

/// Spec revision 10, §1.1: offered, never automatic, and only inside the window in which the bot
/// still holds the bytes.
@Suite("Weather parts offer")
struct WeatherPartsOfferTests {
  private typealias F = WeatherFixture

  private func sweep(
    missing: [UInt8], total: UInt8 = 3, firstAt: TimeInterval = 0, lastAt: TimeInterval = 0
  ) -> WeatherAreaSweepAssembly {
    var packets: [UInt8: [MeshWXAreaSweep.Entry]] = [:]
    for index in 0..<total where !missing.contains(index) {
      packets[index] = [F.texasSweepEntry]
    }
    return WeatherAreaSweepAssembly(
      builtMinutes: F.t0Minutes, group: 212, total: total, packets: packets,
      firstReceivedAt: F.t0.addingTimeInterval(firstAt),
      lastReceivedAt: F.t0.addingTimeInterval(lastAt))
  }

  @Test
  func `an incomplete sweep past the settle window is offered as a parts request`() {
    let offer = WeatherPartsOffer.make(
      assembly: sweep(missing: [1, 2]), now: F.t0.addingTimeInterval(20))
    #expect(offer == .parts(group: 212, indexes: [1, 2], of: .areaSweep))
    #expect(offer?.wireText == ">part 212 1,2")
  }

  /// Nothing to ask for when nothing is missing.
  @Test
  func `a complete sweep is never offered`() {
    #expect(WeatherPartsOffer.make(
      assembly: sweep(missing: []), now: F.t0.addingTimeInterval(60)) == nil)
  }

  /// The bot resends a packet nothing echoed, 8–10 s later, of its own accord (spec §2.3).
  /// Offering inside that window asks for a packet that is already on the air.
  @Test
  func `nothing is offered until the bot's own resend has had its chance`() {
    #expect(WeatherPartsOffer.make(
      assembly: sweep(missing: [1]), now: F.t0.addingTimeInterval(14)) == nil)
    #expect(WeatherPartsOffer.make(
      assembly: sweep(missing: [1]), now: F.t0.addingTimeInterval(15)) != nil)
    #expect(WeatherPartsOffer.settleSeconds == 15)
  }

  /// Past `PARTS_CACHE_S` the bot no longer holds the bytes, so the ask can only come back Not
  /// available and the ordinary request is the only honest offer.
  @Test
  func `nothing is offered once the bot has dropped the bytes`() {
    #expect(WeatherPartsOffer.window == 600)
    #expect(WeatherPartsOffer.window == TimeInterval(MeshWXWire.partsCacheSeconds))
    #expect(WeatherPartsOffer.make(
      assembly: sweep(missing: [1]), now: F.t0.addingTimeInterval(600)) != nil)
    #expect(WeatherPartsOffer.make(
      assembly: sweep(missing: [1]), now: F.t0.addingTimeInterval(601)) == nil)
  }

  /// The same rule and the same wire request for a text reply with a hole in it (spec §8.1): the
  /// kind comes off the assembly's own subject, for the log's wording.
  @Test
  func `a text reply missing a chunk is offered the same way`() {
    let assembly = WeatherTextAssembly(
      subject: .stormReports, group: 23, total: 3, chunks: [0: "a", 2: "c"],
      firstReceivedAt: F.t0, lastReceivedAt: F.t0)
    let offer = WeatherPartsOffer.make(assembly: assembly, now: F.t0.addingTimeInterval(30))
    #expect(offer == .parts(group: 23, indexes: [1], of: .text(subject: 3)))
    #expect(offer?.wireText == ">part 23 1")
  }

  /// `total` is a byte off the wire. Both answer kinds cap at eight packets, so every index is
  /// one digit and all of them always fit — the trim exists so a bot with a bug cannot build a
  /// request the radio refuses.
  @Test
  func `the indexes are trimmed to what a forty-byte request text holds`() {
    let indexes = WeatherPartsOffer.fitting(
      group: 255, indexes: Array<UInt8>(0..<200), kind: .areaSweep)
    let text = WeatherRequest.parts(group: 255, indexes: indexes, of: .areaSweep).wireText
    #expect(text.utf8.count <= MeshWXWire.maxRequestTextBytes)
    #expect(indexes.count < 200)
    #expect(indexes.first == 0, "lowest first: the holes nearest the start of the answer")
    // The realistic case: eight packets, every index one digit, nothing trimmed.
    #expect(WeatherPartsOffer.fitting(group: 212, indexes: [0, 1, 2, 3, 4, 5, 6, 7], kind: .areaSweep)
      == [0, 1, 2, 3, 4, 5, 6, 7])
  }
}

/// Which areas to ask about, and what the tap costs (docs/MESHWX_UI.md §17).
@Suite("Weather area selection and cost")
struct WeatherAreaSelectionTests {
  private typealias F = WeatherFixture
  private let states = MeshWXTables.shared.states

  private func defaults() -> UserDefaults {
    let defaults = UserDefaults(suiteName: "weather-area-\(UUID().uuidString)")!
    return defaults
  }

  /// The owner's ask: *one, a few, or all. That way we don't default to sending everything.*
  @Test
  func `the default is the page's own state, or the country with no place`() {
    #expect(WeatherAreaSelection.default(placeState: "TX")
      == WeatherAreaSelection(isWholeCountry: false, states: ["TX"]))
    #expect(WeatherAreaSelection.default(placeState: nil) == .wholeCountry)
    #expect(WeatherAreaSelection.default(placeState: "") == .wholeCountry)
  }

  @Test
  func `a selection renders the request its button sends`() {
    #expect(WeatherAreaSelection(isWholeCountry: false, states: ["tx", "ok"]).request(includesAdvisories: false)
      == .areaSweep(includesAdvisories: false, states: ["OK", "TX"]))
    #expect(WeatherAreaSelection.wholeCountry.request(includesAdvisories: true)
      == .areaSweep(includesAdvisories: true, states: []))
    // An empty list is the country too: there is nothing else it could ask for.
    #expect(WeatherAreaSelection(isWholeCountry: false, states: []).asksWholeCountry)
  }

  /// More than fifteen states cannot be named in a forty-byte request, so the ask becomes the
  /// whole country — and the screen says so **before** the tap, not after it.
  @Test
  func `more than fifteen states asks for the whole country`() {
    let sixteen = (0..<16).map { states[$0] }
    let selection = WeatherAreaSelection(isWholeCountry: false, states: sixteen)
    #expect(selection.asksWholeCountry)
    #expect(selection.askedStates.isEmpty)
    #expect(selection.request(includesAdvisories: false).wireText == ">wmap")

    let fifteen = WeatherAreaSelection(isWholeCountry: false, states: Array(sixteen.prefix(15)))
    #expect(!fifteen.asksWholeCountry)
    #expect(fifteen.request(includesAdvisories: false).wireText.utf8.count <= MeshWXWire.maxRequestTextBytes)
  }

  @Test
  func `the selection persists per device and falls back to the page's state`() {
    let defaults = defaults()
    let store = WeatherAreaSelectionStore(defaults: defaults)
    #expect(store.selection == nil, "nothing chosen is not the same as the whole country")
    #expect(store.selection(placeState: "TX") == WeatherAreaSelection(isWholeCountry: false, states: ["TX"]))

    store.selection = WeatherAreaSelection(isWholeCountry: false, states: ["OK", "TX"])
    #expect(WeatherAreaSelectionStore(defaults: defaults).selection(placeState: "MT")
      == WeatherAreaSelection(isWholeCountry: false, states: ["OK", "TX"]))
    store.selection = nil
    #expect(store.selection == nil)
  }

  // MARK: - Cost

  private func picture(_ packets: [MeshWXMessage]) -> WeatherAlertMapPicture {
    var state = WeatherBotState(botID: F.botID)
    for (step, packet) in packets.enumerated() {
      _ = WeatherStateReducer.apply(packet, to: &state, receivedAt: F.t0.addingTimeInterval(Double(step)))
    }
    return WeatherAlertMapPicture.make(sweeps: state.areaSweeps, states: states, now: F.t0)
  }

  /// Nothing held: the last national sweep's own count is the best estimate there is, and
  /// without one the figures measured against the bot's live products on 2026-09-20.
  @Test
  func `the national cost is the last national sweep's count, else four and seven`() {
    #expect(WeatherAreaSweepCost.packets(
      for: .wholeCountry, advisories: false, held: .empty) == 4)
    #expect(WeatherAreaSweepCost.packets(
      for: .wholeCountry, advisories: true, held: .empty) == 7)

    let held = picture([
      F.areaSweep(seq: 1, group: 1, index: 0, total: 6, entries: [F.texasSweepEntry])
    ])
    #expect(WeatherAreaSweepCost.packets(for: .wholeCountry, advisories: false, held: held) == 6)
  }

  /// With no sweep of the country to count against, one packet per four states, at least one.
  @Test
  func `without a national sweep a scoped ask is one packet per four states`() {
    func cost(_ codes: [String]) -> Int {
      WeatherAreaSweepCost.packets(
        for: WeatherAreaSelection(isWholeCountry: false, states: codes),
        advisories: false, held: .empty)
    }
    #expect(cost(["TX"]) == 1)
    #expect(cost(["TX", "OK", "MT", "NE"]) == 1)
    #expect(cost(["TX", "OK", "MT", "NE", "KS"]) == 2)
  }

  /// With a sweep of the country held, the runs in those states plus one scope entry per state,
  /// over the thirty-eight an entry list holds — the scope rides in the entry list and spends the
  /// same budget the areas do.
  @Test
  func `a scoped ask counts the runs the map holds in those states`() {
    let texas = (0..<40).map {
      MeshWXAreaSweep.Entry(event: 3, stateIndex: F.texasState, isCounty: false, start: UInt16($0), run: 1)
    }
    let held = picture([
      F.areaSweep(seq: 1, group: 1, index: 0, total: 2, entries: Array(texas.prefix(38))),
      F.areaSweep(seq: 2, group: 1, index: 1, total: 2, entries: Array(texas.suffix(2)) + [F.montanaSweepEntry])
    ])
    // 40 Texas runs and one state: ceil(41 / 38) = 2.
    #expect(WeatherAreaSweepCost.packets(
      for: WeatherAreaSelection(isWholeCountry: false, states: ["TX"]),
      advisories: false, held: held) == 2)
    // Montana alone is one run and one state.
    #expect(WeatherAreaSweepCost.packets(
      for: WeatherAreaSelection(isWholeCountry: false, states: ["MT"]),
      advisories: false, held: held) == 1)
    // A state with nothing active still costs its scope entry, so never less than one packet.
    #expect(WeatherAreaSweepCost.packets(
      for: WeatherAreaSelection(isWholeCountry: false, states: ["NE"]),
      advisories: false, held: held) == 1)
  }
}
