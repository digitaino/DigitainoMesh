import SwiftUI

/// Debug view showing raw MeshWX messages received on the #wx-broadcast channel.
/// Accessible from Tools tab. Shows every packet received, whether decode succeeded or failed.
struct WeatherLogView: View {
    @Environment(\.appState) private var appState

    var body: some View {
        Group {
            if appState.weatherCache.messageLog.isEmpty {
                emptyState
            } else {
                messageList
            }
        }
        .navigationTitle("Weather Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                statusMenu
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        List {
            Section {
                ContentUnavailableView {
                    Label("No Weather Messages", systemImage: "cloud.bolt")
                } description: {
                    VStack(spacing: 8) {
                        Text("Messages received on the #meshwx channel will appear here.")
                        Text("Total channel messages seen: \(appState.weatherCache.totalChannelMessagesReceived)")
                            .fontWeight(.medium)
                        if !appState.weatherCache.recentChannelNames.isEmpty {
                            Text("Active channels: \(appState.weatherCache.recentChannelNames.joined(separator: ", "))")
                                .font(.caption)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Message List

    private var messageList: some View {
        List {
            diagnosticsSection
            statsSection
            messagesSection
        }
    }

    private var diagnosticsSection: some View {
        Section("Channel Diagnostics") {
            LabeledContent("Total channel msgs (all)", value: "\(appState.weatherCache.totalChannelMessagesReceived)")
            if !appState.weatherCache.recentChannelNames.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Active channels:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(appState.weatherCache.recentChannelNames.joined(separator: ", "))
                        .font(.caption.monospaced())
                }
            }
        }
    }

    private var statsSection: some View {
        Section("Weather Cache") {
            LabeledContent("WX messages received", value: "\(appState.weatherCache.messageLog.count)")
            LabeledContent("Active warnings", value: "\(appState.weatherCache.warnings.count)")
            LabeledContent("Radar regions", value: "\(appState.weatherCache.radarFrames.count)")
        }
    }

    private var messagesSection: some View {
        Section("Messages") {
            ForEach(appState.weatherCache.messageLog.reversed()) { entry in
                messageRow(entry)
            }
        }
    }

    private func messageRow(_ entry: WeatherCache.LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: entry.decoded != nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(entry.decoded != nil ? .green : .red)
                    .font(.caption)

                Text(entry.summary)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                Text("\(entry.rawSize)B")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(entry.timestamp, style: .time)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(entry.hexDump)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Status Menu

    private var statusMenu: some View {
        Menu {
            Section("Active Warnings") {
                if appState.weatherCache.warnings.isEmpty {
                    Text("None")
                } else {
                    ForEach(appState.weatherCache.warnings) { warning in
                        Label(warning.displayTitle, systemImage: "exclamationmark.triangle")
                    }
                }
            }
            Button(role: .destructive) {
                appState.weatherCache.clearAll()
            } label: {
                Label("Clear Cache", systemImage: "trash")
            }
        } label: {
            Image(systemName: "info.circle")
        }
    }
}

#Preview {
    NavigationStack {
        WeatherLogView()
    }
    .environment(\.appState, AppState())
}
