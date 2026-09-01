import CoreLocation
import MC1Services
import SwiftUI

/// The observer network's view of one message's packet: which CoreScope observers
/// heard it, how strongly, and by which repeaters.
///
/// Reachable only through the message actions sheet, and only when the Packet
/// Scope opt-in is on and the message has a wire identity — the lookup is
/// user-initiated by design, never fired by rendering a conversation.
///
/// "Nobody heard it" is a real result, not an error: coverage is whatever the
/// configured instance's observers hear, so silence means the packet stayed
/// outside their range. A message can be delivered on the mesh and never observed,
/// and the empty state says exactly that rather than implying a failed send.
struct PacketScopeDetailView: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase

  let message: MessageDTO
  /// The app's own hop-name resolver — the same one the path screen uses, so a
  /// repeater is called the same thing here as everywhere else, complete with the
  /// proximity disambiguation that keeps colliding short hashes apart.
  let pathViewModel: MessagePathViewModel
  /// Reference position for that disambiguation; the host passes the same
  /// stamp-first reference the repeats map uses.
  let userLocation: CLLocation?

  /// Observers ingest over MQTT with seconds of lag and echoes keep arriving, so a
  /// just-sent message is still gaining coverage while the sheet is open. Poll
  /// only inside that window, and only while the message is fresh.
  private static let livePollWindow: TimeInterval = 180
  private static let pollInterval: Duration = .seconds(6)
  /// Consecutive unchanged polls before giving up early. Coverage that has not
  /// moved in ~18s has settled; continuing would spend battery to re-learn it.
  private static let quietPollsBeforeStopping = 3
  /// Consecutive failures before the loop stops retrying. The endpoint is public,
  /// unauthenticated and Cloudflare-fronted with no server-side rate limiting, so
  /// pacing is entirely this client's responsibility — hammering it 30 times
  /// through a challenge or an outage is how an IP earns a block.
  private static let failuresBeforeStopping = 3

  @State private var receptions: [PacketScopeReception]?
  @State private var summary: PacketScopeSummary?
  @State private var errorText: String?
  @State private var isRefreshing = false
  /// Consecutive failed refreshes; drives the loop's give-up and its backoff.
  @State private var consecutiveFailures = 0

  private var service: PacketScopeService {
    PacketScopeService()
  }

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
    } else if let receptions, let summary {
      if receptions.isEmpty {
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
        summarySection(summary)
        Section {
          ForEach(receptions) { reception in
            receptionRow(reception)
          }
        } header: {
          Text(L10n.Localizable.PacketScope.observerCount(summary.observerCount))
        } footer: {
          VStack(alignment: .leading, spacing: 4) {
            Text(L10n.Localizable.PacketScope.coverageFooter)
            // A retry puts a *different* packet on the air each attempt, and this
            // row is stamped with whichever attempt's echo arrived first. Saying
            // so beats implying the coverage below describes all of them.
            if message.sendCount > 1 {
              Text(L10n.Localizable.PacketScope.retriedFooter(message.sendCount))
            }
          }
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

  /// What the mesh as a whole did with this packet, above the per-observer detail.
  private func summarySection(_ summary: PacketScopeSummary) -> some View {
    Section {
      if let best = summary.bestSNR {
        LabeledContent(
          L10n.Localizable.PacketScope.bestSignal,
          value: "\(best.formatted(.number.precision(.fractionLength(0...1)))) dB"
        )
      }
      if let hops = summary.shortestHopCount {
        LabeledContent(
          L10n.Localizable.PacketScope.shortestRoute,
          value: hops == 0
            ? L10n.Localizable.PacketScope.direct
            : L10n.Localizable.PacketScope.hopCount(hops)
        )
      }
      // Only meaningful with two or more timestamped receptions; the model returns
      // nil rather than a misleading zero.
      if let spread = summary.propagationSpread {
        LabeledContent(
          L10n.Localizable.PacketScope.propagation,
          value: L10n.Localizable.PacketScope.spreadSeconds(
            spread.formatted(.number.precision(.fractionLength(0...1)))
          )
        )
      }
      // Receptions exceed observers whenever one observer heard the packet by more
      // than one route — that ratio is a redundancy signal worth showing plainly.
      if summary.receptionCount > summary.observerCount {
        LabeledContent(
          L10n.Localizable.PacketScope.receptions,
          value: "\(summary.receptionCount)"
        )
      }
    }
    .themedRowBackground(theme)
  }

  private func receptionRow(_ reception: PacketScopeReception) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(reception.observerName)
          .font(.subheadline.weight(.medium))
        Spacer()
        if let firstHeard = reception.firstHeard {
          Text(firstHeard, style: .time)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      HStack(spacing: 12) {
        if let snr = reception.bestSNR {
          Text("SNR \(snr, format: .number.precision(.fractionLength(0...1))) dB")
        }
        if let rssi = reception.bestRSSI {
          Text("RSSI \(rssi) dBm")
        }
        if reception.receptionCount > 1 {
          Text(L10n.Localizable.PacketScope.timesHeard(reception.receptionCount))
        }
      }
      .font(.caption.monospacedDigit())
      .foregroundStyle(.secondary)

      ForEach(Array(reception.routes.enumerated()), id: \.offset) { _, route in
        routeLine(route)
      }
    }
    .padding(.vertical, 2)
  }

  @ViewBuilder
  private func routeLine(_ route: PacketScopeReception.Route) -> some View {
    if route.hops.isEmpty {
      Text(L10n.Localizable.PacketScope.heardDirectly)
        .font(.caption2)
        .foregroundStyle(.tertiary)
    } else {
      Text(L10n.Localizable.PacketScope.via(hopNames(for: route)))
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(2)
    }
  }

  /// Names the hops the way the rest of the app does.
  ///
  /// The local resolver is tried first — it is free, works offline, and matches
  /// what the path screen and repeats map call the same repeater. A name it is not
  /// certain of is marked with `~`, mirroring the app's fallback convention rather
  /// than presenting a guess as fact. Only when the phone has never heard the
  /// repeater at all does the short wire hash stand in.
  private func hopNames(for route: PacketScopeReception.Route) -> String {
    route.hops.enumerated().map { index, hop in
      guard let hashBytes = Data(hexString: hop) else { return hop }
      let resolution = pathViewModel.repeaterResolution(
        for: hashBytes,
        userLocation: userLocation
      )
      switch resolution.matchKind {
      case .exact:
        return resolution.displayName
      case .fallback:
        return "~\(resolution.displayName)"
      case .unresolved:
        // The server may know a repeater this phone has never heard. Its resolved
        // public key is exact where a short hash can collide, so prefer its first
        // 4 hex over the wire hash when the server had an answer for this slot —
        // it often does not (roughly a third of slots come back null).
        if index < route.resolvedHops.count,
           let pubkey = route.resolvedHops[index] {
          return String(pubkey.prefix(4)).uppercased()
        }
        return hop
      }
    }
    .joined(separator: " → ")
  }

  // MARK: - Fetching

  private func refresh() async {
    guard let hash = message.packetContentHash, !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }
    do {
      let results = try await service.observations(for: [hash])
      let observations = results[hash] ?? []
      receptions = PacketScopeFold.receptions(from: observations)
      summary = PacketScopeFold.summary(from: observations)
      errorText = nil
      consecutiveFailures = 0
    } catch {
      consecutiveFailures += 1
      // A failed refresh never blanks data already on screen.
      if receptions == nil {
        errorText = error.localizedDescription
      }
    }
  }

  /// One fetch always; then, while the message is fresh enough that observers may
  /// still be ingesting it, keep polling so coverage builds in front of the reader.
  ///
  /// Stops early on three unchanged polls — coverage that has settled will not
  /// un-settle, and the alternative is 30 requests for a sheet left open. Also
  /// pauses while the app is backgrounded: nobody is reading, and a poll there
  /// spends radio for a screen no one sees. Cancellation (the sheet closing)
  /// exits through the sleep.
  private func liveRefreshLoop() async {
    await refresh()
    var quietPolls = 0
    var lastReceptionCount = summary?.receptionCount ?? 0

    while isWithinLiveWindow,
          quietPolls < Self.quietPollsBeforeStopping,
          consecutiveFailures < Self.failuresBeforeStopping {
      // Back off on failure rather than retrying at full cadence into whatever is
      // going wrong; a run of successes polls at the normal interval.
      let interval = Self.pollInterval * (1 << consecutiveFailures)
      do { try await Task.sleep(for: interval) } catch { return }
      guard scenePhase == .active else { continue }
      await refresh()

      let current = summary?.receptionCount ?? 0
      quietPolls = current == lastReceptionCount ? quietPolls + 1 : 0
      lastReceptionCount = current
    }
  }

  /// Whether the message is new enough that observers may still be ingesting it.
  ///
  /// Clamped at both ends: `createdAt` is decoded unvalidated from backups, and a
  /// timestamp in the future would otherwise keep this loop polling for as long as
  /// the sheet stayed open.
  private var isWithinLiveWindow: Bool {
    let age = Date().timeIntervalSince(message.createdAt)
    return age >= 0 && age < Self.livePollWindow
  }
}
