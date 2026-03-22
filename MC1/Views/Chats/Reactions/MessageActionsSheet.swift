import CoreLocation
import MC1Services
import SwiftUI

/// Actions available from the message actions sheet
enum MessageAction: Equatable {
    case react(String)
    case reply
    case replyWithRoute(String)
    case replyWithRepeaterMap(url: URL, description: String)
    case copy
    case sendAgain
    case blockSender
    case delete
}

/// Sheet-based message actions UI (ElementX style)
/// Replaces native context menus for unified experience across channel and direct messages
struct MessageActionsSheet: View {
    @Environment(\.appState) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let message: MessageDTO
    let senderName: String
    let recentEmojis: [String]
    let senderContact: ContactDTO?
    let onAction: (MessageAction) -> Void
    var onDirectMessage: ((ContactDTO) -> Void)?
    var onViewContact: ((ContactDTO) -> Void)?

    private var availability: MessageActionAvailability {
        MessageActionAvailability(message: message, senderContact: senderContact)
    }

    private func performAction(_ action: MessageAction) {
        onAction(action)
        dismiss()
    }

    private var emojiSection: some View {
        ActionsEmojiSection(
            recentEmojis: recentEmojis,
            showEmojiPicker: $showEmojiPicker,
            onSelectEmoji: { emoji in
                performAction(.react(emoji))
            }
        )
    }

    @State private var longPressHapticTrigger = 0
    @State private var showEmojiPicker = false
    @State private var isDetailExpanded = false
    @State private var repeats: [MessageRepeatDTO]?
    @State private var contacts: [ContactDTO] = []
    @State private var discoveredNodes: [DiscoveredNodeDTO] = []
    @State private var pathViewModel = MessagePathViewModel()

    var body: some View {
        VStack(spacing: 0) {
            ActionsPreviewHeader(
                message: message,
                senderName: senderName,
                senderContact: senderContact,
                onViewContact: { contact in
                    dismiss()
                    // Delay to let sheet dismiss before navigating
                    Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        onViewContact?(contact)
                    }
                }
            )

            Divider()

            if !dynamicTypeSize.isAccessibilitySize {
                emojiSection
                Divider()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        if dynamicTypeSize.isAccessibilitySize {
                            emojiSection
                            Divider()
                        }
                        ActionsButtonsSection(
                            availability: availability,
                            senderContact: senderContact,
                            onSelectAction: performAction,
                            onDirectMessage: { contact in
                                dismiss()
                                Task {
                                    try? await Task.sleep(for: .milliseconds(300))
                                    onDirectMessage?(contact)
                                }
                            }
                        )
                        ActionsDetailsSection(
                            message: message,
                            availability: availability,
                            isDetailExpanded: $isDetailExpanded,
                            repeats: repeats,
                            contacts: contacts,
                            discoveredNodes: discoveredNodes,
                            pathViewModel: pathViewModel,
                            onReplyWithRoute: { routeInfo in
                                performAction(.replyWithRoute(routeInfo))
                            },
                            onReplyWithRepeaterMap: { url, description in
                                performAction(.replyWithRepeaterMap(url: url, description: description))
                            }
                        )
                        ActionsBlockSection(
                            availability: availability,
                            onSelectAction: performAction
                        )
                        ActionsDeleteSection(
                            availability: availability,
                            onSelectAction: performAction
                        )
                    }
                }
                .onChange(of: isDetailExpanded) { _, expanded in
                    if expanded {
                        withAnimation {
                            proxy.scrollTo("expandedContent", anchor: .top)
                        }
                    }
                }
            }
        }
        .presentationDetents(
            (horizontalSizeClass == .regular || dynamicTypeSize.isAccessibilitySize)
                ? [.large] : [.medium, .large]
        )
        .presentationContentInteraction(.scrolls)
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(.systemBackground))
        .onAppear {
            longPressHapticTrigger += 1
        }
        .sensoryFeedback(.impact(flexibility: .solid), trigger: longPressHapticTrigger)
        .task {
            guard let services = appState.services else { return }
            if availability.canShowRepeatDetails {
                do {
                    contacts = try await services.dataStore.fetchContacts(deviceID: message.deviceID)
                    discoveredNodes = try await services.dataStore.fetchDiscoveredNodes(deviceID: message.deviceID)
                } catch {
                    contacts = []
                    discoveredNodes = []
                }
                repeats = await services.heardRepeatsService.refreshRepeats(for: message.id)
            } else if availability.canViewPath {
                await pathViewModel.loadContacts(services: services, deviceID: message.deviceID)
            }
        }
    }
}

// MARK: - Extracted Views

private struct ActionsPreviewHeader: View {
    let message: MessageDTO
    let senderName: String
    let senderContact: ContactDTO?
    let onViewContact: ((ContactDTO) -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var senderNodeID: String? {
        guard !message.isOutgoing,
              let keyPrefix = message.senderKeyPrefix,
              let firstByte = keyPrefix.first else { return nil }
        return String(format: "%02X", firstByte)
    }

    @ViewBuilder
    private var senderNameLabel: some View {
        if let contact = senderContact, let onViewContact {
            Button {
                onViewContact(contact)
            } label: {
                Text(senderName)
                    .font(.subheadline)
                    .bold()
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
        } else {
            Text(senderName)
                .font(.subheadline)
                .bold()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    if let senderNodeID {
                        Text(senderNodeID)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospaced()
                    }
                    senderNameLabel
                    Spacer()
                    ActionsTimestampLabel(message: message)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if let senderNodeID {
                            Text(senderNodeID)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .monospaced()
                        }
                        senderNameLabel
                    }
                    ActionsTimestampLabel(message: message)
                }
            }

            Text(message.text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
        }
        .padding()
    }
}

private struct ActionsTimestampLabel: View {
    let message: MessageDTO

    var body: some View {
        Text(message.date, format: .dateTime.hour().minute())
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}

private struct ActionsEmojiSection: View {
    let recentEmojis: [String]
    @Binding var showEmojiPicker: Bool
    let onSelectEmoji: (String) -> Void

    var body: some View {
        EmojiPickerRow(
            emojis: recentEmojis,
            onSelect: onSelectEmoji,
            onOpenKeyboard: { showEmojiPicker = true }
        )
        .padding(.vertical, 4)
        .sheet(isPresented: $showEmojiPicker) {
            EmojiPickerSheet(onSelect: onSelectEmoji)
        }
    }
}

private struct ActionsButtonsSection: View {
    let availability: MessageActionAvailability
    let senderContact: ContactDTO?
    let onSelectAction: (MessageAction) -> Void
    let onDirectMessage: ((ContactDTO) -> Void)?
    @AppStorage("replyWithQuote") private var replyWithQuote = false

    var body: some View {
        if availability.canReply {
            ActionButton(
                title: replyWithQuote ? L10n.Chats.Chats.Message.Action.reply : L10n.Chats.Chats.Message.Action.mention,
                icon: "arrowshape.turn.up.left",
                action: { onSelectAction(.reply) }
            )
        }

        if availability.canDirectMessage, let contact = senderContact {
            ActionButton(
                title: L10n.Chats.Chats.Message.Action.directMessage,
                icon: "paperplane",
                action: { onDirectMessage?(contact) }
            )
        }

        ActionButton(
            title: L10n.Chats.Chats.Message.Action.copy,
            icon: "doc.on.doc",
            action: { onSelectAction(.copy) }
        )

        if availability.canSendAgain {
            ActionButton(
                title: L10n.Chats.Chats.Message.Action.sendAgain,
                icon: "arrow.uturn.forward",
                action: { onSelectAction(.sendAgain) }
            )
        }
    }
}

private struct ActionsBlockSection: View {
    let availability: MessageActionAvailability
    let onSelectAction: (MessageAction) -> Void

    var body: some View {
        if availability.canBlockSender {
            Divider()
                .padding(.vertical, 8)
            ActionButton(
                title: L10n.Chats.Chats.Message.Action.blockSender,
                icon: "hand.raised",
                isDestructive: true,
                action: { onSelectAction(.blockSender) }
            )
        }
    }
}

private struct ActionsDeleteSection: View {
    let availability: MessageActionAvailability
    let onSelectAction: (MessageAction) -> Void

    var body: some View {
        if availability.canDelete {
            Divider()
                .padding(.vertical, 8)
            ActionButton(
                title: L10n.Chats.Chats.Message.Action.delete,
                icon: "trash",
                isDestructive: true,
                action: { onSelectAction(.delete) }
            )
        }
    }
}

private struct ActionsDetailsSection: View {
    let message: MessageDTO
    let availability: MessageActionAvailability
    @Binding var isDetailExpanded: Bool
    let repeats: [MessageRepeatDTO]?
    let contacts: [ContactDTO]
    let discoveredNodes: [DiscoveredNodeDTO]
    let pathViewModel: MessagePathViewModel
    var onReplyWithRoute: ((String) -> Void)?
    var onReplyWithRepeaterMap: ((URL, String) -> Void)?

    @Environment(\.appState) private var appState

    /// Location recorded on the message at receive time — preferred over current GPS.
    private var messageLocation: CLLocation? {
        guard let lat = message.userLatitude, let lon = message.userLongitude else { return nil }
        return CLLocation(latitude: lat, longitude: lon)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if availability.canShowRepeatDetails || availability.canViewPath {
                ActionsExpandableDetailRow(
                    message: message,
                    availability: availability,
                    isDetailExpanded: $isDetailExpanded,
                    repeats: repeats,
                    contacts: contacts,
                    discoveredNodes: discoveredNodes,
                    pathViewModel: pathViewModel,
                    onReplyWithRoute: onReplyWithRoute,
                    onReplyWithRepeaterMap: onReplyWithRepeaterMap
                )
            }

            Text(L10n.Chats.Chats.Message.Action.details)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 4)

            if message.isOutgoing {
                ActionsOutgoingDetailsRows(message: message)
            } else {
                ActionsIncomingDetailsRows(
                    message: message,
                    contacts: contacts.isEmpty ? pathViewModel.allContacts : contacts,
                    discoveredNodes: discoveredNodes.isEmpty ? pathViewModel.allDiscoveredNodes : discoveredNodes,
                    userLocation: messageLocation ?? appState.locationService.currentLocation
                )
            }
        }
    }
}

private struct ActionsExpandableDetailRow: View {
    @Environment(\.appState) private var appState

    let message: MessageDTO
    let availability: MessageActionAvailability
    @Binding var isDetailExpanded: Bool
    let repeats: [MessageRepeatDTO]?
    let contacts: [ContactDTO]
    let discoveredNodes: [DiscoveredNodeDTO]
    let pathViewModel: MessagePathViewModel
    var onReplyWithRoute: ((String) -> Void)?
    var onReplyWithRepeaterMap: ((URL, String) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation {
                    isDetailExpanded.toggle()
                }
            } label: {
                HStack {
                    Label(
                        availability.canShowRepeatDetails
                            ? L10n.Chats.Chats.Message.Action.repeatDetails
                            : L10n.Chats.Chats.Message.Action.viewPath,
                        systemImage: availability.canShowRepeatDetails
                            ? "arrow.triangle.branch"
                            : "point.topleft.down.to.point.bottomright.curvepath"
                    )
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isDetailExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .padding()
                .contentShape(.rect)
            }
            .foregroundStyle(.primary)
            .accessibilityValue(isDetailExpanded ? "expanded" : "collapsed")

            if isDetailExpanded {
                Divider()
                    .padding(.horizontal)
                ActionsExpandedContent(
                    message: message,
                    availability: availability,
                    repeats: repeats,
                    contacts: contacts,
                    discoveredNodes: discoveredNodes,
                    pathViewModel: pathViewModel,
                    onReplyWithRoute: onReplyWithRoute,
                    onReplyWithRepeaterMap: onReplyWithRepeaterMap
                )
                .padding(.horizontal)
                .padding(.bottom)
                .id("expandedContent")
            }
        }
    }
}

private struct ActionsExpandedContent: View {
    @Environment(\.appState) private var appState

    let message: MessageDTO
    let availability: MessageActionAvailability
    let repeats: [MessageRepeatDTO]?
    let contacts: [ContactDTO]
    let discoveredNodes: [DiscoveredNodeDTO]
    let pathViewModel: MessagePathViewModel
    var onReplyWithRoute: ((String) -> Void)?
    var onReplyWithRepeaterMap: ((URL, String) -> Void)?

    @State private var showingRepeatsMap = false
    @State private var isSharing = false
    @State private var showingLocationPicker = false

    /// Location recorded on the message at receive time — preferred over current GPS.
    private var messageLocation: CLLocation? {
        guard let lat = message.userLatitude, let lon = message.userLongitude else { return nil }
        return CLLocation(latitude: lat, longitude: lon)
    }

    var body: some View {
        if availability.canShowRepeatDetails {
            RepeatDetailsContent(
                repeats: repeats,
                contacts: contacts,
                discoveredNodes: discoveredNodes,
                userLocation: messageLocation ?? appState.locationService.currentLocation
            )

            if let repeats, !repeats.isEmpty {
                HStack(spacing: 8) {
                    Button {
                        showingRepeatsMap = true
                    } label: {
                        Label(L10n.Chats.Chats.HeardRepeats.Map.viewOnMap, systemImage: "map")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .sheet(isPresented: $showingRepeatsMap) {
                        HeardRepeatsMapSheet(
                            repeats: repeats,
                            contacts: contacts,
                            discoveredNodes: discoveredNodes,
                            messageLocation: messageLocation
                        )
                    }

                    Button {
                        showingLocationPicker = true
                    } label: {
                        if isSharing {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                        } else {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSharing || trueLocationCoordinate == nil)
                    .sheet(isPresented: $showingLocationPicker) {
                        if let coord = trueLocationCoordinate {
                            ShareLocationPickerSheet(trueLocation: coord) { chosenCoordinate in
                                Task {
                                    await shareHeardRepeaters(
                                        repeats: repeats,
                                        chosenCoordinate: chosenCoordinate
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(.top, 8)
            }
        } else if availability.canViewPath {
            MessagePathContent(
                message: message,
                viewModel: pathViewModel,
                receiverName: appState.connectedDevice?.nodeName ?? L10n.Chats.Chats.Path.Receiver.you,
                userLocation: messageLocation ?? appState.locationService.currentLocation,
                onReplyWithRoute: onReplyWithRoute
            )
        }
    }

    // MARK: - Location

    /// The user's true location coordinate for the location picker.
    /// Prefers the location recorded on the message; falls back to current GPS.
    private var trueLocationCoordinate: CLLocationCoordinate2D? {
        if let lat = message.userLatitude, let lon = message.userLongitude {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        return appState.locationService.currentLocation?.coordinate
    }

    // MARK: - Share Heard Repeaters

    private func shareHeardRepeaters(
        repeats: [MessageRepeatDTO],
        chosenCoordinate: CLLocationCoordinate2D?
    ) async {
        isSharing = true
        defer { isSharing = false }

        let repeaterContacts = contacts.filter { $0.type == .repeater }

        // Use the location recorded on the message at receive time for repeater
        // matching — the user may be somewhere else when they share.
        let userLocation: CLLocation? = {
            guard let lat = message.userLatitude, let lon = message.userLongitude else { return nil }
            return CLLocation(latitude: lat, longitude: lon)
        }()

        // Aggregate unique repeaters across all repeats
        var repeaterMap: [String: (contact: ContactDTO?, heardCount: Int, snrSum: Double, snrCount: Int, rssiSum: Double, rssiCount: Int)] = [:]

        // Build per-repeat path data for map line rendering
        var repeatPaths: [RouteShareService.RepeatPath] = []

        for repeatDTO in repeats {
            guard !repeatDTO.pathNodes.isEmpty else { continue }

            let hashes = RouteAggregator.parseHopHashes(
                pathNodes: repeatDTO.pathNodes,
                hashSize: repeatDTO.hashSize
            )
            guard !hashes.isEmpty else { continue }

            // Build path hop hex IDs for this repeat
            let hopHexIDs = hashes.map { hash in
                hash.map { String(format: "%02X", $0) }.joined()
            }
            repeatPaths.append(RouteShareService.RepeatPath(
                hops: hopHexIDs,
                snr: repeatDTO.snr
            ))

            for hash in hashes {
                let hexID = hash.map { String(format: "%02X", $0) }.joined()
                var entry = repeaterMap[hexID] ?? (contact: nil, heardCount: 0, snrSum: 0, snrCount: 0, rssiSum: 0, rssiCount: 0)

                if entry.contact == nil {
                    entry.contact = RepeaterResolver.bestMatch(for: hash, in: repeaterContacts, userLocation: userLocation)
                }

                entry.heardCount += 1
                if let snr = repeatDTO.snr {
                    entry.snrSum += snr
                    entry.snrCount += 1
                }
                if let rssi = repeatDTO.rssi {
                    entry.rssiSum += Double(rssi)
                    entry.rssiCount += 1
                }

                repeaterMap[hexID] = entry
            }
        }

        let repeaterInfos: [RouteShareService.RepeaterInfo] = repeaterMap.map { hexID, entry in
            RouteShareService.RepeaterInfo(
                hexID: hexID,
                name: entry.contact?.displayName,
                latitude: entry.contact?.hasLocation == true ? entry.contact?.latitude : nil,
                longitude: entry.contact?.hasLocation == true ? entry.contact?.longitude : nil,
                heardCount: entry.heardCount,
                avgSNR: entry.snrCount > 0 ? entry.snrSum / Double(entry.snrCount) : nil,
                avgRSSI: entry.rssiCount > 0 ? entry.rssiSum / Double(entry.rssiCount) : nil
            )
        }

        guard !repeaterInfos.isEmpty else { return }

        let service = RouteShareService()
        if let url = await service.shareRepeaterMap(
            repeaters: repeaterInfos,
            paths: repeatPaths.isEmpty ? nil : repeatPaths,
            userLatitude: chosenCoordinate?.latitude,
            userLongitude: chosenCoordinate?.longitude
        ) {
            let hexList = repeaterInfos.map(\.hexID).joined(separator: ", ")
            let repeatWord = repeats.count == 1 ? "repeat" : "repeats"
            let description = "📡 \(repeats.count) \(repeatWord) via \(hexList)"
            onReplyWithRepeaterMap?(url, description)
        }
    }
}

private struct ActionsOutgoingDetailsRows: View {
    let message: MessageDTO

    var body: some View {
        ActionInfoRow(text: L10n.Chats.Chats.Message.Info.sent(
            message.senderDate.formatted(date: .abbreviated, time: .shortened)))

        if let rtt = message.roundTripTime {
            ActionInfoRow(text: L10n.Chats.Chats.Message.Info.roundTrip(Int(rtt)))
        }

        if message.heardRepeats > 0 {
            let word = message.heardRepeats == 1
                ? L10n.Chats.Chats.Message.Repeat.singular
                : L10n.Chats.Chats.Message.Repeat.plural
            ActionInfoRow(text: L10n.Chats.Chats.Message.Info.heardRepeats(message.heardRepeats, word))
        }
    }
}

private struct ActionsIncomingDetailsRows: View {
    let message: MessageDTO
    var contacts: [ContactDTO] = []
    var discoveredNodes: [DiscoveredNodeDTO] = []
    var userLocation: CLLocation?

    private var distanceText: String? {
        guard let result = RouteDistanceCalculator.computeRouteDistance(
            message: message,
            contacts: contacts,
            discoveredNodes: discoveredNodes,
            userLocation: userLocation
        ) else { return nil }
        return RouteDistanceCalculator.formatTotal(result.meters, hasGaps: result.hasGaps)
    }

    var body: some View {
        ActionInfoRow(
            text: L10n.Chats.Chats.Message.Info.hops(MessagePathFormatter.format(message))
                + (distanceText.map { " · \($0)" } ?? ""),
            icon: "arrowshape.bounce.right"
        )

        let sentText = L10n.Chats.Chats.Message.Info.sent(
            message.senderDate.formatted(date: .abbreviated, time: .shortened))
        let adjusted = message.timestampCorrected ? " " + L10n.Chats.Chats.Message.Info.adjusted : ""
        ActionInfoRow(text: sentText + adjusted)

        ActionInfoRow(text: L10n.Chats.Chats.Message.Info.received(
            message.createdAt.formatted(date: .abbreviated, time: .shortened)))

        if let snr = message.snr {
            ActionInfoRow(text: L10n.Chats.Chats.Message.Info.snr(snrFormatted(snr)))
        }
    }

    private func snrFormatted(_ snr: Double) -> String {
        let quality: String
        switch snr {
        case 10...:
            quality = L10n.Chats.Chats.Signal.excellent
        case 5..<10:
            quality = L10n.Chats.Chats.Signal.good
        case 0..<5:
            quality = L10n.Chats.Chats.Signal.fair
        case -10..<0:
            quality = L10n.Chats.Chats.Signal.poor
        default:
            quality = L10n.Chats.Chats.Signal.veryPoor
        }
        return "\(snr.formatted(.number.precision(.fractionLength(1)))) dB (\(quality))"
    }

}

// MARK: - Shared Helper Views

private struct ActionButton: View {
    let title: String
    let icon: String
    var isDestructive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
            }
            .padding()
            .contentShape(.rect)
        }
        .foregroundStyle(isDestructive ? .red : .primary)
    }
}

private struct ActionInfoRow: View {
    let text: String
    var icon: String?

    var body: some View {
        HStack {
            if let icon {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
            }
            Text(text)
            Spacer()
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}

#Preview("Outgoing Message") {
    let message = Message(
        deviceID: UUID(),
        contactID: UUID(),
        text: "Hello world!",
        directionRawValue: MessageDirection.outgoing.rawValue,
        statusRawValue: MessageStatus.delivered.rawValue
    )
    message.roundTripTime = 234
    message.heardRepeats = 2
    return MessageActionsSheet(
        message: MessageDTO(from: message),
        senderName: "My Device",
        recentEmojis: RecentEmojisStore.defaultEmojis,
        senderContact: nil,
        onAction: { print("Action: \($0)") }
    )
}

#Preview("Incoming Message") {
    let message = Message(
        deviceID: UUID(),
        contactID: UUID(),
        text: "Hey, can you meet me at the coffee shop downtown later today? I have something important to discuss.",
        directionRawValue: MessageDirection.incoming.rawValue,
        statusRawValue: MessageStatus.delivered.rawValue,
        pathLength: 2
    )
    message.pathNodes = Data([0xA3, 0x7F])
    message.snr = 8.5
    return MessageActionsSheet(
        message: MessageDTO(from: message),
        senderName: "Alice",
        recentEmojis: RecentEmojisStore.defaultEmojis,
        senderContact: nil,
        onAction: { print("Action: \($0)") }
    )
}
