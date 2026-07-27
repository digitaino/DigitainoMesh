import Foundation
import MeshCore
import os

/// The two sync-registry operations the capability probe and the motion hint need.
///
/// Narrow on purpose, in the idiom ``SignalBarsSessionOps`` established: depending on the
/// whole of `ConfigurationSessionOps` would drag dozens of unrelated radio commands into
/// every test double for the sake of two calls.
public protocol SyncRegistrySessionOps: Actor {
  /// Lists the registry slots the device knows about. Stock firmware rejects the opcode,
  /// which is the capability signal.
  func listSync() async throws -> [SyncListEntry]

  /// Writes one registry slot.
  func setSync(_ id: SyncID, payload: Data) async throws
}

extension MeshCoreSession: SyncRegistrySessionOps {}

/// Discovers which sync-registry slots the connected radio implements.
///
/// The registry (``SyncID``) is a Digitaino custom-firmware feature. Stock firmware answers
/// `listSync` with a device error, and *that rejection is the capability probe* — there is no
/// version flag to read. Two features depend on the answer:
///
/// - **Signal bars** run in viewer mode when the radio advertises ``SyncID/signalBars`` (the
///   radio owns the measurement table and the app only mirrors it), and in engine mode
///   otherwise (the app measures for itself).
/// - **The motion hint** is only pushed when ``SyncID/motionHint`` is advertised.
///
/// ## Latching
///
/// Classification follows the pattern ``NotifSyncService`` established: a device error latches
/// ``FirmwareSupport/unsupported`` and every later call answers from the latch without touching
/// the radio, while a timeout or transport failure leaves the classification at
/// ``FirmwareSupport/unknown`` so a flaky link cannot permanently downgrade a capable radio.
/// The probe is per-connection (it lives on `ServiceContainer`), so "retry on the next connect"
/// costs nothing: a fresh container starts back at `.unknown`.
public actor SyncRegistryProbe {
  /// Whether the connected device implements the sync registry.
  public enum FirmwareSupport: Sendable, Equatable {
    /// Not yet probed, or the last probe was inconclusive. The next call probes again.
    case unknown
    /// The device answered `listSync`.
    case supported
    /// The device rejected the opcode. Answered from the latch from here on.
    case unsupported
  }

  private let session: any SyncRegistrySessionOps
  private let logger = Logger(subsystem: "com.mc1", category: "SyncRegistry")

  /// The device's classification for this connection.
  public private(set) var support: FirmwareSupport = .unknown

  /// The raw slot ids the device advertised, empty until a successful probe.
  public private(set) var advertisedSlots: Set<UInt8> = []

  public init(session: any SyncRegistrySessionOps) {
    self.session = session
  }

  // MARK: - Probing

  /// Classifies the device, reusing a latched answer when there is one.
  ///
  /// - Returns: The classification. ``FirmwareSupport/unknown`` means the probe was
  ///   inconclusive (timeout, transport error) and the caller should treat the registry as
  ///   absent for now but may probe again later.
  @discardableResult
  public func probe() async -> FirmwareSupport {
    guard support == .unknown else { return support }

    do {
      let entries = try await session.listSync()
      advertisedSlots = Set(entries.map(\.id))
      support = .supported
      logger.info("Sync registry supported; slots \(self.advertisedSlots.sorted())")
    } catch let error as MeshCoreError where isRejection(error) {
      advertisedSlots = []
      support = .unsupported
      logger.info("Device rejected listSync; no sync registry on this firmware")
    } catch {
      // Timeout or transport failure: inconclusive, so nothing latches.
      logger.warning("listSync inconclusive: \(error.localizedDescription)")
    }
    return support
  }

  /// Whether the device advertised a given slot. Answers `false` until a successful probe.
  public func supportsSlot(_ id: SyncID) -> Bool {
    support == .supported && advertisedSlots.contains(id.rawValue)
  }

  /// The signal-bars mode this device calls for.
  ///
  /// Viewer mode only when the radio actually advertises the slot; everything else — stock
  /// firmware, custom firmware built without the feature, or an inconclusive probe — runs the
  /// app's own engine, which works on any radio.
  public func signalBarsMode() async -> SignalBarsMode {
    await probe()
    return supportsSlot(.signalBars) ? .viewer : .engine
  }

  // MARK: - Helpers

  /// Whether the error is the device saying "I don't know this opcode" rather than a
  /// transport problem.
  private func isRejection(_ error: MeshCoreError) -> Bool {
    if case .deviceError = error { return true }
    return false
  }
}
