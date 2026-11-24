import Foundation
import MC1Services

extension NodeConfigImportState {
  struct Preview {
    let id = UUID()
    var input: Input
    let source: NodeConfigImportViewModel.ImportSource
    let sections: ConfigSections
    /// "Make Room" as it stood when the preview ran; the apply uses the same value.
    var makeRoomForChannels = false
    /// The planner's preview for the confirmation's notes: contacts left out or without a
    /// location, and channel slot alignment. Nil until the preview returns.
    var notes: ImportPreview?
  }
}
