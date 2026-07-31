import Foundation

/// One observation the "no repeats heard" detector folds in.
///
/// The inputs are deliberately transport-agnostic values rather than the service event
/// types they are derived from, so ``ChatNoRepeatsPolicy`` can be exercised as a scripted
/// sequence with no radio, no persistence, and no clock.
public enum ChatNoRepeatsInput: Sendable, Equatable {
  /// A send reached a resolved status on the radio. Carries the two facts eligibility
  /// depends on, because the policy never reads a `MessageDTO`.
  ///
  /// Only channel broadcasts can arm the detector: repeat correlation works by matching
  /// our own packet echoing back through the RX log, and ``HeardRepeatsService`` only
  /// correlates `groupText` frames. A DM has no repeat evidence to be missing, so
  /// offering a "no repeats heard" card for one would always be a false positive.
  case sendResolved(messageID: UUID, isChannelMessage: Bool, isOutgoing: Bool, status: MessageStatus)
  /// A repeater echo was correlated to a sent message (`HeardRepeatEvent`).
  case repeatHeard(messageID: UUID, count: Int)
  /// The user asked for the message to go out again (either resend button, or the
  /// failed-send retry). The card has served its purpose and retires.
  case resendRequested(messageID: UUID)
  /// The send failed terminally; the failure UI owns that row instead.
  case sendFailed(messageID: UUID)
  /// The detection window for an armed message ran out. Emitted by the driver's timer,
  /// never by a caller — passing it directly is how tests skip the wall clock.
  case windowElapsed(messageID: UUID)
  /// Repeater signal data went away while the message was armed, so the window's verdict
  /// rests on nothing. Also emitted by the driver only: the armed slot is dropped and no
  /// card is offered.
  case detectionUnavailable(messageID: UUID)
  /// Conversation switch or teardown: forget everything.
  case reset

  /// Whether this observation can only ever retire — never create — an offer.
  ///
  /// The owner gates *arming* on repeater signal data being available; a retirement must
  /// pass that gate unconditionally, or a card offered while data was still flowing could
  /// never be dismissed once it stopped.
  public var isRetirement: Bool {
    switch self {
    case .repeatHeard, .resendRequested, .sendFailed, .detectionUnavailable, .reset:
      true
    case .sendResolved, .windowElapsed:
      false
    }
  }
}

/// Pure state machine deciding which message, if any, is offered the "no repeats heard"
/// retry card.
///
/// Holds no clock, no I/O and no reference to a view model. The driver
/// (``ChatNoRepeatsDetector``) owns the timer that turns an armed message into a
/// ``ChatNoRepeatsInput/windowElapsed(messageID:)``; every other rule lives here.
///
/// Ported from the legacy `ChatViewModel.scheduleNoRepeatsRetry` / `clearNoRepeatsRetry`
/// pair, which kept a single `noRepeatsRetryMessageID` and a single cancellable task. The
/// single-slot semantics are preserved: at most one message is armed and at most one is
/// prompted, and a newer send takes the armed slot from an older one.
public struct ChatNoRepeatsPolicy: Sendable, Equatable {
  /// The message whose detection window is running, or `nil` when none is.
  public private(set) var armedMessageID: UUID?

  /// The message currently offered the retry card, or `nil` when none is.
  public private(set) var promptedMessageID: UUID?

  /// Bumped every time a message takes the armed slot, including when the same message
  /// re-arms after a resend. The driver keys its timer restart on this rather than on
  /// ``armedMessageID`` changing, so a resend of the already-armed message restarts the
  /// window instead of inheriting the old one's remaining time.
  public private(set) var armSequence: UInt64 = 0

  public init() {}

  /// Whether a resolved send is evidence we can wait on repeats for.
  ///
  /// `.sent` is the terminal success state for a channel broadcast (there is no recipient
  /// ACK), and `.delivered` is admitted for the same reason legacy did: it is a strictly
  /// better outcome than `.sent` and must not silently disarm detection.
  public static func armsOnSend(
    isChannelMessage: Bool,
    isOutgoing: Bool,
    status: MessageStatus
  ) -> Bool {
    guard isChannelMessage, isOutgoing else { return false }
    switch status {
    case .sent, .delivered: return true
    case .pending, .sending, .failed, .retrying: return false
    }
  }

  /// Folds one input in.
  /// - Returns: `true` when the observable state changed.
  @discardableResult
  public mutating func handle(_ input: ChatNoRepeatsInput) -> Bool {
    let before = self

    switch input {
    case let .sendResolved(messageID, isChannelMessage, isOutgoing, status):
      guard Self.armsOnSend(
        isChannelMessage: isChannelMessage,
        isOutgoing: isOutgoing,
        status: status
      ) else { break }
      armedMessageID = messageID
      armSequence &+= 1
      // The packet just went back out, so any card offered for this same message is
      // stale. A card offered for a *different* message stays: that message really did
      // go unheard, and legacy kept it on screen until its own evidence changed.
      if promptedMessageID == messageID {
        promptedMessageID = nil
      }

    case let .repeatHeard(messageID, count):
      // A recorded repeat always carries a positive running count; the guard exists so a
      // zero-valued event (a reset write, a future caller) cannot retire the card.
      guard count > 0 else { break }
      retire(messageID)

    case let .resendRequested(messageID), let .sendFailed(messageID),
         let .detectionUnavailable(messageID):
      retire(messageID)

    case let .windowElapsed(messageID):
      // Anything that would have disqualified the message (a repeat, a failure, a
      // resend) already cleared the armed slot, so reaching here still armed *is* the
      // "no repeats heard" verdict.
      guard armedMessageID == messageID else { break }
      armedMessageID = nil
      promptedMessageID = messageID

    case .reset:
      armedMessageID = nil
      promptedMessageID = nil
    }

    return self != before
  }

  private mutating func retire(_ messageID: UUID) {
    if armedMessageID == messageID {
      armedMessageID = nil
    }
    if promptedMessageID == messageID {
      promptedMessageID = nil
    }
  }
}
