import SwiftUI

/// Educational sheet explaining how MeshCore signal surveys work,
/// the difference between active and passive modes, and how to read the map.
struct SurveyInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    asymmetrySection
                    passiveSurveySection
                    activeSurveySection
                    probeSettingsSection
                    cellDetailSection
                    signalColumnsSection
                    readingTheMapSection
                    communitySection
                    sessionManagementSection
                    tipsSection
                }
                .padding()
            }
            .navigationTitle("How It Works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Sections

    private var asymmetrySection: some View {
        infoSection(
            icon: "arrow.left.arrow.right",
            iconColor: .orange,
            title: "MeshCore Radio is Asymmetric"
        ) {
            Text("Hearing a repeater does not mean the repeater can hear you.")
                .font(.subheadline)
                .fontWeight(.medium)

            Text("Radio links are not always symmetric. A repeater may broadcast with more power or from a higher elevation, so its signal reaches you — but your device's lower power or obstructed position may prevent your signal from reaching it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("This is why the survey distinguishes between one-way reception (passive) and confirmed two-way connectivity (active).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var passiveSurveySection: some View {
        infoSection(
            icon: "ear",
            iconColor: .yellow,
            title: "Passive Survey (RX Only)"
        ) {
            Text("Listens for mesh traffic without transmitting. Records packets that your device receives from nearby repeaters.")
                .font(.caption)
                .foregroundStyle(.secondary)

            bulletPoint("Proves a repeater's signal reaches your location")
            bulletPoint("Does NOT prove you can reach the repeater")
            bulletPoint("Works silently — no transmissions added to the mesh")
            bulletPoint("Good for mapping general coverage areas")
        }
    }

    private var activeSurveySection: some View {
        infoSection(
            icon: "bolt.horizontal.fill",
            iconColor: .green,
            title: "Active Survey (TX + RX)"
        ) {
            Text("Sends a channel message and listens for responses. A heard-repeat response confirms the repeater heard you AND you heard it — a real bidirectional link.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Every Probe Sends")
                .font(.caption.weight(.semibold))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 8) {
                probeStep(number: 1, text: "Discover request — asks nearby repeaters to identify themselves. Zero-hop only, never floods the network. Responses include TX signal data (how well they hear you).")
                probeStep(number: 2, text: "Trace — maps multi-hop paths and mesh depth. Propagates hop-by-hop with a natural limit, not a full flood.")
            }

            Text("Channel Flood Messages (Optional)")
                .font(.caption.weight(.semibold))
                .padding(.top, 2)

            Text("Channel messages are the only probe type that floods the entire mesh network. Use \"Flood Messages per Cell\" to limit how many are sent per hex cell (1-3), or set to Off to rely on discover + trace only. When multiple floods are allowed, they're spaced evenly across your estimated cell transit time using GPS speed — so they test the link at different positions within the cell. A 0-hop heard repeat of your channel message proves direct 2-way connectivity. Tap the Probe button to manually send a flood message anytime.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var probeSettingsSection: some View {
        infoSection(
            icon: "wave.3.right",
            iconColor: .orange,
            title: "Probe Settings"
        ) {
            Text("Control how and when probes are sent during an active survey.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                settingRow(label: "Private Channel", description: "Select or create a dedicated channel for probe messages. Avoids cluttering public conversations.")
                settingRow(label: "Probe Frequency", description: "Distance-based trigger for automatic probes. Faster presets send probes more often.")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Frequency Presets")
                    .font(.caption.weight(.semibold))
                #if DEBUG
                frequencyRow(name: "Driving", description: "~15m trigger — best for high-speed travel (debug only)")
                frequencyRow(name: "Dense", description: "~25m trigger — walking in urban areas (debug only)")
                #endif
                frequencyRow(name: "Normal", description: "~50m trigger — walking, cycling, e-bike")
                frequencyRow(name: "Sparse", description: "~100m trigger — driving, fast cycling")
            }

            Text("You can also send a manual probe at any time by tapping the wave icon in the toolbar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var cellDetailSection: some View {
        infoSection(
            icon: "square.on.square",
            iconColor: .purple,
            title: "Cell Detail Card"
        ) {
            Text("Tap any hex cell on the map to see detailed stats. The card shows signal quality, packet counts, and repeater connectivity.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                mapLegendRow(label: "Connected (2-way)", color: .green, icon: "arrow.left.arrow.right",
                             description: "Repeaters confirmed via direct heard-repeat or discover response")
                mapLegendRow(label: "Mesh Reach", color: .cyan, icon: "point.3.connected.trianglepath.dotted",
                             description: "Repeaters reached via multi-hop relay — not direct 2-way")
                mapLegendRow(label: "Heard (1-way)", color: .secondary, icon: "ear",
                             description: "Repeaters detected passively — reception only")
            }

            Text("Tap a repeater chip to filter all stats to that repeater. Both RX and TX signal columns update to show only data for the selected repeater.")
                .font(.caption)
                .foregroundStyle(.secondary)

            bulletPoint("View individual packets with timestamps and signal data")
            bulletPoint("Probe success rate shows what percentage of probes got a response")
            bulletPoint("A Mesh Gateway section shows which repeater has the best connection to the broader mesh — measured by reachable nodes, hop depth, and path SNR (from trace data)")
        }
    }

    private var signalColumnsSection: some View {
        infoSection(
            icon: "cellularbars",
            iconColor: .green,
            title: "RX & TX Signal"
        ) {
            Text("The cell detail card shows two signal columns side by side.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                signalExplainer(
                    direction: "RX Signal",
                    arrow: "arrow.down",
                    description: "How well you hear the repeater. Includes SNR (dB), RSSI (dBm), and SNR range. Available from all packet types."
                )
                signalExplainer(
                    direction: "TX Signal",
                    arrow: "arrow.up",
                    description: "How well the repeater hears you. Only discover responses carry TX signal data (always sent with each probe). Heard repeats prove 2-way connectivity but don't include TX quality."
                )
            }

            Text("Heard repeats are the most important signal — they confirm a repeater received your message and relayed it. The TX column appears when discover response data is available (sent with every probe).")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("When a non-direct repeater (mesh reach or heard-only) is selected, the TX column shows \"—\" because TX data only applies to direct 2-way links.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var readingTheMapSection: some View {
        infoSection(
            icon: "map.fill",
            iconColor: .blue,
            title: "Reading the Map"
        ) {
            Text("The hex grid divides the area into ~100m cells. Each cell is colored by signal quality.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                colorRow(color: .green, label: "Excellent signal")
                colorRow(color: .yellow, label: "Good signal")
                colorRow(color: .orange, label: "Fair signal")
                colorRow(color: .red, label: "Poor signal")
                colorRow(color: .gray, label: "Dead zone — probes sent, no response")
            }

            Text("When active probing is enabled, cells with direct 2-way connectivity are colored by the strongest repeater's SNR. Passive-only cells use the average SNR of all received packets.")
                .font(.caption)
                .foregroundStyle(.secondary)

            bulletPoint("Switch between Grid Heatmap and Point Cloud visualization modes")
            bulletPoint("Use the filter menu to show All, Passive Only, or Active Only data")
        }
    }

    private var communitySection: some View {
        infoSection(
            icon: "globe.americas.fill",
            iconColor: .cyan,
            title: "Community Map"
        ) {
            Text("Aggregated anonymous survey data from all contributors, shown as a faded overlay behind your personal data.")
                .font(.caption)
                .foregroundStyle(.secondary)

            bulletPoint("Toggle the globe icon on the map to show or hide community data")
            bulletPoint("Filter community data by coverage type (all, active, passive)")
            bulletPoint("Filter by specific repeater to see one repeater's coverage")
            bulletPoint("Filter by time range (all time, past week, past month)")

            Text("Contributing Data")
                .font(.caption.weight(.semibold))
                .padding(.top, 2)

            bulletPoint("Enable Live Upload to share data to the community map in real time during a survey")
            bulletPoint("Upload completed sessions from the completion summary or session list")
            bulletPoint("Use Batch Upload to upload multiple sessions at once")
            bulletPoint("All uploaded data is anonymized — no GPS coordinates, sender identity, or message content")
        }
    }

    private var sessionManagementSection: some View {
        infoSection(
            icon: "list.bullet.rectangle",
            iconColor: .indigo,
            title: "Sessions & History"
        ) {
            Text("Each survey run is saved as a session. Browse and manage sessions from the session list menu.")
                .font(.caption)
                .foregroundStyle(.secondary)

            bulletPoint("Pause and resume an active survey without losing data")
            bulletPoint("View previous sessions and their coverage data on the map")
            bulletPoint("Session completion summary shows detailed stats and personal records")
            bulletPoint("Personal records track your best survey achievements with trophy badges")
            bulletPoint("Export session data as anonymized JSON for sharing or analysis")
        }
    }

    private var tipsSection: some View {
        infoSection(
            icon: "lightbulb.fill",
            iconColor: .yellow,
            title: "Tips"
        ) {
            bulletPoint("Every probe sends discover + trace automatically (lightweight, no flood)")
            bulletPoint("Set Flood Messages per Cell to 1-2 for network-friendly 2-way proof")
            bulletPoint("Use the manual Probe button to send a flood message on demand")
            bulletPoint("Enable Live Upload to share data to the community map in real time")
            bulletPoint("Tap a repeater chip in the cell detail card to see per-repeater stats")
            bulletPoint("Dead zones show where probes were sent but got no response")
            bulletPoint("Passive data is still valuable — it maps where repeater signals reach")
            bulletPoint("Survey the same area multiple times for more reliable data")
        }
    }

    // MARK: - Helpers

    private func infoSection<Content: View>(
        icon: String,
        iconColor: Color,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(title)
                    .font(.headline)
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
            }

            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func bulletPoint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func probeStep(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.caption2.weight(.bold))
                .frame(width: 18, height: 18)
                .background(Color.green.opacity(0.2), in: Circle())
                .foregroundStyle(.green)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func mapLegendRow(label: String, color: Color, icon: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption.weight(.semibold))
                Text(description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func settingRow(label: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 2)
    }

    private func frequencyRow(name: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(name)
                .font(.caption2.weight(.medium))
                .frame(width: 56, alignment: .leading)
            Text(description)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func signalExplainer(direction: String, arrow: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: arrow)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(direction)
                    .font(.caption.weight(.semibold))
                Text(description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func colorRow(color: Color, label: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
