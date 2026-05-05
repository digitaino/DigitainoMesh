/// Callbacks for message bubble interactions
struct MessageBubbleCallbacks {
    var onRetry: (() -> Void)?
    var onResendSamePower: (() -> Void)?
    var onResendAtNextPower: (() -> Void)?
    var onReaction: ((String) -> Void)?
    var onLongPress: (() -> Void)?
    var onReply: (() -> Void)?
    var onImageTap: (() -> Void)?
    var onRetryImageFetch: (() -> Void)?
    var onRequestPreviewFetch: (() -> Void)?
    var onManualPreviewFetch: (() -> Void)?
    var onShowSharedRoute: (() -> Void)?
    var onShowHexPath: (() -> Void)?
}
