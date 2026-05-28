import Foundation
import MeshCore

/// Synchronizes iOS-side notification preferences (per-channel and per-contact
/// mute/level state) to the Digitaino custom firmware over the iOS sync
/// registry (``SyncID/notifPrefs``).
///
/// The firmware uses the synced rules to gate on-device beep/vibration alerts.
/// Call ``syncNow(deviceID:)`` after any user mute toggle or notification-level
/// change to push the updated rule set.
public actor NotifSyncService {

    private let session: MeshCoreSessionProtocol
    private let dataStore: PersistenceStoreProtocol

    public init(session: MeshCoreSessionProtocol, dataStore: PersistenceStoreProtocol) {
        self.session = session
        self.dataStore = dataStore
    }

    /// Gathers per-channel notification levels and per-contact mute state for
    /// the given device, encodes them as a ``NotifPrefsBlob``, and pushes the
    /// blob to the firmware via ``MeshCoreSession/setSync(_:payload:)``.
    ///
    /// Skips channels at the global default (`.all`) and contacts that aren't
    /// muted to keep the wire payload compact — firmware falls back to
    /// `globalMode` (also `.all`) for unmatched targets.
    public func syncNow(deviceID: UUID) async throws {
        let channels = try await dataStore.fetchChannels(deviceID: deviceID)
        let contacts = try await dataStore.fetchContacts(deviceID: deviceID)

        // Only emit overrides — anything matching `globalMode = .all` is implicit.
        let channelRules: [NotifPrefsBlob.ChannelRule] = channels
            .filter { $0.notificationLevel != .all }
            .map { channel in
                .init(channelIdx: channel.index,
                      mode: NotifPrefsBlob.firmwareMode(from: channel.notificationLevel))
            }

        // Contacts currently support only isMuted (boolean) — emit a .silent rule
        // for each muted contact. Unmuted contacts inherit globalMode.
        let contactRules: [NotifPrefsBlob.ContactRule] = contacts
            .filter { $0.isMuted }
            .map { contact in
                .init(pubKeyPrefix: contact.publicKey.prefix(6), mode: .silent)
            }

        let blob = NotifPrefsBlob(
            globalMode: .all,
            channelRules: channelRules,
            contactRules: contactRules
        )

        try await session.setSync(.notifPrefs, payload: blob.encode())
    }

    /// Fetches the firmware's current stored blob (for diagnostics / verification).
    public func currentDeviceBlob() async throws -> NotifPrefsBlob? {
        let raw = try await session.getSync(.notifPrefs)
        if raw.isEmpty { return nil }
        return NotifPrefsBlob(decoding: raw)
    }
}
