import MC1Services

/// Lightweight status published by SignalSurveyViewModel to AppState,
/// consumed by the floating survey indicator across the app.
struct SurveyLiveStatus: Equatable {
    /// Total survey points recorded in the current session.
    var pointCount: Int = 0

    /// Signal quality of the hex cell the user is currently located in.
    var currentCellQuality: SNRQuality = .unknown

    /// Number of packets in the user's current cell.
    var currentCellPacketCount: Int = 0

    /// Whether dead zone (probed but no response) at user's location.
    var isDeadZone: Bool = false

    /// Hex ID of the most-heard repeater in the current cell (e.g. "07").
    var topRepeaterHexID: String?

    // MARK: - Live Signal Bars (from SignalBarsService)

    /// Best repeater's RX quality (how well we hear them) from SignalBarsService.
    var bestRepeaterRxQuality: SNRQuality?

    /// Best repeater's TX quality (how well they hear us) from SignalBarsService.
    var bestRepeaterTxQuality: SNRQuality?

    /// Best repeater's display name or hex ID from SignalBarsService.
    var bestRepeaterName: String?

}
