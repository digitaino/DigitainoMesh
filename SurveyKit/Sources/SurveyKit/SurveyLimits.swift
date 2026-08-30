import Foundation

/// Shared validation limits. The client pre-validates against the same numbers the
/// server enforces, so a payload that encodes locally can never bounce remotely for
/// limit reasons. Payload-shape validation returns with the wire v3 DTOs in M2
/// (docs/SIGNAL_MAPPER_V2.md §4); the physics and structural caps below are
/// wire-independent and mirrored in the server's fixtures.
public enum SurveyLimits {
  /// Max cells in one upload payload.
  public static let maxCellsPerUpload = 10000
  /// Max repeater observations per cell.
  public static let maxRepeatersPerCell = 100
  /// Max known-repeater entries per upload.
  public static let maxKnownRepeaters = 500
  /// Plausible SNR range in dB (LoRa physics; anything outside is junk or spoofed).
  public static let snrRange: ClosedRange<Double> = -30...30
  /// Plausible RSSI range in dBm.
  public static let rssiRange: ClosedRange<Double> = -160...0
  /// Max mesh hop count.
  public static let maxHopCount = 20
  /// Native resolutions accepted on upload (base ± the speed tiers).
  public static let acceptedResolutions = SurveyGrid.coarsestResolution...SurveyGrid.baseResolution
}
