import Foundation
import MC1Services

extension ChatViewModel {
  // MARK: - Reactions

  /// Send a reaction emoji to a message (channel or DM)
  func sendReaction(emoji: String, to message: MessageDTO) async {
    guard reactionServiceProvider() != nil,
          messageService != nil,
          let dataStore else {
      return
    }

    // Prevent duplicate sends from rapid taps
    let reactionKey = "\(message.id)-\(emoji)"
    guard !inFlightReactions.contains(reactionKey) else {
      logger.debug("Reaction \(emoji) already in flight for message \(message.id), ignoring")
      return
    }
    inFlightReactions.insert(reactionKey)
    defer { inFlightReactions.remove(reactionKey) }

    let localNodeName = connectedDeviceProvider()?.nodeName ?? "Me"

    // Check if user already reacted with this emoji
    if let alreadyReacted = try? await dataStore.reactionExists(
      messageID: message.id,
      senderName: localNodeName,
      emoji: emoji
    ), alreadyReacted {
      logger.debug("User already reacted with \(emoji), ignoring")
      return
    }

    // Handle channel vs DM
    if let channelIndex = message.channelIndex {
      await sendChannelReaction(
        emoji: emoji,
        to: message,
        channelIndex: channelIndex,
        localNodeName: localNodeName
      )
    } else if let contactID = message.contactID {
      await sendDMReaction(
        emoji: emoji,
        to: message,
        contactID: contactID,
        localNodeName: localNodeName
      )
    }
  }

  private func sendChannelReaction(
    emoji: String,
    to message: MessageDTO,
    channelIndex: UInt8,
    localNodeName: String
  ) async {
    guard let reactionService = reactionServiceProvider(),
          let messageService,
          let dataStore else { return }

    // Determine target sender name
    let targetSenderName: String
    if message.isOutgoing {
      targetSenderName = localNodeName
    } else {
      guard let senderName = message.senderNodeName else { return }
      targetSenderName = senderName
    }

    let reactionText = reactionService.buildReactionText(
      emoji: emoji,
      targetSender: targetSenderName,
      targetText: message.text,
      targetTimestamp: message.reactionTimestamp,
      localNodeName: localNodeName
    )

    // Reactions ride the same persisted send queue as ordinary messages: the
    // pending row survives an app restart and drains on the next transport-open,
    // which is what replaces the fork's in-memory outgoing-reaction queue.
    let carrier: MessageDTO
    do {
      carrier = try await messageService.createPendingChannelMessage(
        text: reactionText,
        channelIndex: channelIndex,
        radioID: message.radioID
      )
    } catch {
      logger.error("Failed to stage channel reaction: \(error)")
      errorMessage = error.userFacingMessage
      return
    }

    // Optimistic local update — the badge appears immediately; the queue
    // owns getting the packet out.
    await persistOutgoingReaction(
      ReactionDTO(
        messageID: message.id,
        emoji: emoji,
        senderName: localNodeName,
        messageHash: ReactionParser.generateMessageHash(
          text: message.text,
          timestamp: message.reactionTimestamp
        ),
        rawText: reactionText,
        channelIndex: channelIndex,
        radioID: message.radioID
      ),
      using: reactionService,
      dataStore: dataStore
    )

    // `localNodeName: nil` deliberately: the envelope's node name exists so the
    // drain can index a sent message as a reaction *target*. A reaction is never
    // itself reactable, so it must not enter the reaction index.
    let envelope = ChannelMessageEnvelope(
      messageID: carrier.id,
      channelIndex: channelIndex,
      isResend: false,
      messageText: carrier.text,
      messageTimestamp: carrier.timestamp,
      localNodeName: nil
    )
    do {
      try await enqueueChannel(envelope)
    } catch {
      logger.error("enqueueChannel reaction failed for messageID=\(carrier.id, privacy: .public): \(String(describing: error))")
      await failReactionCarrier(carrier.id)
      sendErrorMessage = Self.copyForEnqueueFailure(error)
    }
  }

  private func sendDMReaction(
    emoji: String,
    to message: MessageDTO,
    contactID: UUID,
    localNodeName: String
  ) async {
    guard let reactionService = reactionServiceProvider(),
          let messageService,
          let dataStore else { return }

    // Fetch the contact for sending
    guard let contact = try? await dataStore.fetchContact(id: contactID) else {
      logger.error("Failed to fetch contact for DM reaction")
      return
    }

    let reactionText = reactionService.buildDMReactionText(
      emoji: emoji,
      targetText: message.text,
      targetTimestamp: message.reactionTimestamp
    )

    let carrier: MessageDTO
    do {
      carrier = try await messageService.createPendingMessage(text: reactionText, to: contact)
    } catch {
      logger.error("Failed to stage DM reaction: \(error)")
      errorMessage = error.userFacingMessage
      return
    }

    await persistOutgoingReaction(
      ReactionDTO(
        messageID: message.id,
        emoji: emoji,
        senderName: localNodeName,
        messageHash: ReactionParser.generateMessageHash(
          text: message.text,
          timestamp: message.reactionTimestamp
        ),
        rawText: reactionText,
        contactID: contactID,
        radioID: message.radioID
      ),
      using: reactionService,
      dataStore: dataStore
    )

    do {
      try await enqueueDM(DirectMessageEnvelope(messageID: carrier.id, contactID: contact.id))
    } catch {
      logger.error("enqueueDM reaction failed for messageID=\(carrier.id, privacy: .public): \(String(describing: error))")
      await failReactionCarrier(carrier.id)
      sendErrorMessage = Self.copyForEnqueueFailure(error)
    }
  }

  // MARK: - Carrier Bookkeeping

  /// Writes the optimistic reaction row and pushes the refreshed summary into the timeline.
  private func persistOutgoingReaction(
    _ reactionDTO: ReactionDTO,
    using reactionService: ReactionService,
    dataStore: DataStore
  ) async {
    if let result = await reactionService.persistReactionAndUpdateSummary(
      reactionDTO,
      using: dataStore
    ) {
      updateReactionSummary(for: result.messageID, summary: result.summary)
    }
  }

  /// Marks a reaction's carrier message failed. A failed outgoing reaction is the one
  /// case `filterOutgoingReactionMessages` lets through to the timeline, so the user
  /// sees the send that didn't make it and can retry it like any other message.
  private func failReactionCarrier(_ messageID: UUID) async {
    _ = try? await dataStore?.updateMessageStatusUnlessDelivered(id: messageID, status: .failed)
    timeline.applyStatusUpdate(messageID: messageID, status: .failed)
  }

  // MARK: - Reaction Updates

  /// Update reaction summary for a specific message inline (O(1) update)
  func updateReactionSummary(for messageID: UUID, summary: String) {
    updateMessage(id: messageID) { $0.reactionSummary = summary }
  }
}
