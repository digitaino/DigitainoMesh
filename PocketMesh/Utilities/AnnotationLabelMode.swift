/// Controls annotation label visibility on route and traffic maps.
enum AnnotationLabelMode: CaseIterable {
    /// Labels hidden — tap pin for callout.
    case hidden
    /// Show short hex identifier (e.g. "A1B2C3").
    case hexShort
    /// Show full display name (adaptive visibility with collision avoidance).
    case name

    /// SF Symbol for the toolbar toggle.
    var iconName: String {
        switch self {
        case .hidden: "tag.slash"
        case .hexShort: "number"
        case .name: "tag"
        }
    }

    /// Cycle to the next mode.
    var next: AnnotationLabelMode {
        switch self {
        case .hidden: .hexShort
        case .hexShort: .name
        case .name: .hidden
        }
    }
}
