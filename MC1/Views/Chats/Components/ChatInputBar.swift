import SwiftUI
import MC1Services

/// Reusable chat input bar with configurable styling
struct ChatInputBar: View {
    @Environment(\.appState) private var appState
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool
    let placeholder: String
    let maxBytes: Int
    let isEncrypted: Bool
    /// Called to send a message. Second parameter is an optional one-shot TX power override in dBm.
    let onSend: (String, Int8?) -> Void

    @State private var isCoolingDown = false
    @State private var showPowerPicker = false
    @State private var sentAtPowerLabel: String? = nil

    private var byteCount: Int {
        text.utf8.count
    }

    private var isOverLimit: Bool {
        byteCount > maxBytes
    }

    private var shouldShowCharacterCount: Bool {
        byteCount >= maxBytes - 20
    }

    private var adaptivePower: AdaptivePowerService {
        appState.adaptivePowerService
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            ChatInputTextField(text: $text, placeholder: placeholder, isFocused: $isFocused, isEncrypted: isEncrypted)
            VStack(spacing: 4) {
                sendButton
                if let label = sentAtPowerLabel {
                    Text("Sent at \(label)")
                        .font(.system(.caption2, weight: .medium))
                        .foregroundStyle(.orange)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if shouldShowCharacterCount {
                    ChatCharacterCountLabel(
                        byteCount: byteCount,
                        maxBytes: maxBytes,
                        isOverLimit: isOverLimit
                    )
                }
            }
            .animation(.easeOut(duration: 0.2), value: sentAtPowerLabel)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .inputBarBackground()
        .overlay(alignment: .bottomTrailing) {
            if showPowerPicker && adaptivePower.isEnabled {
                PowerPickerMenu(
                    power: adaptivePower,
                    onSelect: { stepIndex in
                        showPowerPicker = false
                        sendAtPower(stepIndex)
                    },
                    onDismiss: { showPowerPicker = false }
                )
                .padding(.trailing, 16)
                .padding(.bottom, 56)
                .transition(.scale(scale: 0.85, anchor: .bottomTrailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.15), value: showPowerPicker)
    }

    // MARK: - Send Button

    private var sendButtonFont: Font {
        if #available(iOS 26.0, *) { .title2 } else { .title }
    }

    private var canSend: Bool {
        !isCoolingDown &&
        appState.connectionState == .ready &&
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isOverLimit
    }

    private var sendButton: some View {
        Button {
            // Don't send if the power picker is showing (long press just ended)
            guard !showPowerPicker else { return }
            send()
        } label: {
            Image(systemName: "arrow.up.circle.fill")
                .font(sendButtonFont)
                .foregroundStyle(canSend ? AppColors.Message.outgoingBubble : .secondary)
        }
        .sendButtonStyle()
        .disabled(!canSend)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    guard canSend && adaptivePower.isEnabled else { return }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    showPowerPicker = true
                }
        )
        .accessibilityLabel(sendAccessibilityLabel)
        .accessibilityHint(sendAccessibilityHint)
    }

    // MARK: - Accessibility

    private var sendAccessibilityLabel: String {
        if isOverLimit {
            return L10n.Chats.Chats.Input.tooLong
        } else {
            return L10n.Chats.Chats.Input.sendMessage
        }
    }

    private var sendAccessibilityHint: String {
        if isOverLimit {
            return L10n.Chats.Chats.Input.removeCharacters(byteCount - maxBytes)
        } else if appState.connectionState != .ready {
            return L10n.Chats.Chats.Input.requiresConnection
        } else if canSend {
            if adaptivePower.isEnabled {
                return "Tap to send. Hold to choose power level."
            }
            return L10n.Chats.Chats.Input.tapToSend
        } else {
            return L10n.Chats.Chats.Input.typeFirst
        }
    }

    // MARK: - Send Actions

    private func send() {
        let captured = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !captured.isEmpty else { return }
        isCoolingDown = true
        text = ""
        onSend(captured, nil)
        Task {
            try? await Task.sleep(for: .seconds(1))
            isCoolingDown = false
        }
    }

    private func sendAtPower(_ stepIndex: Int) {
        let captured = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !captured.isEmpty else { return }
        let step = AdaptivePowerService.allSteps[stepIndex]
        let power = appState.adaptivePowerService
        let overrideDbm = power.radioDbm(for: step)

        isCoolingDown = true
        text = ""
        sentAtPowerLabel = step.label

        // Pass the override dBm directly through onSend — it travels with the
        // queued message, so there are no race conditions or environment issues.
        onSend(captured, overrideDbm)

        Task {
            try? await Task.sleep(for: .seconds(2))
            sentAtPowerLabel = nil
            isCoolingDown = false
        }
    }
}

// MARK: - Power Picker Menu (interactive tappable buttons)

private struct PowerPickerMenu: View {
    let power: AdaptivePowerService
    let onSelect: (Int) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("Send at power")
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)

            ForEach(power.availableSteps) { step in
                if step.id != power.availableSteps.first?.id {
                    Divider()
                        .padding(.leading, 14)
                }
                Button {
                    onSelect(step.id)
                } label: {
                    HStack {
                        Text(step.label)
                            .font(.system(.body, weight: step.id == power.currentStepIndex ? .semibold : .regular))
                        Spacer()
                        if step.id == power.currentStepIndex {
                            Image(systemName: "checkmark")
                                .font(.subheadline)
                                .foregroundStyle(.blue)
                        } else if step.id == power.baseStepIndex {
                            Text("base")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Divider()
                .padding(.leading, 14)

            Button {
                onDismiss()
            } label: {
                Text("Cancel")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 200)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
    }
}

// MARK: - Extracted Views

private struct ChatInputTextField: View {
    @Binding var text: String
    let placeholder: String
    @FocusState.Binding var isFocused: Bool
    let isEncrypted: Bool

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .padding(.leading, 12)
            .padding(.trailing, 28)
            .padding(.vertical, 8)
            .overlay(alignment: .trailing) {
                Image(systemName: isEncrypted ? "lock.fill" : "lock.open.fill")
                    .font(.footnote)
                    .foregroundStyle(isEncrypted ? .blue : .orange)
                    .padding(.trailing, 10)
                    .accessibilityHidden(true)
            }
            .textFieldBackground()
            .lineLimit(1...5)
            .focused($isFocused)
            .accessibilityLabel(L10n.Chats.Chats.Input.accessibilityLabel)
            .accessibilityHint(L10n.Chats.Chats.Input.accessibilityHint)
            .accessibilityValue(isEncrypted ? L10n.Chats.Chats.Input.encrypted : L10n.Chats.Chats.Input.notEncrypted)
    }
}

private struct ChatCharacterCountLabel: View {
    let byteCount: Int
    let maxBytes: Int
    let isOverLimit: Bool

    var body: some View {
        Text("\(byteCount)/\(maxBytes)")
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(isOverLimit ? .red : .secondary)
            .accessibilityLabel(L10n.Chats.Chats.Input.characterCount(byteCount, maxBytes))
    }
}

// MARK: - Platform-Conditional Styling

private extension View {
    @ViewBuilder
    func sendButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.padding(.vertical, 4)
        }
    }

    @ViewBuilder
    func textFieldBackground() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
        } else {
            self
                .background(Color(.systemGray6))
                .clipShape(.rect(cornerRadius: 20))
        }
    }

    @ViewBuilder
    func inputBarBackground() -> some View {
        if #available(iOS 26.0, *) {
            self
        } else {
            self.background(.bar)
        }
    }
}
