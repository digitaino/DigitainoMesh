import Foundation
import SurveyKit

extension SignalSurveyPointDTO {

    /// The SurveyKit aggregation form of this point — the one mapping used by live
    /// upload, batch upload, and (eventually) display, so they can't classify the
    /// same packet differently.
    public var surveySample: SurveySample {
        // TX SNR comes from discover/trace responses and describes the repeater that
        // answered; only attribute it when the path names exactly one repeater.
        let attributeTxSnr = pathNodeHexIDs.count == 1 ? txSnr : nil
        return SurveySample(
            timestamp: timestamp,
            coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
            snr: snr,
            txSnr: txSnr,
            rssi: rssi.map(Double.init),
            route: routeType == .direct ? .direct : .flood,
            isActiveProbe: isActiveProbe,
            hopCount: hopCount,
            repeaters: pathNodeHexIDs.map { hexID in
                SurveySample.RepeaterSighting(
                    id: hexID.uppercased(),
                    rxSnr: attributeTxSnr == nil ? snr : nil,
                    txSnr: attributeTxSnr,
                    rssi: rssi.map(Double.init)
                )
            }
        )
    }
}
