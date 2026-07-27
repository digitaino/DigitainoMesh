import Foundation
import MeshCore

/// The narrow slice of the mesh session the signal-bars engine transmits through.
///
/// Four operations, all of them things this feature actually does: read and trigger the
/// signal-bars sync slot (viewer mode), send a trace probe, and ask the mesh which
/// repeaters are out there (engine mode). Depending on the whole of
/// `ConfigurationSessionOps` or `DiagnosticsSessionOps` would drag dozens of unrelated
/// commands into every test double.
///
/// Compose it with `SessionEventStreaming` at the call site — the idiom upstream services
/// use (`any AdvertisingSessionOps & SessionEventStreaming`).
public protocol SignalBarsSessionOps: Actor {
  /// Reads the device's serialized signal-bars table. Digitaino custom firmware only;
  /// stock firmware surfaces the unknown opcode as a device error, which is how the app
  /// discovers it must run its own engine.
  func getSync(_ id: SyncID) async throws -> Data

  /// Writes a sync registry slot. For ``SyncID/signalBars`` the payload is a
  /// ``SignalBarsTrigger``, not a stored blob.
  func setSync(_ id: SyncID, payload: Data) async throws

  /// Sends a trace probe; the reply carries the SNR the far end measured for us.
  func sendTrace(
    tag: UInt32?,
    authCode: UInt32?,
    flags: UInt8,
    path: Data?
  ) async throws -> MessageSentInfo

  /// Broadcasts a discover request so repeaters announce themselves with their full
  /// public keys — which is what makes them probeable.
  func sendNodeDiscoverRequest(
    filter: UInt8,
    prefixOnly: Bool,
    tag: UInt32?,
    since: Date?
  ) async throws -> UInt32
}

extension MeshCoreSession: SignalBarsSessionOps {}

/// Supplies the nodes a repeater hash can be resolved against.
///
/// Name resolution goes through ``NodeIdentityResolving``; this is only the candidate
/// pool, so the engine needs no persistence dependency and tests can hand it a literal
/// array. The app-side implementation reads saved contacts and discovered nodes.
public protocol SignalBarsNodeDirectory: Sendable {
  /// Contacts and discovered nodes that could answer to a repeater hash.
  func resolvableNodes() async -> [AnyResolvableNode]
}
