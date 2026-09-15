import MC1Services
import SwiftUI

/// The place and where its weather comes from (docs/MESHWX_UI.md §10):
///
///     Austin ▾
///     Your location · WX-AUS last heard 2 min ago   ⓘ
struct WeatherHeaderSection: View {
  @Environment(\.appTheme) private var theme

  let model: WeatherToolModel
  let snapshot: WeatherScreenSnapshot
  let onChoosePlace: () -> Void
  let onAbout: () -> Void
  let onOpenSettings: () -> Void

  private var header: WeatherCopy.Header {
    WeatherCopy.header(
      place: snapshot.place,
      placeState: model.placeState,
      sourceName: snapshot.source == nil ? nil : model.sourceName,
      // Heard live: a backlog drained at connect is not the bot being in range now.
      sourceHeardAt: snapshot.source?.lastLiveHeardAt,
      now: model.now)
  }

  var body: some View {
    let header = header
    Section {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Button(action: onChoosePlace) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              Text(header.title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.leading)
              Image(systemName: "chevron.down")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }
          }
          .buttonStyle(.borderless)
          .foregroundStyle(.primary)
          .accessibilityLabel(header.title)
          .accessibilityHint(L10n.Weather.Weather.Header.chooseHint)

          subtitle(header)
        }
        Spacer(minLength: 8)
        Button(action: onAbout) {
          Image(systemName: "info.circle")
            .font(.title3)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(L10n.Weather.Weather.About.title)
      }
      .padding(.vertical, 2)
      .accessibilityElement(children: .contain)
    }
    .themedRowBackground(theme)
  }

  @ViewBuilder
  private func subtitle(_ header: WeatherCopy.Header) -> some View {
    let text = Text(header.subtitle)
      .font(.subheadline)
      .foregroundStyle(.secondary)
    if let action = header.action {
      let button = Button {
        switch action {
        case .backToMyLocation: model.backToMyLocation()
        case .openSettings: onOpenSettings()
        }
      } label: {
        Text(action == .backToMyLocation
          ? L10n.Weather.Weather.Header.backToMyLocation
          : L10n.Weather.Weather.Header.settings)
          .font(.subheadline)
      }
      .buttonStyle(.borderless)
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 4) {
          text
          Text(verbatim: "·").font(.subheadline).foregroundStyle(.secondary).accessibilityHidden(true)
          button
        }
        VStack(alignment: .leading, spacing: 4) {
          text
          button
        }
      }
    } else if !header.subtitle.isEmpty {
      text
    }
  }
}

/// At most one banner, only when something blocks weather on your radio.
struct WeatherBannerSection: View {
  @Environment(\.appTheme) private var theme

  let model: WeatherToolModel
  let banner: WeatherScreenSnapshot.Banner
  let onAddChannel: () -> Void

  var body: some View {
    Section {
      VStack(alignment: .leading, spacing: 10) {
        Label {
          Text(WeatherCopy.banner(banner))
            .font(.subheadline)
        } icon: {
          Image(systemName: banner == .noBotHeard ? "antenna.radiowaves.left.and.right" : "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        }
        if banner == .channelMissing, model.isChannelSyncDone {
          HStack(spacing: 10) {
            Button(L10n.Weather.Weather.Banner.addChannel, action: onAddChannel)
              .buttonStyle(.bordered)
              .disabled(model.isAddingChannel)
            if model.isAddingChannel {
              ProgressView()
            }
          }
        }
      }
      .padding(.vertical, 2)
    }
    .themedRowBackground(theme)
  }
}
