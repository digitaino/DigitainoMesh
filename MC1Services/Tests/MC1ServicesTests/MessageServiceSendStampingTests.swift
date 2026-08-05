import Foundation
@testable import MC1Services
import Testing

/// Send-time location stamping: outgoing rows carry the phone's fix through
/// the same `stampableFix` gate ingest uses — fresh and valid, or nothing.
@Suite("MessageService send-time location stamping")
struct MessageServiceSendStampingTests {
  private struct FixedPhoneLocationProvider: PhoneLocationProvider {
    let fix: PhoneLocationFix?
    func currentFix() async -> PhoneLocationFix? { fix }
  }

  private func makeService(provider: PhoneLocationProvider?) throws -> (service: MessageService, store: PersistenceStore) {
    let container = try PersistenceStore.createContainer(inMemory: true)
    let store = PersistenceStore(modelContainer: container)
    let service = MessageService(
      session: MockMeshCoreSession(),
      dataStore: store,
      contactService: nil,
      phoneLocationProvider: provider
    )
    return (service, store)
  }

  @Test
  func `A fresh fix stamps the pending channel message and persists`() async throws {
    let fix = PhoneLocationFix(latitude: 30.2672, longitude: -97.7431, timestamp: Date())
    let (service, store) = try makeService(provider: FixedPhoneLocationProvider(fix: fix))
    let radioID = UUID()

    let dto = try await service.createPendingChannelMessage(
      text: "hello",
      channelIndex: 0,
      radioID: radioID
    )

    #expect(dto.userLatitude == 30.2672)
    #expect(dto.userLongitude == -97.7431)

    // The stamp must survive `Message(dto:)` into the store — the map reads
    // the row, not the returned DTO.
    let saved = try await store.fetchMessages(radioID: radioID, channelIndex: 0)
    #expect(saved.first?.userLatitude == 30.2672)
    #expect(saved.first?.userLongitude == -97.7431)
  }

  @Test
  func `An aged fix never stamps a send`() async throws {
    let aged = Date().addingTimeInterval(-(NodeLocationStalenessPolicy.maxFixAge + 60))
    let fix = PhoneLocationFix(latitude: 30.2672, longitude: -97.7431, timestamp: aged)
    let (service, _) = try makeService(provider: FixedPhoneLocationProvider(fix: fix))

    let dto = try await service.createPendingChannelMessage(
      text: "hello",
      channelIndex: 0,
      radioID: UUID()
    )

    #expect(dto.userLatitude == nil)
    #expect(dto.userLongitude == nil)
  }

  @Test
  func `A fresh null-island fix never stamps a send`() async throws {
    let fix = PhoneLocationFix(latitude: 0, longitude: 0, timestamp: Date())
    let (service, _) = try makeService(provider: FixedPhoneLocationProvider(fix: fix))

    let dto = try await service.createPendingChannelMessage(
      text: "hello",
      channelIndex: 0,
      radioID: UUID()
    )

    #expect(dto.userLatitude == nil)
    #expect(dto.userLongitude == nil)
  }

  @Test
  func `No provider leaves the send unstamped`() async throws {
    let (service, _) = try makeService(provider: nil)

    let dto = try await service.createPendingChannelMessage(
      text: "hello",
      channelIndex: 0,
      radioID: UUID()
    )

    #expect(dto.userLatitude == nil)
    #expect(dto.userLongitude == nil)
  }
}
