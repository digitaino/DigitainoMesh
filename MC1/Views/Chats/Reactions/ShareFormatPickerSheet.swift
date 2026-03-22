import SwiftUI

/// Format options when sharing routes or repeater maps
enum ShareFormat: String {
    case webLink
    case textOnly
}

/// Compact sheet presenting "Web Link" vs "Text Only" share format options.
struct ShareFormatPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("shareFormatDefault") private var defaultFormat = "webLink"

    let onSelect: (ShareFormat) -> Void

    @State private var rememberChoice = false

    private var currentDefault: ShareFormat {
        ShareFormat(rawValue: defaultFormat) ?? .webLink
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        select(.webLink)
                    } label: {
                        formatRow(
                            icon: "globe",
                            title: "Web Link",
                            description: "Upload to server and generate a shareable URL",
                            isDefault: currentDefault == .webLink
                        )
                    }

                    Button {
                        select(.textOnly)
                    } label: {
                        formatRow(
                            icon: "text.quote",
                            title: "Text Only",
                            description: "Insert route description without uploading",
                            isDefault: currentDefault == .textOnly
                        )
                    }
                }

                Section {
                    Toggle("Remember my choice", isOn: $rememberChoice)
                } footer: {
                    Text("Sets the default for future shares. You can change it in Settings > Chats.")
                }
            }
            .navigationTitle("Share Format")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func select(_ format: ShareFormat) {
        if rememberChoice {
            defaultFormat = format.rawValue
        }
        dismiss()
        onSelect(format)
    }

    private func formatRow(
        icon: String,
        title: String,
        description: String,
        isDefault: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.body)
                    if isDefault {
                        Text("Default")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .contentShape(Rectangle())
    }
}
