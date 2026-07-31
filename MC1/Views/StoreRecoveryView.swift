import SwiftUI

/// Shown in place of the main UI when the SwiftData store cannot be opened.
///
/// Replaces what used to be a `fatalError` in `MC1App`: a store that fails migration is a
/// permanent condition, so crashing produced an unrecoverable launch loop with the user's
/// data still sitting on disk and no way to reach it. This screen keeps the app alive on a
/// throwaway in-memory container and offers the two moves that can actually help — retry,
/// or move the store aside and start fresh. Neither one deletes anything.
///
/// Deliberately self-contained: no `AppState` reads, no services, no navigation. The only
/// thing it borrows from the running app is the theme, so the failure screen doesn't look
/// like a different product.
struct StoreRecoveryView: View {
  let theme: Theme
  /// `localizedDescription` of the failure, surfaced only inside the collapsed detail.
  let errorDescription: String
  let onTryAgain: () async -> Void
  let onBackUpAndReset: () async -> Void

  @State private var isWorking = false
  @State private var showingResetConfirmation = false
  @State private var showingDetails = false

  var body: some View {
    ScrollView {
      VStack(spacing: 24) {
        Image(systemName: "externaldrive.badge.exclamationmark")
          .font(.system(size: 52))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)

        VStack(spacing: 8) {
          Text(L10n.Localizable.StoreRecovery.title)
            .font(.title2.bold())
          Text(L10n.Localizable.StoreRecovery.message)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)

        VStack(spacing: 12) {
          Button {
            perform(onTryAgain)
          } label: {
            buttonLabel(L10n.Localizable.Common.tryAgain)
          }
          .buttonStyle(.borderedProminent)

          Button {
            showingResetConfirmation = true
          } label: {
            buttonLabel(L10n.Localizable.StoreRecovery.backUpAndReset)
          }
          .buttonStyle(.bordered)

          Text(L10n.Localizable.StoreRecovery.BackUpAndReset.footnote)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .disabled(isWorking)

        DisclosureGroup(L10n.Localizable.StoreRecovery.details, isExpanded: $showingDetails) {
          Text(errorDescription)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        }
        .font(.footnote)
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 40)
      .frame(maxWidth: 480)
      .frame(maxWidth: .infinity)
    }
    .background(theme.surfaces?.canvas ?? Color(.systemGroupedBackground))
    // Destructive-by-confirmation: the reset moves live data out of the store the app is
    // pointed at, so it never happens on a single tap.
    .confirmationDialog(
      L10n.Localizable.StoreRecovery.Confirm.title,
      isPresented: $showingResetConfirmation,
      titleVisibility: .visible
    ) {
      Button(L10n.Localizable.StoreRecovery.backUpAndReset, role: .destructive) {
        perform(onBackUpAndReset)
      }
      Button(L10n.Localizable.Common.cancel, role: .cancel) {}
    } message: {
      Text(L10n.Localizable.StoreRecovery.Confirm.message)
    }
  }

  @ViewBuilder
  private func buttonLabel(_ title: String) -> some View {
    if isWorking {
      HStack(spacing: 8) {
        ProgressView()
        Text(L10n.Localizable.StoreRecovery.working)
      }
      .frame(maxWidth: .infinity)
    } else {
      Text(title)
        .frame(maxWidth: .infinity)
    }
  }

  /// Opening a container can take seconds on a large store, so both actions are async and
  /// the buttons stay disabled meanwhile rather than blocking the main thread.
  private func perform(_ action: @escaping () async -> Void) {
    guard !isWorking else { return }
    isWorking = true
    Task {
      await action()
      isWorking = false
    }
  }
}

#Preview {
  StoreRecoveryView(
    theme: .default,
    errorDescription: "The model configuration used to open the store is incompatible with the one that was used to create the store.",
    onTryAgain: {},
    onBackUpAndReset: {}
  )
}
