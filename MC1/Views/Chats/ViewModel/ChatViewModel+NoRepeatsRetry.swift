import Foundation
import MC1Services

/// Wiring between the conversation's event stream and ``ChatNoRepeatsDetector``, and
/// between the detector's verdict and the timeline row that renders the card.
///
/// All decision logic lives in `MC1Services` (``ChatNoRepeatsPolicy``); this file only
/// translates. The translation is here rather than in `MessageEventDispatcher` because
/// eligibility needs the message DTO (channel vs DM, direction), and the view model is the
/// layer that already holds it — the same place legacy's `scheduleNoRepeatsRetry` lived.
extension ChatViewModel {
  // MARK: - Feeding the detector

  /// Routes one observation to the detector, dropping an *arming* observation when the
  /// connection has no repeater signal data.
  ///
  /// The gate is `AppState.repeaterSignals.isAttached`, which is true exactly when the
  /// signal-bars engine is running for this connection — engine mode or viewer mode, per
  /// `SyncRegistryProbe.signalBarsMode()`. When it is false (signal bars switched off for
  /// the device, or no connection) no send arms the detector, so no window task is ever
  /// created and no card can appear: inert at zero cost, not merely hidden.
  ///
  /// Retirement inputs pass regardless. Gating those too would strand a card offered while
  /// signal bars were still attached — including the card's own Send Again button, whose
  /// `.resendRequested` is what retires it.
  func noteNoRepeatsInput(_ input: ChatNoRepeatsInput) {
    guard input.isRetirement || signalDataAvailableProvider() else { return }
    noRepeatsDetector.handle(input)
  }

  /// Arms (or disarms) detection from a resolved send. Resolves channel-vs-DM and
  /// direction from the canonical DTO; an unknown id is skipped rather than guessed at.
  func noteSendResolved(messageID: UUID, status: MessageStatus) {
    guard let message = messagesByID[messageID] else { return }
    noteNoRepeatsInput(.sendResolved(
      messageID: messageID,
      isChannelMessage: message.isChannelMessage,
      isOutgoing: message.isOutgoing,
      status: status
    ))
  }

  /// Retires the card for a message the user has just asked to go out again. Called from
  /// every resend and retry entry point, so the card never lingers over a message that is
  /// already back in the send queue.
  func noteResendRequested(messageID: UUID) {
    noteNoRepeatsInput(.resendRequested(messageID: messageID))
  }

  /// Forgets everything on a conversation switch. Paired with `clearPreviewState`, which
  /// clears the bake-side slot in the same call.
  func resetNoRepeatsDetection() {
    noRepeatsDetector.handle(.reset)
  }

  // MARK: - Rendering the verdict

  /// Moves the card to `messageID` (or retires it when nil) as two single-row rebakes.
  ///
  /// The escalated-power label is resolved here, at prompt time, so the card always offers
  /// the rung the radio would actually step to next.
  func applyNoRepeatsPrompt(_ messageID: UUID?) {
    let prompt = messageID.map { _ in
      NoRepeatsRetryPrompt(nextPowerLabel: nextEscalatedPowerLabel())
    }
    timeline.apply(.noRepeatsRetry(messageID: messageID, prompt: prompt))
  }

  /// Label of the rung an escalated resend would move to, or nil when adaptive power is
  /// off or the radio is already at its highest reachable step.
  ///
  /// Reads `AdaptivePowerPolicy.escalatedStep(from:)` — the same function
  /// `AdaptivePowerService.escalate()` uses to pick its target — so the label on the button
  /// and the power the button produces can never disagree (plan §3 row C4: one
  /// power-decision component).
  func nextEscalatedPowerLabel() -> String? {
    guard let power = adaptivePowerServiceProvider(), power.isEnabled else { return nil }
    return power.policy.escalatedStep(from: power.currentStepIndex)?.label
  }

  // MARK: - Resend actions

  /// Resends the message unchanged, at the power currently in force.
  ///
  /// Routes through `sendAgain`, which enqueues on `ChatSendQueueService` — there is no
  /// second send path for the card.
  func resendAtSamePower(_ message: MessageDTO) async {
    noteResendRequested(messageID: message.id)
    await sendAgain(message)
  }

  /// Escalates TX power one rung, then resends through the same queue path.
  ///
  /// The escalation is **sticky**, matching legacy: `AdaptivePowerService.escalate()`
  /// moves `currentStepIndex` and leaves it there. Power never ramps back down on its own
  /// (that would oscillate); it returns to base only on an explicit reset — reconnect,
  /// disabling adaptive power, or the user's Reset action. So a second message sent after
  /// tapping this button also goes out at the raised power, which is the intent: the
  /// escalation is a verdict about the link, not a per-message override.
  func resendAtNextPower(_ message: MessageDTO) async {
    if let power = adaptivePowerServiceProvider(), power.isEnabled {
      power.onNoRepeatsHeard()
      await power.escalate()
    }
    await resendAtSamePower(message)
  }
}
