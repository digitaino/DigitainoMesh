import Foundation
import MeshCore
import os

/// Synchronizes iOS-side notification preferences (per-channel notification levels and
/// per-contact mute state) to Digitaino custom firmware over the sync registry slot
/// ``SyncID/notifPrefs``.
///
/// The firmware uses the synced rules to gate its own beep/vibration alerts, so the
/// device stays quiet for a muted conversation even while the phone is away. Call
/// ``syncNow(radioID:)`` after any notification-preference write, and
/// ``reconcileOnConnect(radioID:)`` once per connection.
///
/// ## Firmware gating
///
/// Stock firmware answers the sync opcodes with a device error. The first exchange
/// classifies the device into ``FirmwareSupport`` and a device error latches
/// ``FirmwareSupport/unsupported``, after which every entry point is inert — no packets,
/// no throwing, nothing for callers to gate on. Timeouts and transport failures leave the
/// classification at ``FirmwareSupport/unknown`` so a flaky link does not permanently
/// disable the feature.
public actor NotifSyncService {
  /// Whether the connected device implements the notification-prefs sync slot.
  public enum FirmwareSupport: Sendable, Equatable {
    /// Not yet probed. The next call probes and reclassifies.
    case unknown
    /// The device answered a sync-registry exchange.
    case supported
    /// The device rejected the opcode. Every entry point is inert from here on.
    case unsupported
  }

  private let session: any ConfigurationSessionOps
  private let dataStore: any ChannelPersisting & ContactPersisting
  private let logger = Logger(subsystem: "com.mc1", category: "NotifSync")

  /// The device's support classification for this connection.
  public private(set) var support: FirmwareSupport = .unknown

  /// The last blob successfully written to the device, used to skip redundant writes.
  /// A preference write that changes nothing on the wire (a room mute, a re-selection of
  /// the level already in force) must not cost a radio round-trip.
  public private(set) var lastPushedBlob: NotifPrefsBlob?

  public init(
    session: any ConfigurationSessionOps,
    dataStore: any ChannelPersisting & ContactPersisting
  ) {
    self.session = session
    self.dataStore = dataStore
  }

  // MARK: - Sync

  /// Builds the current rule set and pushes it, unless the device already has it.
  ///
  /// Inert on devices without the sync registry. Errors other than an unsupported-opcode
  /// rejection are rethrown so an explicit user action (the diagnostic screen's force
  /// resync) can report them; the fire-and-forget call sites ignore them.
  public func syncNow(radioID: UUID) async throws {
    guard support != .unsupported else { return }

    let blob = try await buildBlob(radioID: radioID)
    guard blob != lastPushedBlob else { return }

    do {
      try await session.setSync(.notifPrefs, payload: blob.encode())
      support = .supported
      lastPushedBlob = blob
      logger.info("Pushed notif prefs: \(blob.channelRules.count) channel, \(blob.contactRules.count) contact rules")
    } catch {
      if markUnsupportedIfRejected(error) { return }
      throw error
    }
  }

  /// Pulls the device's stored rules, then pushes the iOS-side set if it differs.
  ///
  /// Runs once per connection. The pull doubles as the support probe and as the seed for
  /// the redundant-write check, so a reconnect that changed nothing costs one read
  /// instead of a read and a write.
  public func reconcileOnConnect(radioID: UUID) async {
    guard support != .unsupported else { return }

    do {
      lastPushedBlob = try await deviceBlob()
    } catch {
      logger.warning("Could not read device notif prefs on connect: \(error.localizedDescription)")
      lastPushedBlob = nil
    }
    guard support != .unsupported else { return }

    do {
      try await syncNow(radioID: radioID)
    } catch {
      logger.warning("Notif prefs reconcile failed: \(error.localizedDescription)")
    }
  }

  // MARK: - Diagnostics

  /// Reads the rule set the device currently has stored.
  ///
  /// - Returns: The stored blob, or `nil` when the device has nothing stored or does not
  ///   support the sync registry.
  public func deviceBlob() async throws -> NotifPrefsBlob? {
    guard support != .unsupported else { return nil }

    do {
      let raw = try await session.getSync(.notifPrefs)
      support = .supported
      return raw.isEmpty ? nil : NotifPrefsBlob(decoding: raw)
    } catch {
      if markUnsupportedIfRejected(error) { return nil }
      throw error
    }
  }

  /// Encodes the current iOS-side preferences without touching the radio.
  ///
  /// Only overrides are emitted: a channel at `.all` and an unmuted contact both match
  /// the blob's `globalMode`, so leaving them out keeps the payload inside the firmware's
  /// 16-rule-per-list cap on realistic devices.
  ///
  /// Contacts carry a boolean `isMuted` rather than a level — the firmware's contact rule
  /// has no mentions slot — so a muted contact emits `.silent` and everything else
  /// inherits `.all`.
  public func buildBlob(radioID: UUID) async throws -> NotifPrefsBlob {
    let channels = try await dataStore.fetchChannels(radioID: radioID)
    let contacts = try await dataStore.fetchContacts(radioID: radioID)

    let channelRules: [NotifPrefsBlob.ChannelRule] = channels
      .filter { $0.notificationLevel != .all }
      .map { .init(channelIdx: $0.index, mode: NotifPrefsBlob.firmwareMode(from: $0.notificationLevel)) }

    let contactRules: [NotifPrefsBlob.ContactRule] = contacts
      .filter(\.isMuted)
      .map { .init(pubKeyPrefix: $0.publicKey.prefix(6), mode: .silent) }

    return NotifPrefsBlob(
      globalMode: .all,
      channelRules: channelRules,
      contactRules: contactRules
    )
  }

  // MARK: - Helpers

  /// Latches ``FirmwareSupport/unsupported`` when the device rejected the opcode.
  ///
  /// - Returns: `true` when the error was an opcode rejection and the caller should
  ///   swallow it, `false` when it was transient and should propagate.
  private func markUnsupportedIfRejected(_ error: Error) -> Bool {
    guard let meshError = error as? MeshCoreError, case .deviceError = meshError else { return false }
    support = .unsupported
    lastPushedBlob = nil
    logger.info("Device rejected the notif-prefs sync slot; disabling notification sync for this connection")
    return true
  }
}
