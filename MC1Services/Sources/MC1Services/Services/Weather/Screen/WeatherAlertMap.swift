import Foundation
import MeshWX

// MARK: - The map

/// Every sweep the phone holds, resolved into one map (docs/MESHWX_UI.md §17, spec revision 10).
///
/// Before revision 10 there was one sweep and the map was it. Now a phone can hold a national
/// sweep from 13:20 and a two-state sweep from 13:40, and the map is both: Texas and Oklahoma
/// from the newer one, the rest of the country from the older. The owner asked for the scope
/// ("have a way for the user to select which areas they want to request the warnings for. One, a
/// few, or all") and this is the other half of it — the screen has to be able to say *which part
/// of what you are looking at came from where*, because the two halves have different ages, may
/// have different breadths, and may be cut in different places.
///
/// One rule decides everything: **for each state, the newest sweep whose scope includes it wins,
/// and only that sweep's entries for that state are drawn.** Merging two sweeps' entries for one
/// state would draw this hour's tornado warning beside last hour's expired one, which is the
/// output a map must never produce.
///
/// The one exception is a scoped sweep whose scope has not arrived (packet 0 missing): it wins no
/// state, because it cannot say which ones it was asked for, but its entries are still drawn. An
/// area it names is under an alert whatever the phone knows about the question — a shaded area is
/// evidence and an unshaded one never is.
public struct WeatherAlertMapPicture: Sendable, Hashable {
  /// One sweep the map is built out of, and what it is the newest word on.
  public struct Part: Sendable, Hashable, Identifiable {
    /// Its position in ``WeatherAlertMapPicture/parts``, which is what
    /// ``WeatherAlertMapPicture/Entry/part`` refers to.
    public var id: Int
    public var group: UInt8
    /// On the bot's clock (spec §7C). The age on screen is measured from this and never from
    /// receipt: a sweep drained from the radio's queue an hour late is an hour old.
    public var builtAt: Date
    public var includesAdvisories: Bool
    /// Entries were dropped to fit. An area not shaded from this part may still be under an
    /// alert, and the screen says so in its own orange line.
    public var wasCut: Bool
    public var isScoped: Bool
    /// The state indices the sweep says it covers: `[]` national, the indices when scoped and
    /// the packet carrying them arrived, nil when scoped and it has not.
    public var scope: [UInt8]?
    /// The states this part is the newest word on, as two-letter codes, sorted.
    ///
    /// **Empty means "the rest of the country"** for a national part: everything no newer scoped
    /// part claimed. Empty on a *scoped* part means it won nothing — every state it named has a
    /// newer sweep, or its own scope never arrived — and the screen names it by its entries
    /// rather than by its states.
    public var stateCodes: [String]
    public var receivedPackets: Int
    public var totalPackets: Int
    /// The packets that never arrived, ascending. What ``WeatherPartsOffer`` asks for, and what
    /// "4 of 7 parts arrived" counts.
    public var missingIndexes: [UInt8]
    public var firstReceivedAt: Date
    public var lastReceivedAt: Date

    /// Nothing is missing and the sweep was not cut: the only case in which an unshaded area
    /// inside this part's states is genuinely clear.
    public var isWhole: Bool { missingIndexes.isEmpty && !wasCut && totalPackets > 0 }
  }

  /// One alert run the map draws, and which part it came from.
  public struct Entry: Sendable, Hashable {
    public var entry: MeshWXAreaSweep.Entry
    /// The index into ``WeatherAlertMapPicture/parts``, so every shaded area can say how old it
    /// is and which ask it came from.
    public var part: Int
    /// The two-letter code of the run's state, resolved once here so nothing downstream needs
    /// the table again. Nil for a state index this bundle has no code for — an older bundle
    /// reading a newer bot's sweep, which loses the *name* and never the run.
    public var stateCode: String?
  }

  /// Newest first. The status card lists one line per part.
  public var parts: [Part]
  /// In part order, then in the order each bot sent them — most severe first (spec §7C), which
  /// is also the order the map lays its tints down in.
  public var entries: [Entry]
  /// A national sweep is held, so the map speaks for the whole country. False means an unshaded
  /// state outside every part's scope is **unknown**, never clear, and the screen has to say so.
  public var coversWholeCountry: Bool
  /// When the picture was built, so every age on the card is measured from one instant rather
  /// than from a clock read per row.
  public var now: Date

  public static let empty = WeatherAlertMapPicture(
    parts: [], entries: [], coversWholeCountry: false, now: .distantPast)

  public init(parts: [Part], entries: [Entry], coversWholeCountry: Bool, now: Date) {
    self.parts = parts
    self.entries = entries
    self.coversWholeCountry = coversWholeCountry
    self.now = now
  }

  /// - Parameters:
  ///   - sweeps: what one bot sent (`WeatherBotState.areaSweeps`). Sorted here rather than taken
  ///     on trust, so a picture is the same whatever order a caller hands them over in.
  ///   - states: `index.json` `states`, for turning the scope's indices into codes. A state index
  ///     this bundle has no code for still wins its states and still draws its entries; it just
  ///     goes unnamed, the way every other table miss in this app does.
  public static func make(
    sweeps: [WeatherAreaSweepAssembly], states: [String], now: Date
  ) -> WeatherAlertMapPicture {
    let ordered = sweeps.sorted(by: WeatherStateReducer.isNewer)
    guard !ordered.isEmpty else {
      return WeatherAlertMapPicture(parts: [], entries: [], coversWholeCountry: false, now: now)
    }
    func code(_ stateIndex: UInt8) -> String? {
      Int(stateIndex) < states.count ? states[Int(stateIndex)] : nil
    }

    // The winner per state, newest first: the first sweep in the list that covers a state is by
    // definition the newest that does.
    var wonStates: [Int: Set<UInt8>] = [:]
    var claimed: Set<UInt8> = []
    var nationalPart: Int?
    for (index, sweep) in ordered.enumerated() {
      guard sweep.isScoped else {
        // A national sweep wins every state nothing newer has claimed. It is not enumerated
        // state by state: "the rest of the country" is what the card calls it, and the set of
        // states in the bundle is not the set of states on the wire.
        if nationalPart == nil { nationalPart = index }
        continue
      }
      // A scope that never arrived claims nothing (its entries are still drawn below).
      guard let scope = sweep.scope else { continue }
      let won = Set(scope).subtracting(claimed)
      claimed.formUnion(won)
      wonStates[index] = won
    }

    var parts: [Part] = []
    var entries: [Entry] = []
    for (index, sweep) in ordered.enumerated() {
      let won = wonStates[index] ?? []
      parts.append(Part(
        id: index,
        group: sweep.group,
        builtAt: sweep.builtAt,
        includesAdvisories: sweep.includesAdvisories,
        wasCut: sweep.wasCut,
        isScoped: sweep.isScoped,
        scope: sweep.scope,
        stateCodes: won.compactMap(code).sorted(),
        receivedPackets: sweep.receivedPacketCount,
        totalPackets: Int(sweep.total),
        missingIndexes: sweep.missingIndexes,
        firstReceivedAt: sweep.firstReceivedAt,
        lastReceivedAt: sweep.lastReceivedAt))

      // A national part draws every state no newer scoped part won; a scoped part draws the
      // states it won; a scoped part with no scope draws everything it named, having won none.
      let drawsEverythingUnclaimed = !sweep.isScoped && index == nationalPart
      let drawsEverything = sweep.isScoped && sweep.scope == nil
      for entry in sweep.entries {
        let draws = drawsEverything
          || won.contains(entry.stateIndex)
          || (drawsEverythingUnclaimed && !claimed.contains(entry.stateIndex))
        if draws {
          entries.append(Entry(entry: entry, part: index, stateCode: code(entry.stateIndex)))
        }
      }
    }

    return WeatherAlertMapPicture(
      parts: parts,
      entries: entries,
      // A national sweep is the only thing that can speak for a state nobody asked about.
      coversWholeCountry: nationalPart != nil,
      now: now)
  }

  /// The newest part that is the whole country, if one is held: what the cost estimate is read
  /// from, and what "the rest of the country · as of 13:20" names.
  public var nationalPart: Part? { parts.first { !$0.isScoped } }

  /// Every part with a packet missing, newest first — the ones a parts offer applies to.
  public var incompleteParts: [Part] { parts.filter { !$0.missingIndexes.isEmpty } }
}

// MARK: - Which areas to ask about

/// What the next map should cover (docs/MESHWX_UI.md §17, spec revision 10, §1.2).
///
/// The owner's third ask, in his words: *can we go from national alert map to just alert map, and
/// have a way for the user to select which areas they want to request the warnings for. One, a
/// few, or all. That way we don't default to sending everything.*
///
/// Two fields rather than one, because "the whole country" is a choice and not fifty-odd states:
/// a selection of every state in the picker is still a scoped request, and it would not fit in a
/// forty-byte request text.
public struct WeatherAreaSelection: Sendable, Hashable, Codable {
  public var isWholeCountry: Bool
  /// Two-letter codes, sorted and upper case (``WeatherRequest/sweepStates(_:)``). Ignored while
  /// ``isWholeCountry`` is set, and kept rather than cleared, so turning the whole country off
  /// again brings back what was picked before it.
  public var states: [String]

  public init(isWholeCountry: Bool = true, states: [String] = []) {
    self.isWholeCountry = isWholeCountry
    self.states = WeatherRequest.sweepStates(states)
  }

  /// The whole country, which is what a page with no place defaults to.
  public static let wholeCountry = WeatherAreaSelection(isWholeCountry: true)

  /// The selection a page starts from before anyone has chosen: the state of the page's place,
  /// or the whole country when the page has none (docs/MESHWX_UI.md §17).
  ///
  /// One state, not the region around it: a person opening the map from their own town wants
  /// their own state, and one state is one packet rather than eight.
  public static func `default`(placeState: String?) -> WeatherAreaSelection {
    guard let placeState, !placeState.isEmpty else { return .wholeCountry }
    return WeatherAreaSelection(isWholeCountry: false, states: [placeState])
  }

  /// Whether this selection goes out as the whole country after all: more than
  /// ``MeshWXWire/maxSweepScopeStates`` states cannot be named in a forty-byte request, and
  /// fifteen states is most of a sweep's airtime anyway. The screen says so **before** the tap,
  /// not after it — a person who picked twenty states and got the country is owed the sentence
  /// in advance.
  public var asksWholeCountry: Bool {
    isWholeCountry || states.isEmpty || states.count > MeshWXWire.maxSweepScopeStates
  }

  /// The states the request will actually name: empty when it asks for the whole country.
  public var askedStates: [String] {
    asksWholeCountry ? [] : states
  }

  public func request(includesAdvisories: Bool) -> WeatherRequest {
    .areaSweep(includesAdvisories: includesAdvisories, states: askedStates)
  }
}

/// The selection, kept on this phone (`weather.areaSelection`).
///
/// Device-local like the saved places and the bot choice: which states somebody looks at is a
/// fact about this phone, not about a radio, and not worth a backup row. One defaults key holding
/// JSON, so a field added to ``WeatherAreaSelection`` needs no migration — an unreadable value
/// reads as "nothing chosen yet" and the next tap writes a good one.
///
/// `@unchecked Sendable`: the only stored property is a `UserDefaults` reference, which Apple
/// documents as thread-safe.
public struct WeatherAreaSelectionStore: @unchecked Sendable {
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// What was chosen, or nil when nothing has been. Nil is not the same as the whole country:
  /// the default depends on the page's place, which this store knows nothing about.
  public var selection: WeatherAreaSelection? {
    get {
      guard let data = defaults.data(forKey: Self.key) else { return nil }
      return try? JSONDecoder().decode(WeatherAreaSelection.self, from: data)
    }
    nonmutating set {
      guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
        defaults.removeObject(forKey: Self.key)
        return
      }
      defaults.set(data, forKey: Self.key)
    }
  }

  /// What the picker opens on: the choice this phone last made, else the page's own state, else
  /// the whole country.
  public func selection(placeState: String?) -> WeatherAreaSelection {
    selection ?? .default(placeState: placeState)
  }

  private static let key = "weather.areaSelection"
}

// MARK: - What the tap costs

/// How many packets the next sweep will spend, said before it is spent (docs/MESHWX_UI.md §17).
///
/// It is an estimate and the screen words it as one ("About N packets"). There is no way to know
/// exactly: the bot builds the answer when it is asked, out of products this phone has not seen.
/// What the phone does have is the last sweep of the country, which says how many runs are active
/// and where — and one packet holds ``MeshWXWire/maxAreaSweepEntries`` of them.
public enum WeatherAreaSweepCost {
  /// What a national sweep costs when this phone has never seen one. Measured against the bot's
  /// live products on 2026-09-20: warnings and watches were 148 runs, four packets; with
  /// advisories 263 runs, seven.
  public static let typicalNationalPackets = 4
  public static let typicalNationalPacketsWithAdvisories = 7
  /// What one state costs when nothing at all is held: four states to a packet. A guess, and
  /// deliberately a cheap-sounding one — the number a person is deciding against is eight.
  public static let statesPerPacketWithoutASweep = 4

  /// - Parameters:
  ///   - selection: what the button would ask for.
  ///   - advisories: the wider breadth (`>wmap all`).
  ///   - held: the map as the phone has it, which is where the entry counts come from.
  public static func packets(
    for selection: WeatherAreaSelection, advisories: Bool, held: WeatherAlertMapPicture
  ) -> Int {
    guard !selection.asksWholeCountry else {
      // The last national sweep's own packet count is the best possible estimate of the next
      // one: it is what this bot sent for this country a few minutes ago. Its breadth is not
      // checked against `advisories` — the design says "the last national sweep's count" — so a
      // phone holding a narrow sweep shows that count for both buttons until a wider one arrives.
      return held.nationalPart?.totalPackets
        ?? (advisories ? typicalNationalPacketsWithAdvisories : typicalNationalPackets)
    }
    let states = Set(selection.askedStates)
    guard held.coversWholeCountry else {
      // Nothing to count. Four states to a packet, at least one.
      return max(1, (states.count + statesPerPacketWithoutASweep - 1) / statesPerPacketWithoutASweep)
    }
    // The alerts the phone believes are active in those states, plus one scope entry per state —
    // the scope rides in the entry list and spends the same budget the areas do (spec §7C).
    //
    // Counted off the resolved map rather than off the national sweep alone: where a newer
    // scoped sweep has already replaced a state's entries, those are the runs the bot would
    // send now, and the older national sweep's are not.
    let runs = held.entries.count { entry in
      guard let code = entry.stateCode else { return false }
      return states.contains(code)
    }
    let total = runs + states.count
    return max(1, (total + MeshWXWire.maxAreaSweepEntries - 1) / MeshWXWire.maxAreaSweepEntries)
  }
}
