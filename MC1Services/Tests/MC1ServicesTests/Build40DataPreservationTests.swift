import Foundation
@testable import MC1Services
import SwiftData
import Testing

/// Guards the schema surface that exists purely so a Build 40 store survives the in-place
/// update to v2. Nothing in the app reads any of it, so nothing else would notice if a
/// tidy-up pass deleted a model or a column — and by the time a user noticed, their rows
/// would already have been dropped by lightweight migration. These tests are the tripwire.
@Suite("Build 40 data preservation")
struct Build40DataPreservationTests {
  private func entity(_ name: String) throws -> Schema.Entity {
    try #require(PersistenceStore.schema.entities.first { $0.name == name }, "\(name) is not registered in PersistenceStore.schema")
  }

  private func propertyNames(of entityName: String) throws -> Set<String> {
    try Set(entity(entityName).properties.map(\.name))
  }

  // MARK: - Dormant survey entities

  @Test
  func `Survey entities stay registered in the shared schema`() {
    let names = Set(PersistenceStore.schema.entities.map(\.name))
    #expect(names.contains("SurveySession"))
    #expect(names.contains("SignalSurveyPoint"))
  }

  @Test
  func `SurveySession keeps every Build 40 stored property`() throws {
    // Build 40 stored `deviceID`; v2 reaches it through the same
    // `@Attribute(originalName:)` rename the other nine migrated entities use.
    let expected: Set = [
      "id", "radioID", "startedAt", "endedAt", "name", "probesSentData", "completionStatsData"
    ]
    #expect(try propertyNames(of: "SurveySession") == expected)
  }

  @Test
  func `SignalSurveyPoint keeps every Build 40 stored property`() throws {
    let expected: Set = [
      "id", "radioID", "surveySessionID", "timestamp",
      "latitude", "longitude", "altitude", "horizontalAccuracy", "speed",
      "snr", "txSnr", "rssi",
      "routeType", "payloadType", "pathLength",
      "packetHash", "fromContactName", "pathNodeHexIDs", "isActiveProbe"
    ]
    #expect(try propertyNames(of: "SignalSurveyPoint") == expected)
  }

  @Test
  func `Survey rows round-trip through a container built from the shared schema`() throws {
    let container = try PersistenceStore.createContainer(inMemory: true)
    let context = ModelContext(container)
    let radioID = UUID()
    let sessionID = UUID()

    let session = SurveySession(
      id: sessionID,
      radioID: radioID,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000),
      name: "Ridge run",
      probesSentData: Data([0x7B, 0x7D])
    )
    context.insert(session)

    let point = SignalSurveyPoint(
      radioID: radioID,
      surveySessionID: sessionID,
      latitude: 43.77,
      longitude: 11.25,
      horizontalAccuracy: 4.5,
      snr: 7.25,
      routeType: 1,
      payloadType: 2,
      pathLength: 3,
      packetHash: "deadbeef",
      pathNodeHexIDs: "a1,b2",
      isActiveProbe: true
    )
    context.insert(point)
    try context.save()

    let sessions = try context.fetch(FetchDescriptor<SurveySession>())
    #expect(sessions.count == 1)
    #expect(sessions.first?.radioID == radioID)
    #expect(sessions.first?.endedAt == nil)

    let points = try context.fetch(FetchDescriptor<SignalSurveyPoint>())
    #expect(points.count == 1)
    // The link between the two entities is a scalar id in Build 40, not a relationship.
    #expect(points.first?.surveySessionID == sessionID)
    #expect(points.first?.isActiveProbe == true)
    #expect(points.first?.pathNodeHexIDs == "a1,b2")
  }

  // MARK: - Dormant fork-only columns

  @Test
  func `Fork-only columns stay declared on their entities`() throws {
    let message = try propertyNames(of: "Message")
    #expect(message.isSuperset(of: ["userLatitude", "userLongitude", "txPowerDbm"]))
    #expect(try propertyNames(of: "Reaction").contains("sentMessageID"))
    #expect(try propertyNames(of: "TracePathRun").contains("note"))
  }

  @Test
  func `Fork-only column values round-trip`() throws {
    let container = try PersistenceStore.createContainer(inMemory: true)
    let context = ModelContext(container)
    let radioID = UUID()

    let message = Message(radioID: radioID, text: "hi")
    message.userLatitude = 43.7696
    message.userLongitude = 11.2558
    message.txPowerDbm = -3
    context.insert(message)

    let sentMessageID = UUID()
    let reaction = Reaction(
      messageID: message.id,
      emoji: "👍",
      senderName: "Node",
      messageHash: "0011aabb",
      rawText: "👍",
      radioID: radioID
    )
    reaction.sentMessageID = sentMessageID
    context.insert(reaction)

    let run = TracePathRun(success: true, roundTripMs: 120, hopsData: Data())
    run.note = "stock whip antenna"
    context.insert(run)
    try context.save()

    let messages = try context.fetch(FetchDescriptor<Message>())
    #expect(messages.first?.userLatitude == 43.7696)
    #expect(messages.first?.userLongitude == 11.2558)
    #expect(messages.first?.txPowerDbm == -3)

    let reactions = try context.fetch(FetchDescriptor<Reaction>())
    #expect(reactions.first?.sentMessageID == sentMessageID)

    let runs = try context.fetch(FetchDescriptor<TracePathRun>())
    #expect(runs.first?.note == "stock whip antenna")
  }

  @Test
  func `Dormant txPowerDbm stays absent from the backup DTOs`() throws {
    // The DTOs are the backup wire format. txPowerDbm still carries no behaviour, so
    // it deliberately stays out — adding a field would change every exported archive.
    // (userLatitude/userLongitude were revived for receive-time stamping and now ride
    // the DTO on purpose; see the round-trip test below.)
    let message = Message(radioID: UUID(), text: "hi")
    message.txPowerDbm = -3
    let dto = MessageDTO(from: message)
    let encoded = try JSONEncoder().encode(dto)
    let json = try #require(String(data: encoded, encoding: .utf8))
    #expect(!json.contains("txPowerDbm"))
  }

  @Test
  func `Revived location stamp rides the backup DTO and legacy envelopes decode nil`() throws {
    // Stamped rows: the fix must survive export → import, or a restore would strip
    // every receiver pin the path map has learned.
    let stamped = Message(radioID: UUID(), text: "hi")
    stamped.userLatitude = 30.2672
    stamped.userLongitude = -97.7431
    let stampedDTO = MessageDTO(from: stamped)
    #expect(stampedDTO.userLatitude == 30.2672)
    #expect(stampedDTO.userLongitude == -97.7431)
    let roundTripped = try JSONDecoder().decode(MessageDTO.self, from: JSONEncoder().encode(stampedDTO))
    #expect(roundTripped.userLatitude == 30.2672)
    #expect(roundTripped.userLongitude == -97.7431)

    // Unstamped rows encode without the keys (synthesized encoding omits nil),
    // which doubles as the legacy-envelope shape: decoding it must yield nil,
    // not a decode failure — archives predating the stamp have no such keys.
    let legacy = Message(radioID: UUID(), text: "hi")
    let legacyData = try JSONEncoder().encode(MessageDTO(from: legacy))
    let legacyJSON = try #require(String(data: legacyData, encoding: .utf8))
    #expect(!legacyJSON.contains("userLatitude"))
    let decoded = try JSONDecoder().decode(MessageDTO.self, from: legacyData)
    #expect(decoded.userLatitude == nil)
    #expect(decoded.userLongitude == nil)
  }

  @Test
  func `userFixCoordinate rejects null-island and partial stamps`() {
    // Build 40 stamped without v2's gates, so a migrated store can hold junk;
    // the read-side helper is the last line of defence for the receiver pin.
    let stamped = Message(radioID: UUID(), text: "hi")
    stamped.userLatitude = 30.2672
    stamped.userLongitude = -97.7431
    #expect(MessageDTO(from: stamped).userFixCoordinate?.latitude == 30.2672)

    let nullIsland = Message(radioID: UUID(), text: "hi")
    nullIsland.userLatitude = 0
    nullIsland.userLongitude = 0
    #expect(MessageDTO(from: nullIsland).userFixCoordinate == nil)

    let partial = Message(radioID: UUID(), text: "hi")
    partial.userLatitude = 30.2672
    #expect(MessageDTO(from: partial).userFixCoordinate == nil)

    #expect(MessageDTO(from: Message(radioID: UUID(), text: "hi")).userFixCoordinate == nil)
  }
}
