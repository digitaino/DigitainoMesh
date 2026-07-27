import Foundation
import MeshCore

/// The single radio operation the repeater benchmark transmits through.
///
/// A benchmark run is nothing but a sequence of trace probes, so this is deliberately one
/// method wide. `SignalBarsSessionOps` already carries `sendTrace`, but it also carries the
/// sync-slot and discover commands the benchmark has no use for; depending on it — or on
/// MeshCore's whole `DiagnosticsSessionOps` — would drag those into every test double for no
/// gain. Compose with `SessionEventStreaming` at the call site, the same idiom the
/// signal-bars engine uses, because the reply arrives as a `MeshEvent.traceData`.
public protocol BenchmarkSessionOps: Actor {
  /// Sends a trace probe along an explicit path. The reply comes back on the event stream
  /// tagged with `tag`, carrying the SNR every hop measured.
  func sendTrace(
    tag: UInt32?,
    authCode: UInt32?,
    flags: UInt8,
    path: Data?
  ) async throws -> MessageSentInfo
}

extension MeshCoreSession: BenchmarkSessionOps {}
