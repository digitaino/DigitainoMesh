import SwiftUI

/// Layout constants shared across `PathEditingSheet`, `AddHopPickerView`, and
/// `AddHopSegmentPicker`. Top-level `private` in Swift is file-scoped, so this
/// type must be `internal` to be referenced from the other files.
enum PathEditMetrics {
    /// 48pt tap target — glove-safe, above HIG's 44pt minimum.
    static let tapTarget: CGFloat = 48
    static let rowInset: CGFloat = 16
    static let rowVerticalPadding: CGFloat = 8
    static let rowContentSpacing: CGFloat = 12
    static let badgeSpacing: CGFloat = 6
    static let segmentPickerVerticalInset: CGFloat = 8
    static let disabledOpacity: Double = 0.5
}
