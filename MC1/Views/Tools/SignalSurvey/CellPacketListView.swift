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
                            onNavigateToContact: onNavigateToContact
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

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Row 1: Time + badges
            HStack(spacing: 6) {
                Text(Self.timeFormatter.string(from: point.timestamp))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                typeBadge(point.routeType.displayName, color: routeColor)
                typeBadge(point.payloadType.displayName, color: .secondary)
            }

            // Row 2: RX/TX signal bars + values, compact horizontal
            HStack(spacing: 10) {
                // RX signal
                if let snr = point.snr {
                    HStack(spacing: 3) {
                        Image(systemName: "cellularbars", variableValue: point.snrQuality.barLevel)
                            .font(.system(size: 12))
                            .foregroundStyle(point.snrQuality.color)
                            .overlay(alignment: .topLeading) {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 4, weight: .black))
                                    .foregroundStyle(point.snrQuality.color)
                                    .offset(x: -1, y: -1)
                            }
                        Text(String(format: "%.0f", snr))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                // TX signal
                if let txSnr = point.txSnr {
                    HStack(spacing: 3) {
                        Image(systemName: "cellularbars", variableValue: point.txSnrQuality.barLevel)
                            .font(.system(size: 12))
                            .foregroundStyle(point.txSnrQuality.color)
                            .overlay(alignment: .topLeading) {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 4, weight: .black))
                                    .foregroundStyle(point.txSnrQuality.color)
                                    .offset(x: -1, y: -1)
                            }
                        Text(String(format: "%.0f", txSnr))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                // RSSI
                if let rssi = point.rssi {
                    Text("\(rssi)dBm")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                // Hops
                if point.hopCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.triangle.swap")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text("\(point.hopCount)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }

            // Row 3: Sender + relay path (combined, conditional)
            if point.fromContactName != nil || !point.pathNodeHexIDs.isEmpty {
                HStack(spacing: 4) {
                    if let senderName = point.fromContactName {
                        if let contact {
                            Button {
                                onNavigateToContact?(contact)
                            } label: {
                                HStack(spacing: 2) {
                                    Image(systemName: "person.fill")
                                        .font(.system(size: 8))
                                    Text(senderName)
                                        .font(.caption2)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 7))
                                }
                                .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                        } else {
                            HStack(spacing: 2) {
                                Image(systemName: "person.fill")
                                    .font(.system(size: 8))
                                Text(senderName)
                                    .font(.caption2)
                            }
                            .foregroundStyle(.secondary)
                        }
                    }

                    if !point.pathNodeHexIDs.isEmpty {
                        Text("via \(point.pathNodeHexIDs.joined(separator: "→"))")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()
                }
            }
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
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
