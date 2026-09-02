import CoreLocation
import Foundation
@testable import MC1
@testable import MC1Services
import Testing

/// The coverage map's construction rules: where a route starts, which hops pin,
/// which links are counted, which leg carries the SNR treatment, what the
/// focus state draws, and how a partial draw grows.
@Suite("PacketScope coverage builder")
@MainActor
struct PacketScopeCoverageBuilderTests {
  private let origin = CLLocationCoordinate2D(latitude: 30.0, longitude: -97.0)
  private let observerSite = CLLocationCoordinate2D(latitude: 30.5, longitude: -97.5)

  // MARK: - Fixtures

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
      name: String(format: "R-%02X%02X", firstByte, keySuffix),
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

  private func makeMessage(
    direction: MessageDirection = .outgoing,
    stamped: Bool = true,
    senderKeyPrefix: Data? = nil
  ) -> MessageDTO {
    MessageDTO(
      id: UUID(),
      radioID: UUID(),
      contactID: nil,
      channelIndex: 3,
      text: "Test",
      timestamp: 0,
      createdAt: Date(),
      direction: direction,
      status: .sent,
      textType: .plain,
      ackCode: nil,
      pathLength: 0,
      snr: nil,
      senderKeyPrefix: senderKeyPrefix,
      senderNodeName: nil,
      isRead: true,
      replyToID: nil,
      roundTripTime: nil,
      heardRepeats: 0,
      retryAttempt: 0,
      maxRetryAttempts: 0,
      userLatitude: stamped ? origin.latitude : nil,
      userLongitude: stamped ? origin.longitude : nil,
      packetContentHash: "286dcbdeab84b458"
    )
  }

  private func route(_ hops: [String], resolved: [String?] = [], snr: Double? = nil) -> PacketScopeReception.Route {
    PacketScopeReception.Route(hops: hops, resolvedHops: resolved, bestSNR: snr)
  }

  private func reception(_ observer: String, routes: [PacketScopeReception.Route]) -> PacketScopeReception {
    PacketScopeReception(
      observerID: observer,
      observerName: "Observer \(observer)",
      observerIATA: "AUS",
      bestSNR: routes.compactMap(\.bestSNR).max(),
      bestRSSI: nil,
      routes: routes,
      firstHeard: nil,
      receptionCount: routes.count
    )
  }

  private func observer(_ id: String, located: Bool = true, at site: CLLocationCoordinate2D? = nil) -> PacketScopeObserver {
    let site = site ?? observerSite
    return PacketScopeObserver(
      id: id,
      name: "Observer \(id)",
      iata: "AUS",
      latitude: located ? site.latitude : nil,
      longitude: located ? site.longitude : nil
    )
  }

  private func build(
    message: MessageDTO? = nil,
    receptions: [PacketScopeReception],
    observers: [PacketScopeObserver],
    contacts: [ContactDTO] = [],
    repeaters: [ContactDTO] = [],
    userLocation: CLLocation? = nil
  ) -> PacketScopeCoverageMap {
    PacketScopeCoverageBuilder.build(
      message: message ?? makeMessage(),
      receptions: receptions,
      observers: observers,
      contacts: contacts,
      repeaters: repeaters,
      discoveredRepeaters: [],
      userLocation: userLocation,
      originName: "Me"
    )
  }

  /// CLLocationCoordinate2D is not Equatable; compare geometry by value.
  private func signature(_ lines: [MapLine]) -> [[[Double]]] {
    lines.map { $0.coordinates.map { [$0.latitude, $0.longitude] } }
  }

  private func signature(_ groups: [[CLLocationCoordinate2D]]) -> [[[Double]]] {
    groups.map { $0.map { [$0.latitude, $0.longitude] } }
  }

  // MARK: - Default state: pins, links, legs

  @Test
  func `A one-hop route pins origin, hop and observer, counts two links, and gives the observer one SNR leg`() throws {
    let a = makeRepeater(firstByte: 0xAA, latitude: 30.1, longitude: -97.1)
    let map = build(
      receptions: [reception("obs", routes: [route(["AA"], snr: 7.5)])],
      observers: [observer("obs")],
      repeaters: [a]
    )

    #expect(map.isPlottable)
    #expect(map.nodes.map(\.point.pinStyle) == [.pointA, .repeaterHop, .pointB])
    #expect(map.nodes[0].point.label == "Me")
    #expect(map.nodes[0].point.labelPriority == 0)
    // Repeater pins are named, never numbered — numbering belongs to a focus.
    #expect(map.nodes[1].point.label == a.resolvableName)
    #expect(map.nodes[1].point.hopIndex == nil)
    // The observer pin carries its name alone; the signal lives in the row and
    // on the leg's badge. Observer pills outrank repeater pills in a collision.
    #expect(map.nodes[2].point.label == "Observer obs")
    #expect(map.nodes[2].point.labelPriority == 10)
    #expect(map.nodes[1].point.labelPriority > map.nodes[2].point.labelPriority)

    #expect(map.links.map(\.routeCount) == [1, 1])
    #expect(signature(map.links.map { MapLine(id: $0.id, coordinates: [$0.from, $0.to], style: .messagePath, opacity: 1) })
      == signature([[origin, a.coordinate2D], [a.coordinate2D, observerSite]]))

    let leg = try #require(map.observerLegs.first)
    #expect(leg.id == "obs")
    #expect(signature([leg.line]) == signature([[a.coordinate2D, observerSite]]))
    #expect(leg.line.style == .forSNR(7.5))
    #expect(map.observerDistances["obs"] != nil)
    // Every hop placed and the leg drawn: the drawn length is not a lower bound.
    #expect(map.routes.first?.isComplete == true)
    #expect(map.routes.first?.unplacedTailCount == 0)
  }

  @Test
  func `Pins keep their identity across rebuilds`() {
    let a = makeRepeater(firstByte: 0xAA, latitude: 30.1, longitude: -97.1)
    let first = build(receptions: [reception("obs", routes: [route(["AA"], snr: 1)])], observers: [observer("obs")], repeaters: [a])
    let second = build(receptions: [reception("obs", routes: [route(["AA"], snr: 1)])], observers: [observer("obs")], repeaters: [a])
    #expect(first.nodes.map(\.point.id) == second.nodes.map(\.point.id))
    #expect(PacketScopeCoverageBuilder.stableID("obs:obs") == first.nodes[2].point.id)
  }

  @Test
  func `Routes sharing a link count it once per route, so the trunk outweighs a spur`() throws {
    let a = makeRepeater(firstByte: 0xAA, latitude: 30.1, longitude: -97.1)
    let b = makeRepeater(firstByte: 0xBB, latitude: 30.2, longitude: -97.2)
    let c = makeRepeater(firstByte: 0xCC, latitude: 30.3, longitude: -97.3)
    let far = CLLocationCoordinate2D(latitude: 30.9, longitude: -97.9)
    let map = build(
      receptions: [
        reception("one", routes: [route(["AA", "BB"], snr: 5), route(["AA", "CC"], snr: 3)]),
        reception("two", routes: [route(["AA", "BB"], snr: 2)]),
      ],
      observers: [observer("one"), observer("two", at: far)],
      repeaters: [a, b, c]
    )
    let counts = Dictionary(map.links.map { ($0.id, $0.routeCount) }, uniquingKeysWith: { a, _ in a })
    // origin→A is crossed by all three routes; A→B by two; A→C by one.
    #expect(counts["origin>hop:\(hex(a))"] == 3)
    #expect(counts["hop:\(hex(a))>hop:\(hex(b))"] == 2)
    #expect(counts["hop:\(hex(a))>hop:\(hex(c))"] == 1)
    #expect(map.maxLinkRouteCount == 3)
    // Each observer gets exactly one leg, from its strongest route's tail.
    #expect(map.observerLegs.map(\.id) == ["one", "two"])
    let one = try #require(map.observerLegs.first)
    #expect(signature([one.line]) == signature([[b.coordinate2D, observerSite]]))
    #expect(one.snr == 5)
  }

  @Test
  func `A direct reception is one link and one SNR leg from the origin`() throws {
    let map = build(
      receptions: [reception("obs", routes: [route([], snr: 12.0)])],
      observers: [observer("obs")]
    )
    #expect(map.links.map(\.id) == ["origin>obs:obs"])
    let leg = try #require(map.observerLegs.first)
    #expect(signature([leg.line]) == signature([[origin, observerSite]]))
    #expect(leg.line.style == .forSNR(12.0))
    #expect(map.nodes.map(\.point.pinStyle) == [.pointA, .pointB])
  }

  @Test
  func `An observer with no location gets no leg and no link into it, but its hops still pin and link`() throws {
    let a = makeRepeater(firstByte: 0xAA, latitude: 30.1, longitude: -97.1)
    let b = makeRepeater(firstByte: 0xBB, latitude: 30.2, longitude: -97.2)
    let map = build(
      receptions: [reception("obs", routes: [route(["AA", "BB"], snr: 3.0)])],
      observers: [observer("obs", located: false)],
      repeaters: [a, b]
    )
    #expect(map.observerLegs.isEmpty)
    #expect(map.links.map(\.id) == ["origin>hop:\(hex(a))", "hop:\(hex(a))>hop:\(hex(b))"])
    #expect(map.nodes.map(\.point.pinStyle) == [.pointA, .repeaterHop, .repeaterHop])
    #expect(map.observerDistances.isEmpty)
    // Its one route still exists for the focus state: the body, with no leg —
    // and, since the route carries a signal, a readout badge at the body's end
    // so it can still be told apart from a sibling route on the same body.
    let built = try #require(map.routes.first)
    #expect(built.segments.count == 1)
    #expect(built.badge == nil)
    #expect(!built.hasMeasuredLeg)
    #expect(built.isDrawable)
    let readout = try #require(built.soloBadge)
    #expect(readout.badgeText == PacketScopeCoverageBuilder.decibels(3.0))
    #expect(map.drawableObserverIDs == ["obs"])
  }

  @Test
  func `A gap in the path is a gap: no link bridges an unplaced hop, and the body splits`() throws {
    let a = makeRepeater(firstByte: 0xAA, latitude: 30.1, longitude: -97.1)
    let c = makeRepeater(firstByte: 0xCC, latitude: 30.3, longitude: -97.3)
    let map = build(
      receptions: [reception("obs", routes: [route(["AA", "ZZ", "CC"], snr: 9.0)])],
      observers: [observer("obs")],
      repeaters: [a, c]
    )
    // origin→A and C→observer are adjacent in the path; A→C is not.
    #expect(map.links.map(\.id) == ["origin>hop:\(hex(a))", "hop:\(hex(c))>obs:obs"])
    let built = try #require(map.routes.first)
    #expect(signature(built.segments) == signature([[origin, a.coordinate2D], [c.coordinate2D, observerSite]]))
    #expect(built.segments.map(\.style) == [.messagePath, .forSNR(9.0)])
  }

  @Test
  func `An unplaced tail means no measured leg, no badge, and no link into the observer`() throws {
    let a = makeRepeater(firstByte: 0xAA, latitude: 30.1, longitude: -97.1)
    let map = build(
      receptions: [reception("obs", routes: [route(["AA", "ZZ"], snr: 9.0)])],
      observers: [observer("obs")],
      repeaters: [a]
    )
    #expect(map.observerLegs.isEmpty)
    #expect(map.links.map(\.id) == ["origin>hop:\(hex(a))"])
    let built = try #require(map.routes.first)
    #expect(signature(built.segments) == signature([[origin, a.coordinate2D]]))
    #expect(built.badge == nil)
    // The observer pin is still there — it heard the packet.
    #expect(map.nodes.map(\.point.pinStyle) == [.pointA, .repeaterHop, .pointB])
  }

  @Test
  func `A route no part of which can be placed still exists, undrawable, and an origin alone is not plottable`() {
    let map = build(
      receptions: [reception("obs", routes: [route(["ZZ"], snr: 9.0)])],
      observers: [observer("obs", located: false)]
    )
    // The ladder lists it, so the map must know it too — as not drawable.
    #expect(map.routes.count == 1)
    #expect(map.routes.first?.isDrawable == false)
    #expect(map.drawableRouteIDs.isEmpty)
    #expect(map.drawableObserverIDs.isEmpty)
    #expect(map.links.isEmpty)
    #expect(map.nodes.map(\.point.pinStyle) == [.pointA])
    #expect(!map.isPlottable)
  }

  // MARK: - Focus state

  @Test
  func `Two routes into one observer over the same tail fan into distinct arcs with their own badges`() throws {
    let a = makeRepeater(firstByte: 0xAA, latitude: 30.1, longitude: -97.1)
    let b = makeRepeater(firstByte: 0xBB, latitude: 30.2, longitude: -97.2)
    let c = makeRepeater(firstByte: 0xCC, latitude: 30.3, longitude: -97.3)
    let map = build(
      receptions: [reception("obs", routes: [route(["AA", "BB"], snr: 5.0), route(["CC", "BB"], snr: 6.0)])],
      observers: [observer("obs")],
      repeaters: [a, b, c]
    )
    #expect(map.routes.count == 2)
    let legs = try map.routes.map { try #require($0.segments.last) }
    #expect(legs.allSatisfy { $0.coordinates.count > 2 })
    #expect(signature(legs)[0] != signature(legs)[1])
    let badges = try map.routes.map { try #require($0.badge) }
    #expect(badges[0].coordinate.latitude != badges[1].coordinate.latitude)
    #expect(badges[0].id != badges[1].id)
    // The default-state leg is straight and belongs to the stronger route.
    let leg = try #require(map.observerLegs.first)
    #expect(leg.line.coordinates.count == 2)
    #expect(leg.snr == 6.0)
    // No global numbering: a repeater's position is a property of a focus.
    let hopPins = map.nodes.filter { $0.point.pinStyle == .repeaterHop }
    #expect(hopPins.map(\.point.hopIndex) == [nil, nil, nil])
    // The ladder order matches the headline leg: the 6 dB route first.
    #expect(map.routeIDsByObserver["obs"] == ["obs|CC,BB", "obs|AA,BB"])
  }

  @Test
  func `A repeater at different positions in different routes keeps a plain pin`() {
    let a = makeRepeater(firstByte: 0xAA, latitude: 30.1, longitude: -97.1)
    let b = makeRepeater(firstByte: 0xBB, latitude: 30.2, longitude: -97.2)
    let map = build(
      receptions: [reception("obs", routes: [route(["AA"]), route(["BB", "AA"])])],
      observers: [observer("obs")],
      repeaters: [a, b]
    )
    let pinA = map.nodes.first { $0.point.label == a.resolvableName }
    #expect(pinA?.point.hopIndex == nil)
  }

  @Test
  func `Route ranking prefers signal, then fewer hops, and puts unmeasured routes last`() {
    let ranked = PacketScopeCoverageBuilder.rankedRoutes([
      route(["AA", "BB"], snr: nil),
      route(["AA"], snr: 4),
      route(["CC", "DD"], snr: 4),
      route(["EE"], snr: 9),
    ])
    #expect(ranked.map(\.hops) == [["EE"], ["AA"], ["CC", "DD"], ["AA", "BB"]])
  }

  // MARK: - Resolution

  @Test
  func `The server's full public key pins a hop whose short hash is ambiguous on this phone`() throws {
    let a1 = makeRepeater(firstByte: 0xAA, keySuffix: 0x01, latitude: 30.1, longitude: -97.1)
    let a2 = makeRepeater(firstByte: 0xAA, keySuffix: 0x02, latitude: 30.9, longitude: -97.9)

    let unresolved = build(
      receptions: [reception("obs", routes: [route(["AA"], snr: 1.0)])],
      observers: [observer("obs")],
      repeaters: [a1, a2]
    )
    #expect(!unresolved.nodes.contains { $0.point.pinStyle == .repeaterHop })

    let resolved = build(
      receptions: [reception("obs", routes: [route(["AA"], resolved: [a2.publicKeyHex], snr: 1.0)])],
      observers: [observer("obs")],
      repeaters: [a1, a2]
    )
    let pin = try #require(resolved.nodes.first { $0.point.pinStyle == .repeaterHop })
    #expect(pin.coordinate.latitude == a2.latitude)
  }

  @Test
  func `Observer ids join case-insensitively across the roster and the observations`() {
    let map = build(
      receptions: [reception("ABCDEF", routes: [route([], snr: 1.0)])],
      observers: [observer("abcdef")]
    )
    #expect(map.nodes.contains { $0.point.pinStyle == .pointB })
    #expect(map.observerLegs.map(\.id) == ["ABCDEF"])
    #expect(map.observerDistances["ABCDEF"] != nil)
  }

  @Test
  func `An incoming message starts at its located sender, and nowhere when the sender is unknown`() throws {
    let sender = makeRepeater(firstByte: 0x11, latitude: 29.5, longitude: -96.5)
    let a = makeRepeater(firstByte: 0xAA, latitude: 30.1, longitude: -97.1)
    let incoming = makeMessage(direction: .incoming, senderKeyPrefix: sender.publicKeyPrefix)

    let located = build(
      message: incoming,
      receptions: [reception("obs", routes: [route(["AA"], snr: 2.0)])],
      observers: [observer("obs")],
      contacts: [sender],
      repeaters: [a]
    )
    let pin = try #require(located.nodes.first)
    #expect(pin.point.pinStyle == .pointA)
    #expect(pin.point.label == sender.displayName)
    #expect(pin.coordinate.latitude == sender.latitude)

    let unknown = build(
      message: incoming,
      receptions: [reception("obs", routes: [route(["AA"], snr: 2.0)])],
      observers: [observer("obs")],
      repeaters: [a]
    )
    #expect(!unknown.nodes.contains { $0.point.pinStyle == .pointA })
    // No origin: no origin→A link and no body; the measured leg alone remains.
    #expect(unknown.links.map(\.id) == ["hop:\(hex(a))>obs:obs"])
    let built = try #require(unknown.routes.first)
    #expect(signature(built.segments) == signature([[a.coordinate2D, observerSite]]))
  }

  @Test
  func `A direct reception with no origin keeps the observer pin and draws nothing`() {
    let incoming = makeMessage(direction: .incoming)
    let map = build(
      message: incoming,
      receptions: [reception("obs", routes: [route([], snr: 2.0)])],
      observers: [observer("obs")]
    )
    #expect(map.nodes.map(\.point.pinStyle) == [.pointB])
    #expect(map.links.isEmpty)
    #expect(map.observerLegs.isEmpty)
    #expect(map.routes.count == 1)
    #expect(map.drawableRouteIDs.isEmpty)
    #expect(map.isPlottable)
  }

  @Test
  func `An unstamped outgoing message falls back to the live location for its origin`() throws {
    let map = build(
      message: makeMessage(stamped: false),
      receptions: [reception("obs", routes: [route([], snr: 1.0)])],
      observers: [observer("obs")],
      userLocation: CLLocation(latitude: 40.0, longitude: -74.0)
    )
    let pin = try #require(map.nodes.first)
    #expect(pin.point.pinStyle == .pointA)
    #expect(pin.coordinate.latitude == 40.0)
  }

  // MARK: - Focus geometry

  private func lineIDs(_ geometry: PacketScopeFocusGeometry) -> [String] {
    geometry.lines.map(\.id)
  }

  @Test
  func `Focusing what cannot be placed leaves the map exactly as it was, and does not move the camera`() {
    let a = makeRepeater(firstByte: 0xAA, latitude: 30.1, longitude: -97.1)
    let map = build(
      receptions: [
        reception("obs", routes: [route(["AA"], snr: 7.5)]),
        reception("ghost", routes: [route(["ZZ"], snr: 2.0)]),
      ],
      observers: [observer("obs"), observer("ghost", located: false)],
      repeaters: [a]
    )
    #expect(map.routes.count == 2)
    #expect(map.drawableRouteIDs == ["obs|AA"])

    let everything = PacketScopeCoverageBuilder.geometry(for: .all, in: map)
    let ghostRoute = PacketScopeCoverageBuilder.geometry(for: .route(observerID: "ghost", routeID: "ghost|ZZ"), in: map)
    let ghost = PacketScopeCoverageBuilder.geometry(for: .observer("ghost"), in: map)
    for undrawable in [ghostRoute, ghost] {
      #expect(!undrawable.isDrawable)
      #expect(undrawable.cameraCoordinates.isEmpty)
      #expect(lineIDs(undrawable) == lineIDs(everything))
      #expect(undrawable.nodes.map(\.point) == everything.nodes.map(\.point))
      #expect(undrawable.focusLinkIDs == everything.focusLinkIDs)
    }
    #expect(everything.isDrawable)
    #expect(everything.cameraCoordinates.count == map.pinCoordinates.count)
  }

  @Test
  func `An unlocated observer with placed hops focuses as a body: framed to the origin and its hops, with its readout at the body's end`() throws {
    let a = makeRepeater(firstByte: 0xAA, latitude: 30.1, longitude: -97.1)
    let b = makeRepeater(firstByte: 0xBB, latitude: 30.2, longitude: -97.2)
    let map = build(
      receptions: [reception("obs", routes: [route(["AA", "BB"], snr: 3.0)])],
      observers: [observer("obs", located: false)],
      repeaters: [a, b]
    )
    let focused = PacketScopeCoverageBuilder.geometry(for: .route(observerID: "obs", routeID: "obs|AA,BB"), in: map)
    #expect(focused.isDrawable)
    #expect(focused.lines.count == 1)
    #expect(focused.lines.allSatisfy { $0.style == .messagePath })
    #expect(signature(focused.cameraCoordinates.map { [$0] }) == signature([[origin], [a.coordinate2D], [b.coordinate2D]]))
    let badge = try #require(focused.nodes.first { $0.point.pinStyle == .badge })
    #expect(badge.point.badgeText == PacketScopeCoverageBuilder.decibels(3.0))
    #expect(abs(badge.coordinate.latitude - (a.latitude + b.latitude) / 2) < 1e-9)
    #expect(map.routeIDByBadgePinID[badge.point.id] == "obs|AA,BB")
  }

  @Test
  func `Routes that differ only in unplaceable tails draw the same pixels and say so`() {
    let a = makeRepeater(firstByte: 0xAA, latitude: 30.1, longitude: -97.1)
    let map = build(
      receptions: [reception("obs", routes: [route(["AA", "ZZ"], snr: 5.0), route(["AA", "ZZ", "YY"], snr: -2.0)])],
      observers: [observer("obs", located: false)],
      repeaters: [a]
    )
    let routes = map.routes
    #expect(routes.count == 2)
    #expect(routes[0].drawnGeometryKey == routes[1].drawnGeometryKey)
    #expect(Set(routes.map(\.unplacedTailCount)) == [1, 2])
    #expect(routes.allSatisfy { !$0.isComplete })
  }

  @Test
  func `Routes with a measured leg that differ only in an unplaceable middle hop share a key, and a different path does not`() throws {
    let a = makeRepeater(firstByte: 0xAA, latitude: 30.1, longitude: -97.1)
    let b = makeRepeater(firstByte: 0xBB, latitude: 30.2, longitude: -97.2)
    let c = makeRepeater(firstByte: 0xCC, latitude: 30.3, longitude: -97.3)
    let map = build(
      receptions: [reception("obs", routes: [
        route(["AA", "ZZ", "BB"], snr: 5.0),
        route(["AA", "YY", "BB"], snr: -2.0),
        route(["CC", "BB"], snr: 1.0),
      ])],
      observers: [observer("obs")],
      repeaters: [a, b, c]
    )
    let twinA = try #require(map.routesByID["obs|AA,ZZ,BB"])
    let twinB = try #require(map.routesByID["obs|AA,YY,BB"])
    let other = try #require(map.routesByID["obs|CC,BB"])
    // Both legs into B fan apart in observer focus, but route focus draws
    // them straight — and that is the geometry the key must describe.
    #expect(twinA.hasMeasuredLeg && twinB.hasMeasuredLeg)
    #expect(twinA.drawnGeometryKey == twinB.drawnGeometryKey)
    #expect(other.drawnGeometryKey != twinA.drawnGeometryKey)
    #expect(other.isComplete)
    #expect(!twinA.isComplete)
  }

  @Test
  func `Observer focus keeps a readout when the headline route has no measured leg`() throws {
    let a = makeRepeater(firstByte: 0xAA, latitude: 30.1, longitude: -97.1)
    let b = makeRepeater(firstByte: 0xBB, latitude: 30.2, longitude: -97.2)
    let map = build(
      receptions: [reception("obs", routes: [
        route(["AA", "ZZ"], snr: 13.8),
        route(["BB", "YY", "XX"], snr: 4.1),
      ])],
      observers: [observer("obs")],
      repeaters: [a, b]
    )
    let focused = PacketScopeCoverageBuilder.geometry(for: .observer("obs"), in: map)
    let badge = try #require(focused.nodes.first { $0.point.pinStyle == .badge })
    // The headline is the shortest route; its readout sits at its body's end,
    // since its leg cannot draw past the unplaceable tail.
    #expect(badge.point.badgeText == PacketScopeCoverageBuilder.decibels(13.8))
    #expect(map.routeIDByBadgePinID[badge.point.id] == "obs|AA,ZZ")
  }

  /// The ranking that picks an observer's headline route, and the fan order on
  /// the map, leads on hops rather than on signal: every SNR here is measured
  /// at the observer on its last leg, so ranking a longer route first for its
  /// stronger number ranks a repeater's link to that observer above the
  /// sender's own.
  @Test
  func `A shorter route outranks a louder longer one`() throws {
    let a = makeRepeater(firstByte: 0xAA, latitude: 30.1, longitude: -97.1)
    let b = makeRepeater(firstByte: 0xBB, latitude: 30.2, longitude: -97.2)
    let map = build(
      receptions: [reception("obs", routes: [
        route(["AA", "BB"], snr: 13.8),
        route(["BB"], snr: 4.1),
      ])],
      observers: [observer("obs")],
      repeaters: [a, b]
    )
    #expect(map.routeIDsByObserver["obs"]?.first == "obs|BB")
  }

  @Test
  func `Route focus draws only that route, and its links are the exact complement of the context`() throws {
    let a = makeRepeater(firstByte: 0xAA, latitude: 30.1, longitude: -97.1)
    let b = makeRepeater(firstByte: 0xBB, latitude: 30.2, longitude: -97.2)
    let c = makeRepeater(firstByte: 0xCC, latitude: 30.3, longitude: -97.3)
    let far = CLLocationCoordinate2D(latitude: 30.9, longitude: -97.9)
    let map = build(
      receptions: [
        reception("one", routes: [route(["AA", "BB"], snr: 5), route(["AA", "CC"], snr: 3)]),
        reception("two", routes: [route(["AA", "BB"], snr: 2)]),
      ],
      observers: [observer("one"), observer("two", at: far)],
      repeaters: [a, b, c]
    )
    let focused = PacketScopeCoverageBuilder.geometry(for: .route(observerID: "one", routeID: "one|AA,BB"), in: map)
    let route = try #require(map.routesByID["one|AA,BB"])
    #expect(lineIDs(focused) == route.soloSegments.map(\.id))
    #expect(focused.routeIDs == ["one|AA,BB"])
    #expect(focused.focusLinkIDs == route.linkIDs)
    #expect(focused.focusLinkIDs == ["origin>hop:\(hex(a))", "hop:\(hex(a))>hop:\(hex(b))", "hop:\(hex(b))>obs:one"])
    let everyLink = Set(map.links.map(\.id))
    let context = everyLink.subtracting(focused.focusLinkIDs)
    #expect(context.isDisjoint(with: focused.focusLinkIDs))
    #expect(context.union(focused.focusLinkIDs) == everyLink)
    #expect(context == ["hop:\(hex(a))>hop:\(hex(c))", "hop:\(hex(c))>obs:one", "hop:\(hex(b))>obs:two"])
    // Nothing is emitted dimmed.
    #expect(focused.lines.allSatisfy { $0.opacity == 1 })
  }

  @Test
  func `Route focus numbers placed hops by their true path positions, leaving a gap for an unplaced one`() {
    let a = makeRepeater(firstByte: 0xAA, latitude: 30.1, longitude: -97.1)
    let b = makeRepeater(firstByte: 0xBB, latitude: 30.2, longitude: -97.2)
    let map = build(
      receptions: [reception("obs", routes: [route(["AA"], snr: 4), route(["BB", "ZZ", "AA"], snr: 1)])],
      observers: [observer("obs")],
      repeaters: [a, b]
    )
    func number(_ geometry: PacketScopeFocusGeometry, _ name: String) -> Int? {
      geometry.nodes.first { $0.point.label == name }?.point.hopIndex
    }
    func style(_ geometry: PacketScopeFocusGeometry, _ name: String) -> MapPoint.PinStyle? {
      geometry.nodes.first { $0.point.label == name }?.point.pinStyle
    }
    let short = PacketScopeCoverageBuilder.geometry(for: .route(observerID: "obs", routeID: "obs|AA"), in: map)
    #expect(number(short, a.resolvableName) == 1)
    #expect(style(short, a.resolvableName) == .repeaterRingWhite)
    // B is recessed and unlabelled in this focus, so it cannot be found by name.
    #expect(short.nodes.contains { $0.point.id == PacketScopeCoverageBuilder.stableID("hop:\(hex(b))") && $0.point.label == nil })

    let long = PacketScopeCoverageBuilder.geometry(for: .route(observerID: "obs", routeID: "obs|BB,ZZ,AA"), in: map)
    #expect(number(long, b.resolvableName) == 1)
    #expect(number(long, a.resolvableName) == 3)
    // With one drawable route the observer focus numbers the same way; with
    // two, positions conflict and the pins stay plain.
    let both = PacketScopeCoverageBuilder.geometry(for: .observer("obs"), in: map)
    #expect(number(both, a.resolvableName) == nil)
    #expect(style(both, a.resolvableName) == .repeaterHop)
  }

  @Test
  func `Single-route focus draws the measured leg straight, with its readout at the chord midpoint`() throws {
    let a = makeRepeater(firstByte: 0xAA, latitude: 30.1, longitude: -97.1)
    let b = makeRepeater(firstByte: 0xBB, latitude: 30.2, longitude: -97.2)
    let c = makeRepeater(firstByte: 0xCC, latitude: 30.3, longitude: -97.3)
    let map = build(
      receptions: [reception("obs", routes: [route(["AA", "BB"], snr: 5.0), route(["CC", "BB"], snr: 6.0)])],
      observers: [observer("obs")],
      repeaters: [a, b, c]
    )
    let focused = PacketScopeCoverageBuilder.geometry(for: .route(observerID: "obs", routeID: "obs|AA,BB"), in: map)
    let leg = try #require(focused.lines.last)
    #expect(leg.coordinates.count == 2)
    #expect(leg.style == .forSNR(5.0))
    let badge = try #require(focused.nodes.first { $0.point.pinStyle == .badge })
    #expect(abs(badge.coordinate.latitude - (b.latitude + observerSite.latitude) / 2) < 1e-9)
    #expect(abs(badge.coordinate.longitude - (b.longitude + observerSite.longitude) / 2) < 1e-9)
    // Observer focus keeps the fan, and exactly one badge: the best route's.
    let fanned = PacketScopeCoverageBuilder.geometry(for: .observer("obs"), in: map)
    #expect(fanned.lines.count == 4)
    #expect(fanned.nodes.filter { $0.point.pinStyle == .badge }.count == 1)
    #expect(try map.routeIDByBadgePinID[#require(fanned.nodes.first { $0.point.pinStyle == .badge }).point.id] == "obs|CC,BB")
  }

  @Test
  func `Emphasis is two-valued in every focus state`() {
    let a = makeRepeater(firstByte: 0xAA, latitude: 30.1, longitude: -97.1)
    let b = makeRepeater(firstByte: 0xBB, latitude: 30.2, longitude: -97.2)
    let map = build(
      receptions: [
        reception("one", routes: [route(["AA"], snr: 5), route(["BB"], snr: 3)]),
        reception("two", routes: [route([], snr: 2)]),
      ],
      observers: [observer("one"), observer("two", at: CLLocationCoordinate2D(latitude: 30.9, longitude: -97.9))],
      repeaters: [a, b]
    )
    let states: [PacketScopeFocus] = [.all, .observer("one"), .route(observerID: "one", routeID: "one|AA"), .route(observerID: "two", routeID: "two|")]
    for state in states {
      let geometry = PacketScopeCoverageBuilder.geometry(for: state, in: map)
      #expect(geometry.nodes.allSatisfy { $0.point.emphasis == 1 || $0.point.emphasis == MapPoint.recessedEmphasis })
    }
    let focused = PacketScopeCoverageBuilder.geometry(for: .route(observerID: "one", routeID: "one|AA"), in: map)
    #expect(focused.nodes.contains { $0.point.emphasis == MapPoint.recessedEmphasis && $0.point.label == nil })
    #expect(focused.nodes.first { $0.point.pinStyle == .pointA }?.point.emphasis == 1)
  }

  @Test
  func `Arrival is not baked into geometry: every leg comes back whole, with its arrival key`() {
    let a = makeRepeater(firstByte: 0xAA, latitude: 30.1, longitude: -97.1)
    let map = build(
      receptions: [reception("obs", routes: [route(["AA"], snr: 5)])],
      observers: [observer("obs")],
      repeaters: [a]
    )
    let everything = PacketScopeCoverageBuilder.geometry(for: .all, in: map)
    #expect(everything.lines.map(\.id) == map.observerLegs.map(\.line.id))
    #expect(everything.lines.allSatisfy { $0.coordinates.count == 2 })
    #expect(everything.arrivalKeyByLineID == ["scope-leg-obs": "leg:obs"])
    let focused = PacketScopeCoverageBuilder.geometry(for: .route(observerID: "obs", routeID: "obs|AA"), in: map)
    #expect(focused.arrivalKeyByLineID == ["scope-obs|AA-rx-solo": "leg:obs"])
  }

  @Test
  func `Every focus index keys on the observer id as the receptions carry it`() throws {
    let a = makeRepeater(firstByte: 0xAA, latitude: 30.1, longitude: -97.1)
    let map = build(
      receptions: [reception("ABCDEF", routes: [route(["AA"], snr: 1.0)])],
      observers: [observer("abcdef")],
      repeaters: [a]
    )
    #expect(map.routeIDsByObserver["ABCDEF"] == ["ABCDEF|AA"])
    #expect(map.observerCoordinates["ABCDEF"] != nil)
    #expect(map.drawableObserverIDs == ["ABCDEF"])
    let pin = try #require(map.nodes.first { $0.point.pinStyle == .pointB })
    #expect(map.observerIDByPinID[pin.point.id] == "ABCDEF")
    let focused = PacketScopeCoverageBuilder.geometry(for: .observer("ABCDEF"), in: map)
    #expect(focused.isDrawable)
  }

  // MARK: - Partial draws

  @Test
  func `A partial draw keeps whole segments before the cut and shortens the one it lands in`() throws {
    let a = CLLocationCoordinate2D(latitude: 30.0, longitude: -97.0)
    let b = CLLocationCoordinate2D(latitude: 30.0, longitude: -97.1)
    let c = CLLocationCoordinate2D(latitude: 30.0, longitude: -97.2)
    let segments = [
      MapLine(id: "body", coordinates: [a, b], style: .messagePath, opacity: 1.0),
      MapLine(id: "rx", coordinates: [b, c], style: .traceGood, opacity: 1.0),
    ]

    #expect(PacketScopeCoverageBuilder.truncated(segments, toFraction: 0).isEmpty)
    #expect(signature(PacketScopeCoverageBuilder.truncated(segments, toFraction: 1)) == signature(segments))

    let quarter = PacketScopeCoverageBuilder.truncated(segments, toFraction: 0.25)
    #expect(quarter.count == 1)
    let cut = try #require(quarter.first)
    #expect(cut.id == "body")
    #expect(cut.coordinates.count == 2)
    #expect(abs(cut.coordinates[1].longitude - -97.05) < 0.0005)

    let threeQuarters = PacketScopeCoverageBuilder.truncated(segments, toFraction: 0.75)
    #expect(threeQuarters.count == 2)
    #expect(threeQuarters[1].style == .traceGood)
    #expect(try abs(#require(threeQuarters[1].coordinates.last?.longitude) - -97.15) < 0.0005)
  }

  @Test
  func `A partial draw of an arc cuts inside the arc rather than dropping it`() {
    let a = CLLocationCoordinate2D(latitude: 30.0, longitude: -97.0)
    let b = CLLocationCoordinate2D(latitude: 30.0, longitude: -97.1)
    let arc = MessagePathMapView.legArcCoordinates(from: a, to: b, offsetStep: 1)
    let segments = [MapLine(id: "rx", coordinates: arc, style: .traceGood, opacity: 1.0)]
    let half = PacketScopeCoverageBuilder.truncated(segments, toFraction: 0.5)
    #expect(half.count == 1)
    let kept = half[0].coordinates.count
    #expect(kept > 2 && kept < arc.count)
  }
}

private extension ContactDTO {
  var coordinate2D: CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  }
}

/// Lowercase hex of a repeater's key, as the builder's link ids carry it.
private func hex(_ contact: ContactDTO) -> String {
  contact.publicKey.map { String(format: "%02x", $0) }.joined()
}
