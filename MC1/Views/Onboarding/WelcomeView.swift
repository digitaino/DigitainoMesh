import SwiftUI

struct WelcomeView: View {
  @Environment(\.appState) private var appState

  /// TestFlight builds ship with a sandbox receipt; App Store builds do not.
  /// Used to point beta testers at TestFlight's own feedback channel.
  private var isTestFlightBuild: Bool {
    Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
  }

  var body: some View {
    VStack(spacing: OnboardingMetrics.cardSpacing * 2) {
      Spacer()

      MeshAnimationView()
        .frame(height: OnboardingMetrics.heroSize)
        .padding(.horizontal)

      VStack(spacing: 12) {
        Text(L10n.Onboarding.Welcome.title)
          .font(.largeTitle)
          .bold()
          .accessibilityHeading(.h1)

        Text(L10n.Onboarding.Welcome.subtitle)
          .font(.title3)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal)

        Text(L10n.Onboarding.Welcome.Fork.attribution)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      Spacer()

      VStack(spacing: OnboardingMetrics.compactSpacing) {
        Label {
          Text(
            isTestFlightBuild
              ? L10n.Onboarding.Welcome.Fork.feedbackTestFlight
              : L10n.Onboarding.Welcome.Fork.feedbackEmail
          )
        } icon: {
          Image(systemName: "envelope")
        }
        .multilineTextAlignment(.center)

        if !isTestFlightBuild {
          Link(destination: URL(string: "https://github.com/digitaino/PocketMesh")!) {
            Label(
              L10n.Onboarding.Welcome.Fork.github,
              systemImage: "chevron.left.forwardslash.chevron.right"
            )
          }
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal)

      Button {
        appState.onboarding.onboardingPath.append(.permissions)
      } label: {
        Text(L10n.Onboarding.Welcome.getStarted)
          .font(.headline)
          .frame(maxWidth: .infinity)
          .padding()
      }
      .liquidGlassProminentButtonStyle()
      .padding(.horizontal)
      .padding(.bottom)
    }
  }
}

#Preview {
  WelcomeView()
    .environment(\.appState, AppState())
}
