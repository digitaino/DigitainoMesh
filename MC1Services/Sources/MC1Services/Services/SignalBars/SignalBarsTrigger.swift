import Foundation
import MeshCore

/// The two-byte command the app writes to the signal-bars sync slot to make the radio
/// measure something.
///
/// ``SyncID/signalBars`` is asymmetric: reading it returns the device's serialized table
/// (``SignalBarsBlob``), while writing it is a *trigger*, not a stored blob. The firmware
/// reads exactly two bytes:
///
/// ```text
/// [action][target_key]
/// ```
///
/// - `action`: ``Action`` — refresh every entry, ping one entry, or run a discovery scan.
/// - `target_key`: the **first byte** of the target's hash, which is the key the firmware
///   matches its `_signals[]` table on. Zero when the action has no target.
///
/// Radios in the field speak this exact contract; the byte layout is fixed and covered by
/// byte-exact tests.
public struct SignalBarsTrigger: Sendable, Equatable {
  /// What the radio should do. Raw values are the firmware's action codes.
  public enum Action: UInt8, Sendable, Equatable {
    /// Re-measure every repeater the device is tracking.
    case refreshAll = 0
    /// Ping one repeater, identified by ``SignalBarsTrigger/targetKey``.
    case pingTarget = 1
    /// Run a discovery scan; the device's auto-ping then measures whatever it finds.
    case discoveryProbe = 2
  }

  public let action: Action
  /// First hash byte of the target repeater, or `0` when the action targets everything.
  public let targetKey: UInt8

  public init(action: Action, targetKey: UInt8 = 0) {
    self.action = action
    self.targetKey = targetKey
  }

  /// The exact bytes written to ``SyncID/signalBars``.
  public var payload: Data {
    Data([action.rawValue, targetKey])
  }

  /// Re-measure every tracked repeater.
  public static let refreshAll = SignalBarsTrigger(action: .refreshAll)

  /// Run a discovery scan.
  public static let discoveryProbe = SignalBarsTrigger(action: .discoveryProbe)

  /// Ping a single repeater. Only the first hash byte travels — that is all the firmware
  /// matches on, however wide the hash the app happens to be displaying.
  public static func ping(_ id: NodeHexID) -> SignalBarsTrigger {
    SignalBarsTrigger(action: .pingTarget, targetKey: id.bytes[0])
  }

  /// Ping `id` when one is given, otherwise refresh everything — the shape
  /// ``SignalBarsEngine/requestRefresh(target:)`` needs.
  public static func refresh(target id: NodeHexID?) -> SignalBarsTrigger {
    id.map(ping) ?? .refreshAll
  }
}
