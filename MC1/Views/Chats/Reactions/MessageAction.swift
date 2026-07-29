/// User actions dispatched from the message actions sheet, routed to handlers
/// by `ChatConversationView.dispatch(_:for:)`.
enum MessageAction: Equatable {
  case react(String)
  case reply
  /// Reply pre-filled with the message's route info ("RX via ..."), composed by
  /// the details section where the resolved path and its distance are at hand.
  case replyWithRoute(String)
  case copy
  case sendAgain
  case sendDM
  case blockSender
  case delete
}
