import SwiftUI

/// First screen of onboarding - introduces the app
struct WelcomeView: View {
    @Environment(\.appState) private var appState
    @Environment(\.openURL) private var openURL

    private var isTestFlightBuild: Bool {
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    }

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Animated mesh visualization
            MeshAnimationView()
                .padding(.horizontal)

            // App title
            VStack(spacing: 12) {
                Text(L10n.Onboarding.Welcome.title)
                    .font(.largeTitle)
                    .bold()

                Text(L10n.Onboarding.Welcome.subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)

                // Fork attribution
                Text("A fork of [PocketMesh](https://github.com/Avi0n/PocketMesh)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .tint(.secondary)
            }

            // Features list
            VStack(alignment: .leading, spacing: 20) {
                FeatureRow(
                    icon: "arrow.trianglehead.branch",
                    title: L10n.Onboarding.Welcome.Feature.MultiHop.title,
                    description: L10n.Onboarding.Welcome.Feature.MultiHop.description
                )

                FeatureRow(
                    icon: "person.3.fill",
                    title: L10n.Onboarding.Welcome.Feature.Community.title,
                    description: L10n.Onboarding.Welcome.Feature.Community.description
                )
            }
            .padding(.horizontal)

            Spacer()

            // Feedback & contact
            VStack(spacing: 8) {
                if isTestFlightBuild {
                    Label {
                        Text("Send feedback via TestFlight or email [mesh@digitaino.com](mailto:mesh@digitaino.com)")
                            .font(.caption)
                    } icon: {
                        Image(systemName: "envelope.fill")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                } else {
                    Label {
                        Text("Feedback: [mesh@digitaino.com](mailto:mesh@digitaino.com)")
                            .font(.caption)
                    } icon: {
                        Image(systemName: "envelope.fill")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }

                Button {
                    openURL(URL(string: "https://github.com/digitaino/PocketMesh")!)
                } label: {
                    Label {
                        Text("GitHub")
                            .font(.caption)
                    } icon: {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
            }

            // Continue button
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

// MARK: - Feature Row

private struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(.tint.opacity(0.1), in: .circle)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}

#Preview {
    WelcomeView()
        .environment(\.appState, AppState())
}
