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
                    hopCountSection
                    readingTheMapSection
                    communitySection
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
            Text("Sends probe packets and listens for responses. A response confirms the repeater heard you AND you heard it — a real bidirectional link.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                probeStep(number: 1, text: "Channel message — sends a message on your selected channel. A heard-repeat response proves direct 2-way connectivity.")
                probeStep(number: 2, text: "Deep Scan (optional) — also sends discover and flood trace requests to map gateway SNR and mesh depth beyond direct reach.")
            }

            Text("Probe frequency controls how often probes are sent based on distance traveled. Choose Driving, Dense, Normal, or Sparse to match your speed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var hopCountSection: some View {
        infoSection(
            icon: "point.3.connected.trianglepath.dotted",
            iconColor: .cyan,
            title: "Understanding Hop Count"
        ) {
            hopRow(hops: "1 hop", description: "Direct bidirectional link — the repeater heard you and responded directly. This is the strongest confirmation of connectivity.")
            hopRow(hops: "2+ hops", description: "Your probe reached the first repeater, which relayed it deeper into the mesh. You can see downstream repeaters, but they may not hear you directly.")
            hopRow(hops: "0-hop relay", description: "The repeater listed at hop 0 is the one that forwarded the response to your device — your direct radio neighbor.")
        }
    }

    private var readingTheMapSection: some View {
        infoSection(
            icon: "map.fill",
            iconColor: .blue,
            title: "Reading the Map"
        ) {
            VStack(alignment: .leading, spacing: 6) {
                mapLegendRow(label: "Connected (2-way)", color: .green, icon: "arrow.left.arrow.right",
                             description: "Repeaters confirmed via direct probe response — strongest proof of connectivity")
                mapLegendRow(label: "Mesh Reach", color: .cyan, icon: "point.3.connected.trianglepath.dotted",
                             description: "Repeaters reached via multi-hop relay — not direct 2-way")
                mapLegendRow(label: "Heard (1-way)", color: .secondary, icon: "ear",
                             description: "Repeaters detected passively — reception only, no TX confirmation")
                mapLegendRow(label: "Dead Zone", color: .gray, icon: "hexagon",
                             description: "Active probes were sent but no response was received within the timeout window")
            }

            Text("Cell colors reflect signal quality (SNR): green = excellent, yellow = good, orange = fair, red = poor. Tap any cell for detailed stats including packet counts and repeater info.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var communitySection: some View {
        infoSection(
            icon: "globe.americas.fill",
            iconColor: .cyan,
            title: "Community Map"
        ) {
            Text("Aggregated survey data from all contributors, shown as a faded overlay behind your own data.")
                .font(.caption)
                .foregroundStyle(.secondary)

            bulletPoint("Toggle the globe icon on the map to show/hide community data")
            bulletPoint("Filter community data by coverage type, repeater, and time range")
            bulletPoint("Enable live upload to share data to the community map in real time")
            bulletPoint("Upload completed sessions via the menu to contribute")
        }
    }

    private var tipsSection: some View {
        infoSection(
            icon: "lightbulb.fill",
            iconColor: .yellow,
            title: "Tips"
        ) {
            bulletPoint("Enable active probing with a channel to confirm bidirectional connectivity")
            bulletPoint("Use Deep Scan mode at slower speeds for detailed mesh depth data")
            bulletPoint("Use Driving mode when traveling at speed for denser coverage")
            bulletPoint("Enable live upload to share survey data to the community map in real time")
            bulletPoint("Dead zones appear as gray dashed cells where probes got no response")
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

    private func hopRow(hops: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(hops)
                .font(.caption.weight(.semibold))
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
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
}
