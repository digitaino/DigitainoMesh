import CoreLocation
import UIKit

/// Callbacks for message bubble interactions.
///
/// `onRetryInlineImage` fires the inline-image retry (the full-frame retry affordance). The map
/// thumbnail retries separately through `retrySnapshot`. The `snapshot*` closures inject the map
/// snapshot store so the bubble resolves, requests, and retries thumbnails through providers rather
/// than reaching `MapSnapshotStore.shared` from the view body.
struct MessageBubbleCallbacks {
  var onRetry: (() -> Void)?
  /// No-repeats retry card: resend unchanged, at the power currently in force.
  var onResendSamePower: (() -> Void)?
  /// No-repeats retry card: escalate TX power one rung, then resend.
  var onResendAtNextPower: (() -> Void)?
  var onReaction: ((String) -> Void)?
  var onLongPress: (() -> Void)?
  var onImageTap: (() -> Void)?
  var onRetryInlineImage: (() -> Void)?
  var onRequestPreviewFetch: (() -> Void)?
  var onManualPreviewFetch: (() -> Void)?
  var onMapPreviewTap: ((CLLocationCoordinate2D) -> Void)?
  var snapshotResolver: ((MapSnapshotRequest) -> UIImage?)?
  var requestSnapshot: ((MapSnapshotRequest) -> Void)?
  var retrySnapshot: ((MapSnapshotRequest) -> Void)?
}
