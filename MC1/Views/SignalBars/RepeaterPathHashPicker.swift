import MC1Services
import SwiftUI

/// Quick control for the radio's path hash width, next to the signal table it changes the
/// meaning of.
///
/// Wider hashes make hops unambiguous — a 1-byte hash has only 256 values, so collisions in a
/// dense area are routine — at the cost of bytes in every packet's path. That trade-off is
/// worth making while looking at the repeater table, which is why the control is duplicated
/// here from `PathHashModeSection` in Advanced Settings rather than only living there. Both
/// write the same device setting and read the same device record, so they cannot disagree.
///
/// Only shown on firmware that implements the setting.
struct RepeaterPathHashPicker: View {
  @Environment(\.appState) private var appState

  @State private var isApplying = false

  private var deviceMode: UInt8 {
    appState.connectedDevice?.pathHashMode ?? 0
  }

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "number")
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)

      Text(L10n.Settings.PathHashMode.label)
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)

      Spacer(minLength: 4)

      if isApplying {
        ProgressView().controlSize(.mini)
      }

      Picker(L10n.Settings.PathHashMode.label, selection: Binding(
        get: { deviceMode },
        set: { apply($0) }
      )) {
        Text(L10n.Settings.PathHashMode.oneByte).tag(UInt8(0))
        Text(L10n.Settings.PathHashMode.twoBytes).tag(UInt8(1))
        Text(L10n.Settings.PathHashMode.threeBytes).tag(UInt8(2))
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 116)
      .disabled(isApplying)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  /// Writes the new width and lets the device's own confirmation drive the picker.
  ///
  /// Nothing is held locally on failure: the selection reads straight off the device record,
  /// so an unverified write simply leaves the control where it was.
  private func apply(_ mode: UInt8) {
    guard mode != deviceMode, !isApplying else { return }
    guard let settingsService = appState.services?.settingsService else { return }
    isApplying = true
    Task {
      defer { isApplying = false }
      _ = try? await settingsService.setPathHashModeVerified(mode)
    }
  }
}
