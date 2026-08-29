import CoreLocation
import Foundation
@testable import MC1
@testable import MC1Services
import Testing

/// The receiver ("B") pin rule of `MessagePathMapView.locatedNodes`: a fix
/// stamped at receive time anchors the pin; only unstamped messages fall back
/// to the live user location.
@Suite("MessagePath located nodes")
@MainActor
struct MessagePathLocatedNodesTests {
  private func makeMessage(userLatitude: Double? = nil, userLongitude: Double? = nil) -> MessageDTO {
    MessageDTO(
      id: UUID(),
      radioID: UUID(),
      contactID: UUID(),
      channelIndex: nil,
      text: "Test",
      timestamp: 0,
      createdAt: Date(),
      direction: .incoming,
      status: .delivered,
      textType: .plain,
      ackCode: nil,
      pathLength: 0,
      snr: nil,
      senderKeyPrefix: nil,
      senderNodeName: nil,
      isRead: true,
      replyToID: nil,
      roundTripTime: nil,
      heardRepeats: 0,
      retryAttempt: 0,
      maxRetryAttempts: 0,
      userLatitude: userLatitude,
      userLongitude: userLongitude
    )
  }

  private func receiverPins(
    for message: MessageDTO,
    userLocation: CLLocation?
  ) -> [(point: MapPoint, coordinate: CLLocationCoordinate2D)] {
    MessagePathMapView.locatedNodes(
      for: .message(message),
      contacts: [],
      repeaters: [],
      discoveredRepeaters: [],
      userLocation: userLocation,
      receiverName: "Me"
    ).filter { $0.point.pinStyle == .pointB }
  }

  @Test
  func `A stamped message pins the receiver at its recorded fix, not the live location`() {
    let pins = receiverPins(
      for: makeMessage(userLatitude: 30.2672, userLongitude: -97.7431),
      userLocation: CLLocation(latitude: 40.0, longitude: -74.0)
    )
    #expect(pins.count == 1)
    #expect(pins.first?.coordinate.latitude == 30.2672)
    #expect(pins.first?.coordinate.longitude == -97.7431)
  }

  @Test
  func `A stamped message keeps its pin with no live location at all`() {
    let pins = receiverPins(
      for: makeMessage(userLatitude: 30.2672, userLongitude: -97.7431),
      userLocation: nil
    )
    #expect(pins.count == 1)
    #expect(pins.first?.coordinate.latitude == 30.2672)
  }

  @Test
  func `An unstamped message falls back to the live location`() {
    let pins = receiverPins(
      for: makeMessage(),
      userLocation: CLLocation(latitude: 40.0, longitude: -74.0)
    )
    #expect(pins.count == 1)
    #expect(pins.first?.coordinate.latitude == 40.0)
  }

  @Test
  func `A null-island stamp is junk, not a pin — falls back to the live location`() {
    let pins = receiverPins(
      for: makeMessage(userLatitude: 0, userLongitude: 0),
      userLocation: CLLocation(latitude: 40.0, longitude: -74.0)
    )
    #expect(pins.count == 1)
    #expect(pins.first?.coordinate.latitude == 40.0)
  }

  @Test
  func `Unstamped with no live location plots no receiver`() {
    #expect(receiverPins(for: makeMessage(), userLocation: nil).isEmpty)
  }
}

/// The heard-repeats builder: echo loops origin → hops → origin, pins deduped,
/// the shared exact-match hop rule.
@Suite("Heard repeat nodes")
@MainActor
struct HeardRepeatNodesTests {
  private let origin = CLLocationCoordinate2D(latitude: 30.0, longitude: -97.0)

  /// `keySuffix` differentiates full public keys that share a first byte — an
  /// ambiguous 1-byte hash needs two *distinct* keys behind the same prefix.
  private func makeRepeater(
    firstByte: UInt8,
    keySuffix: UInt8 = 0,
    latitude: Double,
    longitude: Double
  ) -> ContactDTO {
    ContactDTO(
      id: UUID(),
      radioID: UUID(),
      publicKey: Data([firstByte, keySuffix] + Array(repeating: UInt8(0), count: 30)),
      name: String(format: "R-%02X", firstByte),
      typeRawValue: ContactType.repeater.rawValue,
      flags: 0,
      outPathLength: 0,
      outPath: Data(),
      lastAdvertTimestamp: 0,
      latitude: latitude,
      longitude: longitude,
      lastModified: 0,
      lastHeardTimestamp: nil,
      nickname: nil,
      isBlocked: false,
      isMuted: false,
      isFavorite: false,
      lastMessageDate: nil,
      unreadCount: 0
    )
  }

  private func makeRepeat(
    pathBytes: [UInt8],
    snr: Double? = nil,
    receivedAt: Date = Date(timeIntervalSince1970: 1_000_000)
  ) -> MessageRepeatDTO {
    MessageRepeatDTO(
      messageID: UUID(),
      receivedAt: receivedAt,
      pathNodes: Data(pathBytes),
      snr: snr,
      rssi: nil,
      rxLogEntryID: nil
    )
  }

  private func makeStampedMessage() -> MessageDTO {
    MessageDTO(
      id: UUID(),
      radioID: UUID(),
      contactID: nil,
      channelIndex: 3,
      text: "Test",
      timestamp: 0,
      createdAt: Date(),
      direction: .outgoing,
      status: .sent,
      textType: .plain,
      ackCode: nil,
      pathLength: 0,
      snr: nil,
      senderKeyPrefix: nil,
      senderNodeName: nil,
      isRead: true,
      replyToID: nil,
      roundTripTime: nil,
      heardRepeats: 0,
      retryAttempt: 0,
      maxRetryAttempts: 0,
      userLatitude: origin.latitude,
      userLongitude: origin.longitude
    )
  }

  /// CLLocationCoordinate2D is not Equatable; compare line geometry by value.
  private func signature(_ lines: [MapLine]) -> [[[Double]]] {
    lines.map { $0.coordinates.map { [$0.latitude, $0.longitude] } }
  }

  private func signature(_ groups: [[CLLocationCoordinate2D]]) -> [[[Double]]] {
    groups.map { $0.map { [$0.latitude, $0.longitude] } }
  }

  private func build(
    repeats: [MessageRepeatDTO],
    repeaters: [ContactDTO],
    stamped: Bool = true,
    userLocation: CLLocation? = nil
  ) -> (nodes: [(point: MapPoint, coordinate: CLLocationCoordinate2D)], lines: [MapLine]) {
    var message = makeStampedMessage()
    if !stamped {
      message.userLatitude = nil
      message.userLongitude = nil
    }
    return MessagePathMapView.heardRepeatNodes(
      message: message,
      repeats: repeats,
      repeaters: repeaters,
      discoveredRepeaters: [],
      userLocation: userLocation,
      originName: "Me"
    )
  }

  @Test
  func `A single one-hop echo is its own reception leg, SNR-styled, with a badge`() {
    let a = makeRepeater(firstByte: 0xAA, latitude: 30.1, longitude: -97.1)
    let built = build(repeats: [makeRepeat(pathBytes: [0xAA], snr: 7.5)], repeaters: [a])

    // Origin + repeater + the midpoint SNR badge.
    #expect(built.nodes.count == 3)
    #expect(built.nodes.first?.point.pinStyle == .pointB)
    // Compare against the house formatter, not a literal — the SNR number is
    // locale-formatted ("7.5" vs "7,5").
    let distance = CLLocation(latitude: a.latitude, longitude: a.longitude)
      .distance(from: CLLocation(latitude: origin.latitude, longitude: origin.longitude))
    let expectedBadge = MapLine.snrBadgeText(distance: distance, snr: 7.5)
    let badge = built.nodes.first { $0.point.pinStyle == .badge }
    #expect(badge?.point.badgeText == expectedBadge)
    // A lone straight leg's badge sits at the chord midpoint — not on the
    // origin pin (the straight "arc" has no apex of its own).
    #expect(badge?.coordinate.latitude == (a.latitude + origin.latitude) / 2)
    #expect(badge?.coordinate.longitude == (a.longitude + origin.longitude) / 2)
    // Out and back share the geometry, so the single line IS the measured leg.
    #expect(signature(built.lines) == signature([[a.coordinate2D, origin]]))
    #expect(built.lines.first?.style == .forSNR(7.5))
  }

  @Test
  func `Repeats sharing a repeater pin it once, numbered, and each echo still traverses it`() {
    let a = makeRepeater(firstByte: 0xAA, latitude: 30.1, longitude: -97.1)
    let b = makeRepeater(firstByte: 0xBB, latitude: 30.2, longitude: -97.2)
    let built = build(
      repeats: [makeRepeat(pathBytes: [0xAA]), makeRepeat(pathBytes: [0xAA, 0xBB])],
      repeaters: [a, b]
    )

    // Origin + A + B, A not duplicated. A is hop 1 in both echoes, B hop 2.
    #expect(built.nodes.count == 3)
    let hopPins = built.nodes.filter { $0.point.pinStyle == .repeaterHop }
    #expect(hopPins.map(\.point.hopIndex) == [1, 2])
    // Bodies come first (echo 2's origin→A→B), then the merged reception legs
    // in first-seen tail order: A→origin (echo 1), B→origin (echo 2). No SNR
    // values, so the legs stay neutral rather than dashed-untraced.
    #expect(signature(built.lines) == signature([
      [origin, a.coordinate2D, b.coordinate2D],
      [a.coordinate2D, origin],
      [b.coordinate2D, origin],
    ]))
    #expect(built.lines.map(\.style) == [.messagePath, .messagePath, .messagePath])
  }

  @Test
  func `Echoes sharing a tail fan into opposite arcs, latest innermost, badges apart`() {
    let a = makeRepeater(firstByte: 0xAA, latitude: 30.1, longitude: -97.1)
    let b = makeRepeater(firstByte: 0xBB, latitude: 30.2, longitude: -97.2)
    let earlier = Date(timeIntervalSince1970: 1_000_000)
    let later = Date(timeIntervalSince1970: 1_000_060)
    let built = build(
      repeats: [
        makeRepeat(pathBytes: [0xAA], snr: -8, receivedAt: earlier),
        makeRepeat(pathBytes: [0xBB, 0xAA], snr: 9, receivedAt: later),
      ],
      repeaters: [a, b]
    )

    // Both echoes end at A: two coincident measurements, so two arcs — the
    // later (+9) first, both spanning A → origin, bowing to opposite sides so
    // neither buries the other.
    #expect(built.lines.map(\.style) == [.messagePath, .forSNR(9), .forSNR(-8)])
    let arcs = Array(built.lines.dropFirst())
    for arc in arcs {
      #expect(arc.coordinates.count > 2)
      #expect(arc.coordinates.first?.latitude == a.latitude)
      #expect(arc.coordinates.last?.latitude == origin.latitude)
    }
    // Opposite bulges, verified by the sign of the cross product of the
    // chord with each apex — different magnitudes on the SAME side would
    // slip past a mere inequality check.
    func side(of apex: CLLocationCoordinate2D) -> Double {
      let chordDx = origin.longitude - a.longitude
      let chordDy = origin.latitude - a.latitude
      return chordDx * (apex.latitude - a.latitude) - chordDy * (apex.longitude - a.longitude)
    }
    let apex0 = arcs[0].coordinates[arcs[0].coordinates.count / 2]
    let apex1 = arcs[1].coordinates[arcs[1].coordinates.count / 2]
    #expect(side(of: apex0) * side(of: apex1) < 0)
    let badges = built.nodes.filter { $0.point.pinStyle == .badge }
    #expect(badges.count == 2)
    #expect(
      badges[0].coordinate.latitude != badges[1].coordinate.latitude
        || badges[0].coordinate.longitude != badges[1].coordinate.longitude
    )
  }

  @Test
  func `Arc offsets fan symmetrically and a lone leg stays straight`() {
    #expect(MessagePathMapView.arcOffsetStep(rank: 0, of: 1) == 0)
    #expect((0..<4).map { MessagePathMapView.arcOffsetStep(rank: $0, of: 4) } == [1, -1, 2, -2])
    let straight = MessagePathMapView.legArcCoordinates(
      from: origin,
      to: CLLocationCoordinate2D(latitude: 30.1, longitude: -97.1),
      offsetStep: 0
    )
    #expect(straight.count == 2)
  }

  @Test
  func `A repeater at different positions in different echoes keeps the plain pin`() {
    let a = makeRepeater(firstByte: 0xAA, latitude: 30.1, longitude: -97.1)
    let b = makeRepeater(firstByte: 0xBB, latitude: 30.2, longitude: -97.2)
    let built = build(
      repeats: [makeRepeat(pathBytes: [0xAA]), makeRepeat(pathBytes: [0xBB, 0xAA])],
      repeaters: [a, b]
    )

    let pinsByName = Dictionary(
      uniqueKeysWithValues: built.nodes
        .filter { $0.point.pinStyle == .repeaterHop }
        .map { ($0.point.label ?? "", $0.point.hopIndex) }
    )
    // A sat at position 1 and position 2 — one number would be a lie.
    #expect(pinsByName["R-AA"] == .some(nil))
    #expect(pinsByName["R-BB"] == .some(1))
  }

  @Test
  func `An unplottable tail closes the loop neutrally — the measured leg is not the drawn one`() {
    let a = makeRepeater(firstByte: 0xAA, latitude: 30.1, longitude: -97.1)
    // Path AA → CC, where CC (the repeater we actually heard the echo from)
    // is unknown: no SNR styling and no badge on a leg the radio never measured.
    let built = build(repeats: [makeRepeat(pathBytes: [0xAA, 0xCC], snr: 7.5)], repeaters: [a])

    #expect(signature(built.lines) == signature([[origin, a.coordinate2D, origin]]))
    #expect(built.lines.map(\.style) == [.messagePath])
    #expect(!built.nodes.contains { $0.point.pinStyle == .badge })
  }

  @Test
  func `An ambiguous hop hash resolves nothing — no pin, no loop`() {
    // Two repeaters sharing the first key byte: a 1-byte hash cannot tell
    // them apart, so the hop must be skipped rather than guessed.
    let a1 = makeRepeater(firstByte: 0xAA, keySuffix: 1, latitude: 30.1, longitude: -97.1)
    let a2 = makeRepeater(firstByte: 0xAA, keySuffix: 2, latitude: 30.9, longitude: -97.9)
    let built = build(repeats: [makeRepeat(pathBytes: [0xAA])], repeaters: [a1, a2])

    #expect(built.nodes.count == 1)
    #expect(built.nodes.first?.point.pinStyle == .pointB)
    #expect(built.lines.isEmpty)
  }

  @Test
  func `A hash shared across the contact and discovered tables is ambiguous too`() {
    // A contact and a discovered node with different full keys behind the
    // same 1-byte prefix: each table alone reads "exact", but the hash still
    // names two possible repeaters — the hop must be skipped.
    let contact = makeRepeater(firstByte: 0xAA, keySuffix: 1, latitude: 30.1, longitude: -97.1)
    let discovered = DiscoveredNodeDTO(
      id: UUID(),
      radioID: UUID(),
      publicKey: Data([0xAA, 0x02] + Array(repeating: UInt8(0), count: 30)),
      name: "Discovered-AA",
      typeRawValue: ContactType.repeater.rawValue,
      lastHeard: Date(),
      lastAdvertTimestamp: 0,
      latitude: 30.5,
      longitude: -97.5,
      outPathLength: 0,
      outPath: Data(),
      inboundHopCount: nil,
      inboundHopAdvertTimestamp: nil
    )
    var message = makeStampedMessage()
    message.userLatitude = origin.latitude
    message.userLongitude = origin.longitude
    let built = MessagePathMapView.heardRepeatNodes(
      message: message,
      repeats: [makeRepeat(pathBytes: [0xAA])],
      repeaters: [contact],
      discoveredRepeaters: [discovered],
      userLocation: nil,
      originName: "Me"
    )

    #expect(built.nodes.count == 1)
    #expect(built.lines.isEmpty)
  }

  @Test
  func `An unresolvable middle hop is skipped, the reception leg still closes home`() {
    let a = makeRepeater(firstByte: 0xAA, latitude: 30.1, longitude: -97.1)
    let b = makeRepeater(firstByte: 0xBB, latitude: 30.2, longitude: -97.2)
    let built = build(
      repeats: [makeRepeat(pathBytes: [0xAA, 0xCC, 0xBB])],
      repeaters: [a, b]
    )

    // The tail (BB) is plottable, so the reception leg still closes home even
    // with the unknown middle hop elided from the body. Nil SNR → neutral.
    #expect(signature(built.lines) == signature([
      [origin, a.coordinate2D, b.coordinate2D],
      [b.coordinate2D, origin],
    ]))
    #expect(built.lines.map(\.style) == [.messagePath, .messagePath])
  }

  @Test
  func `With no origin at all, hops still pin but a single-hop echo draws no line`() {
    let a = makeRepeater(firstByte: 0xAA, latitude: 30.1, longitude: -97.1)
    let b = makeRepeater(firstByte: 0xBB, latitude: 30.2, longitude: -97.2)
    let built = build(
      repeats: [makeRepeat(pathBytes: [0xAA]), makeRepeat(pathBytes: [0xAA, 0xBB])],
      repeaters: [a, b],
      stamped: false,
      userLocation: nil
    )

    #expect(built.nodes.count == 2)
    #expect(built.nodes.allSatisfy { $0.point.pinStyle == .repeaterHop })
    // One-hop echo: a single coordinate is not a line. Two-hop echo: the
    // hop-to-hop segment survives, unclosed and neutral — with no origin
    // there is no reception leg to measure.
    #expect(signature(built.lines) == signature([[a.coordinate2D, b.coordinate2D]]))
    #expect(built.lines.map(\.style) == [.messagePath])
  }

  @Test
  func `An unstamped message anchors the reception leg to the live location`() {
    let a = makeRepeater(firstByte: 0xAA, latitude: 30.1, longitude: -97.1)
    let live = CLLocation(latitude: 40.0, longitude: -74.0)
    let built = build(
      repeats: [makeRepeat(pathBytes: [0xAA])],
      repeaters: [a],
      stamped: false,
      userLocation: live
    )

    #expect(built.lines.first?.coordinates.first?.latitude == 30.1)
    #expect(built.lines.first?.coordinates.last?.latitude == 40.0)
  }
}

/// The hop-plottability rule under identity churn: a re-keyed repeater's dead
/// advert row must not veto its living key, an unlocated contact must not
/// shadow its located same-key discovered row, and an all-stale pool still
/// pins. Mirrors the field failure where hop "ABBA" (one downtown repeater,
/// old key lingering as a stale discovered node) vanished from every path map.
@Suite("Plottable repeater resolution")
@MainActor
struct PlottableRepeaterResolutionTests {
  private static let staleAdvert = UInt32(Date().timeIntervalSince1970 - 100 * 24 * 3600)
  private static let freshAdvert = UInt32(Date().timeIntervalSince1970 - 3600)

  private func makeContact(
    keyBytes: [UInt8],
    name: String,
    latitude: Double,
    longitude: Double
  ) -> ContactDTO {
    ContactDTO(
      id: UUID(),
      radioID: UUID(),
      publicKey: Data(keyBytes + Array(repeating: UInt8(0), count: 32 - keyBytes.count)),
      name: name,
      typeRawValue: ContactType.repeater.rawValue,
      flags: 0,
      outPathLength: 0,
      outPath: Data(),
      lastAdvertTimestamp: Self.freshAdvert,
      latitude: latitude,
      longitude: longitude,
      lastModified: 0,
      lastHeardTimestamp: nil,
      nickname: nil,
      isBlocked: false,
      isMuted: false,
      isFavorite: false,
      lastMessageDate: nil,
      unreadCount: 0
    )
  }

  private func makeDiscovered(
    keyBytes: [UInt8],
    name: String,
    lastAdvertTimestamp: UInt32,
    latitude: Double,
    longitude: Double
  ) -> DiscoveredNodeDTO {
    DiscoveredNodeDTO(
      id: UUID(),
      radioID: UUID(),
      publicKey: Data(keyBytes + Array(repeating: UInt8(0), count: 32 - keyBytes.count)),
      name: name,
      typeRawValue: ContactType.repeater.rawValue,
      lastHeard: Date(),
      lastAdvertTimestamp: lastAdvertTimestamp,
      latitude: latitude,
      longitude: longitude,
      outPathLength: 0,
      outPath: Data(),
      inboundHopCount: nil,
      inboundHopAdvertTimestamp: nil
    )
  }

  @Test
  func `a re-keyed repeater's stale old identity does not veto the living key`() {
    // The field case: hop hash AB BA, current key saved as a located contact,
    // old key still in the discovered table with a months-old advert ~6 m
    // away. The hop must pin at the living contact, not drop as "ambiguous".
    let living = makeContact(
      keyBytes: [0xAB, 0xBA, 0x4A, 0x13],
      name: "Digitaino Central",
      latitude: 30.27111,
      longitude: -97.73012
    )
    let deadTwin = makeDiscovered(
      keyBytes: [0xAB, 0xBA, 0x4A, 0x5B],
      name: "Digitaino Central ",
      lastAdvertTimestamp: Self.staleAdvert,
      latitude: 30.27115,
      longitude: -97.73008
    )

    let resolved = MessagePathMapView.resolvePlottableRepeater(
      hashBytes: Data([0xAB, 0xBA]),
      repeaters: [living],
      discoveredRepeaters: [deadTwin],
      referenceLocation: nil
    )

    #expect(resolved?.resolvableName == "Digitaino Central")
    #expect(resolved?.latitude == 30.27111)
  }

  @Test
  func `two live identities behind one hash still drop the hop`() {
    // Both keys advertising: the hash genuinely names two repeaters, so the
    // original ambiguity rule holds and the hop stays unpinned.
    let living = makeContact(
      keyBytes: [0xAB, 0xBA, 0x4A, 0x13],
      name: "Central A",
      latitude: 30.27111,
      longitude: -97.73012
    )
    let liveRival = makeDiscovered(
      keyBytes: [0xAB, 0xBA, 0x4A, 0x5B],
      name: "Central B",
      lastAdvertTimestamp: Self.freshAdvert,
      latitude: 30.4,
      longitude: -97.9
    )

    let resolved = MessagePathMapView.resolvePlottableRepeater(
      hashBytes: Data([0xAB, 0xBA]),
      repeaters: [living],
      discoveredRepeaters: [liveRival],
      referenceLocation: nil
    )

    #expect(resolved == nil)
  }

  @Test
  func `an unlocated contact does not shadow the located discovered row for the same key`() {
    let unlocatedContact = makeContact(
      keyBytes: [0xA2, 0x00, 0x11],
      name: "Spring Condos - Roof",
      latitude: 0,
      longitude: 0
    )
    let locatedTwin = makeDiscovered(
      keyBytes: [0xA2, 0x00, 0x11],
      name: "Spring Condos - Roof",
      lastAdvertTimestamp: Self.freshAdvert,
      latitude: 30.2695,
      longitude: -97.7525
    )

    let resolved = MessagePathMapView.resolvePlottableRepeater(
      hashBytes: Data([0xA2, 0x00]),
      repeaters: [unlocatedContact],
      discoveredRepeaters: [locatedTwin],
      referenceLocation: nil
    )

    #expect(resolved?.latitude == 30.2695)
    #expect(resolved?.longitude == -97.7525)
  }

  @Test
  func `an all-stale sole candidate still pins`() {
    // A discovered-only repeater in a region that fell quiet: staleness is
    // relative, so with no live rival the quiet row remains the answer.
    let quiet = makeDiscovered(
      keyBytes: [0x81, 0xBB, 0x07],
      name: "BCW RAK 4631",
      lastAdvertTimestamp: Self.staleAdvert,
      latitude: 30.31,
      longitude: -97.93
    )

    let resolved = MessagePathMapView.resolvePlottableRepeater(
      hashBytes: Data([0x81, 0xBB]),
      repeaters: [],
      discoveredRepeaters: [quiet],
      referenceLocation: nil
    )

    #expect(resolved?.resolvableName == "BCW RAK 4631")
  }
}

private extension ContactDTO {
  var coordinate2D: CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  }
}
