import Foundation

/// Shared validation limits. The client pre-validates against the same numbers the
/// server enforces, so a payload that encodes locally can never bounce remotely for
/// limit reasons.
public enum SurveyLimits {
    /// Max cells in one upload payload.
    public static let maxCellsPerUpload = 10_000
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

    public enum ValidationError: Error, Equatable, Sendable {
        case tooManyCells(Int)
        case tooManyRepeaters(cellIndex: Int, count: Int)
        case invalidH3(cellIndex: Int, value: String)
        case unsupportedResolution(cellIndex: Int, resolution: Int)
        case implausibleSnr(cellIndex: Int, value: Double)
        case missingIdentity
    }

    /// Structural validation shared by client (pre-flight) and server (enforcement).
    public static func validate(_ payload: UploadV2Payload) -> ValidationError? {
        guard payload.cells.count <= maxCellsPerUpload else {
            return .tooManyCells(payload.cells.count)
        }
        // v2.2: anonymous uploads must carry a deletion receipt.
        if payload.contributor == nil, payload.receiptB64 == nil {
            return .missingIdentity
        }
        for (index, cell) in payload.cells.enumerated() {
            guard let h3 = H3Cell(string: cell.h3) else {
                return .invalidH3(cellIndex: index, value: cell.h3)
            }
            guard acceptedResolutions.contains(h3.resolution) else {
                return .unsupportedResolution(cellIndex: index, resolution: h3.resolution)
            }
            guard cell.repeaters.count <= maxRepeatersPerCell else {
                return .tooManyRepeaters(cellIndex: index, count: cell.repeaters.count)
            }
            for snr in [cell.snr.avg, cell.snr.min, cell.snr.max, cell.snr.txAvg] {
                if let snr, !snrRange.contains(snr) {
                    return .implausibleSnr(cellIndex: index, value: snr)
                }
            }
        }
        return nil
    }
}
