// MC1/Views/Chats/Components/MessagePathContent.swift
import CoreLocation
import MC1Services
import SwiftUI

/// Inline content for message path visualization, extracted from MessagePathSheet.
/// Shows sender, intermediate hops, receiver, raw path hex, and a copy button.
///
/// All hop resolution reads from `viewModel.resolvedHops` (the single source of truth).
/// The view model's `resolveAllHops` must be called before this view renders
/// (typically by the parent view's `.task` or `.onChange`).
struct MessagePathContent: View {
    let message: MessageDTO
    let viewModel: MessagePathViewModel
    let receiverName: String
    let userLocation: CLLocation?
    var onReplyWithRoute: ((String, ShareFormat) -> Void)?

    @State private var copyHapticTrigger = 0
    @State private var showingRouteMap = false
    @State private var showingShareFormatPicker = false
    @State private var disambiguatingHop: Data?

    /// Route info text for the reply button, using the resolved distance.
    private var routeInfoText: String? {
        let hopCount = Int(message.pathLength & 0x3F)
        guard hopCount > 0 else { return nil }
        let pathHex = message.pathNodesHex.joined(separator: ",")
        guard !pathHex.isEmpty else { return nil }
        let hopWord = hopCount == 1 ? "hop" : "hops"
        let distancePart = viewModel.routeDistanceText.map { " \($0)" } ?? ""
        return "RX via \(pathHex). \(hopCount) \(hopWord)\(distancePart)"
    }

    /// Binding for the disambiguation sheet (true when disambiguatingHop is set).
    private var disambiguationBinding: Binding<Bool> {
        Binding(
            get: { disambiguatingHop != nil },
            set: { if !$0 { disambiguatingHop = nil } }
        )
    }

    var body: some View {
        if viewModel.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .center)
                .padding()
        } else if message.pathNodes == nil {
            ContentUnavailableView(
                L10n.Chats.Chats.Path.Unavailable.title,
                systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                description: Text(L10n.Chats.Chats.Path.Unavailable.description)
            )
        } else {
            // Sender
            PathHopRowView(
                hopType: .sender,
                nodeName: viewModel.senderName(for: message),
                nodeID: viewModel.senderNodeID(for: message),
                snr: nil
            )

            // Intermediate hops — read from the view model's cached resolution
            ForEach(Array(viewModel.resolvedHops.enumerated()), id: \.offset) { index, entry in
                PathHopRowView(
                    hopType: .intermediate(index + 1),
                    nodeName: entry.resolved.name,
                    nodeID: entry.hex,
                    snr: nil,
                    isAmbiguous: entry.resolved.isAmbiguous,
                    onTapAmbiguous: {
                        disambiguatingHop = entry.hashBytes
                    }
                )
            }

            // Receiver
            PathHopRowView(
                hopType: .receiver,
                nodeName: receiverName,
                nodeID: nil,
                snr: message.snr
            )
            .sheet(isPresented: disambiguationBinding) {
                if let hopData = disambiguatingHop {
                    // Read currentName from the cached results (same source of truth)
                    let currentName = viewModel.resolvedByHex[hopData.hexString()]?.name
                        ?? L10n.Chats.Chats.Path.Hop.unknown
                    HopDisambiguationSheet(
                        hashBytes: hopData,
                        candidates: viewModel.candidates(for: hopData, userLocation: userLocation),
                        currentName: currentName,
                        onSelect: { name in
                            viewModel.setOverride(
                                for: hopData, name: name,
                                message: message, userLocation: userLocation
                            )
                        }
                    )
                }
            }

            // Raw path hex + copy button
            if !viewModel.resolvedHops.isEmpty {
                HStack {
                    Button(L10n.Chats.Chats.Path.copyButton, systemImage: "doc.on.doc") {
                        copyHapticTrigger += 1
                        UIPasteboard.general.string = message.pathStringForClipboard
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L10n.Chats.Chats.Path.copyAccessibility)
                    .accessibilityHint(L10n.Chats.Chats.Path.copyHint)

                    Text(message.pathString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)

                    Spacer()

                    // Distance from resolved route
                    if let distance = viewModel.routeDistanceText {
                        Text(distance)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 8)
                .sensoryFeedback(.success, trigger: copyHapticTrigger)

                // View Route on Map
                Button {
                    showingRouteMap = true
                } label: {
                    Label(
                        L10n.Chats.Chats.Path.RouteMap.viewOnMap,
                        systemImage: "map"
                    )
                }
                .buttonStyle(.borderless)
                .padding(.top, 4)
                .sheet(isPresented: $showingRouteMap) {
                    MessageRouteMapSheet(message: message, pathViewModel: viewModel)
                }

                // Reply with Route
                if let onReplyWithRoute, let routeInfo = routeInfoText {
                    Button {
                        showingShareFormatPicker = true
                    } label: {
                        Label("Reply with Route", systemImage: "arrowshape.turn.up.left")
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, 4)
                    .sheet(isPresented: $showingShareFormatPicker) {
                        ShareFormatPickerSheet { format in
                            onReplyWithRoute(routeInfo, format)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Hop Disambiguation Sheet

/// Sheet that lets the user pick from ambiguous repeater candidates for a hop.
struct HopDisambiguationSheet: View {
    let hashBytes: Data
    let candidates: [HopCandidate]
    let currentName: String
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Multiple repeaters match the prefix **\(hashBytes.hexString())**. Choose the correct one:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Candidates") {
                    ForEach(candidates) { candidate in
                        Button {
                            onSelect(candidate.name)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(candidate.name)
                                        .font(.body)
                                        .foregroundStyle(.primary)

                                    HStack(spacing: 12) {
                                        if let distance = candidate.distanceFromUser {
                                            Label(
                                                formatDistance(distance),
                                                systemImage: "location"
                                            )
                                        } else if !candidate.hasLocation {
                                            Label(
                                                "No location",
                                                systemImage: "location.slash"
                                            )
                                        }

                                        Label(candidate.lastHeard, systemImage: "clock")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if candidate.name == currentName {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Choose Repeater")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func formatDistance(_ meters: Double) -> String {
        let measurement = Measurement(value: meters, unit: UnitLength.meters)
        if Locale.current.measurementSystem == .metric {
            if meters >= 1000 {
                return measurement.converted(to: .kilometers).formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(1))))
            }
            return measurement.formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(0))))
        } else {
            let miles = measurement.converted(to: .miles)
            if miles.value >= 0.1 {
                return miles.formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(1))))
            }
            return measurement.converted(to: .feet).formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(0))))
        }
    }
}
