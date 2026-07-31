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
/// Stock firmware answers the sync opcodes with ``ErrorCode/unsupportedCommand``. The first
/// exchange classifies the device into ``FirmwareSupport`` and that rejection latches
/// ``FirmwareSupport/unsupported``, after which every entry point is inert — no packets, no
/// throwing, and ``SyncOutcome/unsupported`` for callers that want to report it. Every other
/// failure (timeouts, transport errors, and device errors that mean something else) leaves the
/// classification at ``FirmwareSupport/unknown`` so a flaky link, or a late error frame from an
/// unrelated command, cannot permanently disable the feature.
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

  /// What a push attempt did, for callers that report the result to the user.
  public enum SyncOutcome: Sendable, Equatable {
    /// The device acknowledged the write.
    case pushed
    /// The device already had this rule set, so nothing was sent.
    case unchanged
    /// The device does not implement the slot; nothing was sent and nothing will be.
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
  ///
  /// - Parameter force: Writes even when the rule set is unchanged. Used by the manual
  ///   resync action, where "nothing was sent" would read as a failure.
  /// - Returns: What the attempt did, so a rejection the service swallowed is still
  ///   distinguishable from a successful push.
  @discardableResult
  public func syncNow(radioID: UUID, force: Bool = false) async throws -> SyncOutcome {
    guard support != .unsupported else { return .unsupported }

    let blob = try await buildBlob(radioID: radioID)
    guard force || blob != lastPushedBlob else { return .unchanged }

    do {
      try await session.setSync(.notifPrefs, payload: blob.encode())
      support = .supported
      lastPushedBlob = blob
      logger.info("Pushed notif prefs: \(blob.channelRules.count) channel, \(blob.contactRules.count) contact rules")
      return .pushed
    } catch {
      if markUnsupportedIfRejected(error) { return .unsupported }
      // The device may have applied the write and only the acknowledgement was lost, so the
      // cache can no longer stand in for device state: drop it and let the next sync push
      // unconditionally rather than skip a revert as "unchanged".
      lastPushedBlob = nil
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
  /// - Throws: ``MeshCoreError/parseError(_:)`` when the slot holds bytes this build cannot
  ///   read (a newer schema version). That is unknown device state, not an unsupported
  ///   device: reporting it as an empty slot would claim the radio has no rules at all.
  public func deviceBlob() async throws -> NotifPrefsBlob? {
    guard support != .unsupported else { return nil }

    do {
      let raw = try await session.getSync(.notifPrefs)
      support = .supported
      guard !raw.isEmpty else { return nil }
      guard let blob = NotifPrefsBlob(decoding: raw) else {
        throw MeshCoreError.parseError("Unreadable notif-prefs blob (\(raw.count) bytes)")
      }
      return blob
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
  /// Past that cap the surplus is dropped *here* rather than in ``NotifPrefsBlob/encode()``:
  /// the returned blob is what gets cached as ``lastPushedBlob``, so it has to be equal to
  /// what the wire carries or the cache would claim rules the device never received. The
  /// rules that survive are the first of each list in the order the store returns them —
  /// channels by index, contacts by name — which is the order the UI shows.
  ///
  /// Contacts carry a boolean `isMuted` rather than a level — the firmware's contact rule
  /// has no mentions slot — so a muted contact emits `.silent` and everything else
  /// inherits `.all`.
  public func buildBlob(radioID: UUID) async throws -> NotifPrefsBlob {
    let channels = try await dataStore.fetchChannels(radioID: radioID)
    let contacts = try await dataStore.fetchContacts(radioID: radioID)

    let channelRules = Self.channelRules(from: channels)
    let contactRules = Self.contactRules(from: contacts)
    if channelRules.count > NotifPrefsBlob.maxChannelRules || contactRules.count > NotifPrefsBlob.maxContactRules {
      logger.warning("Notif prefs exceed the firmware cap: \(channelRules.count) channel, \(contactRules.count) contact rules")
    }

    return NotifPrefsBlob(
      globalMode: .all,
      channelRules: Array(channelRules.prefix(NotifPrefsBlob.maxChannelRules)),
      contactRules: Array(contactRules.prefix(NotifPrefsBlob.maxContactRules))
    )
  }

  /// The channel overrides a rule set carries, uncapped.
  ///
  /// Exposed so the diagnostics screen can compare what the preferences ask for against what
  /// ``buildBlob(radioID:)`` could fit, without restating the predicate.
  public static func channelRules(from channels: [ChannelDTO]) -> [NotifPrefsBlob.ChannelRule] {
    channels
      .filter { $0.notificationLevel != .all }
      .map { .init(channelIdx: $0.index, mode: NotifPrefsBlob.firmwareMode(from: $0.notificationLevel)) }
  }

  /// The contact overrides a rule set carries, uncapped.
  public static func contactRules(from contacts: [ContactDTO]) -> [NotifPrefsBlob.ContactRule] {
    contacts
      .filter(\.isMuted)
      .map { .init(pubKeyPrefix: $0.publicKey.prefix(6), mode: .silent) }
  }

  // MARK: - Helpers

  /// Latches ``FirmwareSupport/unsupported`` when the device rejected the *opcode*.
  ///
  /// Only ``ErrorCode/unsupportedCommand`` counts. The sync matchers turn every `.error`
  /// frame on the link into a device error, including a late one belonging to a command that
  /// already timed out, so latching on any code at all would disable the feature on a radio
  /// that supports it. Every other code means the firmware knows the opcode and refused this
  /// particular call, which is a transient failure the caller should see.
  ///
  /// - Returns: `true` when the error was an opcode rejection and the caller should
  ///   swallow it, `false` when it should propagate.
  private func markUnsupportedIfRejected(_ error: Error) -> Bool {
    guard let meshError = error as? MeshCoreError,
          meshError.deviceErrorCode == .unsupportedCommand else { return false }
    support = .unsupported
    lastPushedBlob = nil
    logger.info("Device rejected the notif-prefs sync slot; disabling notification sync for this connection")
    return true
  }
}
