import Foundation
import MC1Services
import MeshWX
import SwiftUI

/// One narrative product, as the NWS wrote it.
///
/// Read from the model by group rather than held as a value, so a chunk that arrives while
/// this screen is open fills its hole in place.
struct WeatherTextDetailView: View {
  @Environment(\.appTheme) private var theme

  let model: WeatherToolModel
  let group: UInt8

  /// The app may ask once more for a reply with a hole in it, and only after 20 seconds
  /// (spec §8.1) — long enough for a chunk that is merely late.
  private static let askAgainAfter: TimeInterval = 20

  private var assembly: WeatherTextAssembly? {
    model.texts.first { $0.group == group }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let assembly {
          // These are NWS products, written in a fixed-width world: columns of rainfall
          // totals and hand-drawn separator lines only line up in a monospaced face.
          Text(displayText(assembly))
            .font(.system(.footnote, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)

          if !assembly.isComplete {
            missingFooter(assembly)
          }
        } else {
          Text(L10n.Weather.Weather.Text.gone)
            .foregroundStyle(.secondary)
        }
      }
      .padding()
    }
    .navigationTitle(assembly.map { WeatherFormatting.subjectTitle($0.subject) } ?? L10n.Weather.Weather.Text.section)
    .navigationBarTitleDisplayMode(.inline)
  }

  private func displayText(_ assembly: WeatherTextAssembly) -> String {
    assembly.orderedChunks
      .map { $0 ?? L10n.Weather.Weather.Text.missingPart }
      .joined()
  }

  private func missingFooter(_ assembly: WeatherTextAssembly) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Divider()
      Text(missingText(assembly))
        .font(.footnote)
        .foregroundStyle(.secondary)
      if let request = repeatRequest(assembly) {
        Button(L10n.Weather.Weather.Text.askAgain) {
          Task { await model.send(request) }
        }
        .buttonStyle(.bordered)
        .disabled(!canAskAgain(assembly))
      }
    }
  }

  private func missingText(_ assembly: WeatherTextAssembly) -> String {
    guard let first = assembly.missingIndexes.first else { return "" }
    return L10n.Weather.Weather.Text.missingFooter(Int(first) + 1, Int(assembly.total))
  }

  private func repeatRequest(_ assembly: WeatherTextAssembly) -> WeatherRequest? {
    WeatherTextRequests.repeatRequest(for: assembly.subject, lastRequests: model.lastTextRequests)
  }

  private func canAskAgain(_ assembly: WeatherTextAssembly) -> Bool {
    guard model.canSendRequests, !model.hasPendingRequest else { return false }
    return model.now.timeIntervalSince(assembly.lastReceivedAt) >= Self.askAgainAfter
  }
}
