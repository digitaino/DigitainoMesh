import SwiftUI
import UIKit
import MC1Services

/// Display state for a message bubble (typically derived from MessageDisplayItem)
struct MessageDisplayState {
    var showTimestamp: Bool = false
    var showDirectionGap: Bool = false
    var showSenderName: Bool = true
    var showNewMessagesDivider: Bool = false
    var detectedURL: URL?
    var previewState: PreviewLoadState = .idle
    var loadedPreview: LinkPreviewDataDTO?
    var isImageURL: Bool = false
    var decodedImage: UIImage?
    var decodedPreviewImage: UIImage?
    var decodedPreviewIcon: UIImage?
    var isGIF: Bool = false
    var showInlineImages: Bool = false
    var autoPlayGIFs: Bool = true
    var showIncomingPath: Bool = false
    var showIncomingHopCount: Bool = false
    var formattedText: AttributedString?
    var detectedSharedRoute: SharedRoute?
    var detectedHexPath: HexPath?
    var isSearchMatch: Bool = false
    var isHighlighted: Bool = false

    // No-repeats retry suggestion
    var showNoRepeatsRetry: Bool = false
    var nextPowerLabel: String?

    // Duplicate message collapsing
    var duplicateCount: Int = 1
    var isDuplicateGroupExpanded: Bool = false
    var onToggleDuplicateGroup: (() -> Void)?
}
