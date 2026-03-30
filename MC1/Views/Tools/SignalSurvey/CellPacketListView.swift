import MC1Services
import MeshCore
import SwiftUI

/// Sheet view displaying individual packet details for a selected hex grid cell.
struct CellPacketListView: View {
    let points: [SignalSurveyPointDTO]
    let cellID: String
    let relayFilter: String?
    let contactsByName: [String: ContactDTO]
    var onNavigateToContact: ((ContactDTO) -> Void)?
    var onViewInChat: ((SignalSurveyPointDTO) -> Void)?

    @Environment(\.dismiss) private var dismiss

    private var sortedPoints: [SignalSurveyPointDTO] {
        points.sorted { $0.timestamp > $1.timestamp }
    }

    var body: some View {
        NavigationStack {
            Group {
                if points.isEmpty {
                    ContentUnavailableView(
                        "No Packets",
                        systemImage: "antenna.radiowaves.left.and.right.slash",
                        description: Text("No packets recorded in this cell.")
                    )
                } else {
                    List(sortedPoints) { point in
                        PacketRow(
                            point: point,
                            contact: point.fromContactName.flatMap { contactsByName[$0] },
                            onNavigateToContact: onNavigateToContact,
                            onViewInChat: onViewInChat
                        )
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var navigationTitle: String {
        let count = points.count
        if let relay = relayFilter {
            return "\(count) Packet\(count == 1 ? "" : "s") via \(relay)"
        }
        return "\(count) Packet\(count == 1 ? "" : "s")"
    }
}

// MARK: - Packet Row

private struct PacketRow: View {
    let point: SignalSurveyPointDTO
    let contact: ContactDTO?
    var onNavigateToContact: ((ContactDTO) -> Void)?
    var onViewInChat: ((SignalSurveyPointDTO) -> Void)?

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Line 1: Time + Signal
            HStack(spacing: 8) {
                Text(Self.timeFormatter.string(from: point.timestamp))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)

                signalIndicator

                Spacer()

                typeBadge(point.routeType.displayName, color: routeColor)
                typeBadge(point.payloadType.displayName, color: .secondary)
            }

            // Line 2: Signal values
            HStack(spacing: 12) {
                if let snr = point.snr {
                    Label {
                        Text(String(format: "%.1f dB", snr))
                            .font(.caption)
                    } icon: {
                        Image(systemName: "waveform")
                            .font(.caption2)
                            .foregroundStyle(snrColor)
                    }
                }

                if let rssi = point.rssi {
                    Label {
                        Text("\(rssi) dBm")
                            .font(.caption)
                    } icon: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if point.hopCount > 0 {
                    Label {
                        Text("\(point.hopCount) hop\(point.hopCount == 1 ? "" : "s")")
                            .font(.caption)
                    } icon: {
                        Image(systemName: "arrow.triangle.swap")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Line 3: Sender
            if let senderName = point.fromContactName {
                HStack(spacing: 4) {
                    Image(systemName: "person.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if let contact {
                        Button {
                            onNavigateToContact?(contact)
                        } label: {
                            HStack(spacing: 2) {
                                Text(senderName)
                                    .font(.caption)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8))
                            }
                            .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(senderName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Line 4: Relay path
            if !point.pathNodeHexIDs.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.swap")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text("via " + point.pathNodeHexIDs.joined(separator: " → "))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            // Line 5: View in Chat link (for chat-type packets)
            if point.payloadType == .groupText || point.payloadType == .textMessage {
                Button {
                    onViewInChat?(point)
                } label: {
                    Label("View in Chat", systemImage: "bubble.left.and.bubble.right")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var signalIndicator: some View {
        let quality = point.snrQuality
        Image(systemName: "cellularbars", variableValue: quality.barLevel)
            .font(.caption)
            .foregroundStyle(snrColor)
    }

    private var snrColor: Color {
        switch point.snrQuality {
        case .excellent: .green
        case .good: .mint
        case .fair: .yellow
        case .poor: .orange
        case .veryPoor: .red
        case .unknown: .secondary
        }
    }

    private var routeColor: Color {
        switch point.routeType {
        case .flood, .tcFlood: .blue
        case .direct, .tcDirect: .green
        }
    }

    private func typeBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
