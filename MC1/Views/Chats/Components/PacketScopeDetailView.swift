import MC1Services
import SwiftUI

/// The observer network's view of one message's packet: which CoreScope observers
/// heard it, at what signal, and via which repeaters.
///
/// Reachable only through the message actions sheet, and only when the Packet
/// Scope opt-in is on and the message has a wire identity — the lookup is
/// user-initiated by design, never fired by rendering a conversation.
///
/// "Nobody heard it" is a real result, not an error: coverage is whatever the
/// configured instance's observers hear, so silence means the packet stayed
/// outside their range — a message can be delivered on the mesh and still be
/// unobserved. The empty state says so rather than implying failure.
struct PacketScopeDetailView: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss

  let message: MessageDTO

  /// How long after a message's send an open screen keeps polling: observers
  /// ingest over MQTT with seconds of lag, and echoes of a just-sent message can
  /// still be landing. Past this window the data is settled and one fetch is fair.
  private static let livePollWindow: TimeInterval = 180
  private static let livePollInterval: Duration = .seconds(6)

  @State private var observations: [PacketScopeObservation]?
  @State private var errorText: String?
  @State private var isRefreshing = false

  private let service = PacketScopeService()

  var body: some View {
    NavigationStack {
      List {
        content
      }
      .themedCanvas(theme)
      .navigationTitle(L10n.Localizable.PacketScope.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button(L10n.Localizable.Common.done) { dismiss() }
        }
        ToolbarItem(placement: .topBarLeading) {
          if isRefreshing {
            ProgressView()
          } else {
            Button {
              Task { await refresh() }
            } label: {
              Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel(L10n.Localizable.PacketScope.refresh)
          }
        }
      }
      .task { await liveRefreshLoop() }
    }
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    if let errorText {
      Section {
        Label(errorText, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.secondary)
      }
      .themedRowBackground(theme)
    } else if let observations {
      if observations.isEmpty {
        Section {
          Label(
            L10n.Localizable.PacketScope.notObserved,
            systemImage: "waveform.slash"
          )
          .foregroundStyle(.secondary)
        } footer: {
          Text(L10n.Localizable.PacketScope.notObservedFooter)
        }
        .themedRowBackground(theme)
      } else {
        Section {
          ForEach(observations) { observation in
            observationRow(observation)
          }
        } header: {
          Text(L10n.Localizable.PacketScope.observerCount(observations.count))
        } footer: {
          Text(L10n.Localizable.PacketScope.coverageFooter)
        }
        .themedRowBackground(theme)
      }
    } else {
      Section {
        HStack(spacing: 10) {
          ProgressView()
          Text(L10n.Localizable.PacketScope.loading)
            .foregroundStyle(.secondary)
        }
      }
      .themedRowBackground(theme)
    }
  }

  private func observationRow(_ observation: PacketScopeObservation) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(observation.observerName)
          .font(.subheadline.weight(.medium))
        Spacer()
        if let timestamp = observation.timestamp {
          Text(timestamp, style: .time)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      HStack(spacing: 12) {
        if let snr = observation.snr {
          Text("SNR \(snr, format: .number.precision(.fractionLength(0...1))) dB")
        }
        // rssi == 0 is CoreScope's "not reported", not a plausible reading.
        if let rssi = observation.rssi, rssi != 0 {
          Text("RSSI \(rssi) dBm")
        }
      }
      .font(.caption.monospacedDigit())
      .foregroundStyle(.secondary)

      if observation.pathHops.isEmpty {
        Text(L10n.Localizable.PacketScope.heardDirectly)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      } else {
        Text(
          L10n.Localizable.PacketScope.via(observation.pathHops.joined(separator: " → "))
        )
        .font(.caption2.monospaced())
        .foregroundStyle(.tertiary)
        .lineLimit(2)
      }
    }
    .padding(.vertical, 2)
  }

  // MARK: - Fetching

  private func refresh() async {
    guard let hash = message.packetContentHash, !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }
    do {
      let results = try await service.observations(for: [hash])
      observations = (results[hash] ?? []).sorted { lhs, rhs in
        (lhs.snr ?? -.infinity) > (rhs.snr ?? -.infinity)
      }
      errorText = nil
    } catch {
      // A failed refresh never blanks data already on screen.
      if observations == nil {
        errorText = error.localizedDescription
      }
    }
  }

  /// One fetch always; then, while the message is fresh enough that observers may
  /// still be ingesting it, keep polling so the user can watch coverage build.
  /// Cancellation (screen dismissed) ends the loop via the sleep throwing.
  private func liveRefreshLoop() async {
    await refresh()
    while Date().timeIntervalSince(message.createdAt) < Self.livePollWindow {
      do { try await Task.sleep(for: Self.livePollInterval) } catch { return }
      await refresh()
    }
  }
}
