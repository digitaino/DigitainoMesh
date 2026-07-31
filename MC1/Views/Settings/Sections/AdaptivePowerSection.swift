import MC1Services
import SwiftUI

/// Adaptive TX power control: base output level, external amplifier profile, and the
/// live state of the escalation the service is running.
///
/// Preferences are per-device (`DevicePreferenceStore`); the live state lives on the
/// per-connection `AdaptivePowerService`, so this section is only meaningful while a
/// radio is connected.
struct AdaptivePowerSection: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme

  @State private var isEnabled = false
  @State private var paGainDb: Double = 0
  @State private var baseStepIndex = AdaptivePowerPolicy.defaultBaseStepIndex

  /// Amplifier profiles offered in the picker, keyed by the gain the service stores.
  /// The two measured entries resolve to real PA curves; the rest fall back to flat gain.
  private static let amplifierGains: [Double] = [0, 8, 11, 6, 10, 12]

  private var service: AdaptivePowerService? {
    appState.services?.adaptivePowerService
  }

  private var deviceID: UUID? {
    appState.connectedDevice?.id
  }

  var body: some View {
    Section {
      Toggle(isOn: $isEnabled) {
        TintedLabel(L10n.Settings.AdaptivePower.enable, systemImage: "bolt.badge.automatic")
      }
      .onChange(of: isEnabled) { _, newValue in
        save()
        Task { await service?.setEnabled(newValue) }
      }

      if isEnabled {
        Picker(L10n.Settings.AdaptivePower.amplifier, selection: $paGainDb) {
          ForEach(Self.amplifierGains, id: \.self) { gain in
            Text(amplifierLabel(forGain: gain)).tag(gain)
          }
        }
        .pickerStyle(.menu)
        .tint(.primary)
        .onChange(of: paGainDb) { _, newValue in
          save()
          Task { await service?.setPAGain(newValue) }
          clampBaseStepToReachable(forGain: newValue)
        }

        Picker(L10n.Settings.AdaptivePower.baseOutput, selection: $baseStepIndex) {
          ForEach(availableSteps) { step in
            Text(stepLabel(step)).tag(step.id)
          }
        }
        .pickerStyle(.menu)
        .tint(.primary)
        .onChange(of: baseStepIndex) { _, newValue in
          save()
          Task { await service?.setBaseStep(newValue) }
        }

        if let service {
          statusPanel(service)
        }
      }
    } header: {
      Text(L10n.Settings.AdaptivePower.header)
    } footer: {
      Text(isEnabled ? L10n.Settings.AdaptivePower.footerEnabled : L10n.Settings.AdaptivePower.footer)
    }
    .themedRowBackground(theme)
    .disabled(deviceID == nil)
    .onAppear { load() }
    .onChange(of: deviceID) { _, _ in load() }
  }

  // MARK: - Status Panel

  private func statusPanel(_ service: AdaptivePowerService) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Circle()
          .fill(statusColor(service))
          .frame(width: 8, height: 8)
        Text(stepLabel(service.currentStep))
          .font(.system(.subheadline, design: .monospaced).weight(.medium))
      }

      if paGainDb > 0 {
        Text(L10n.Settings.AdaptivePower.chain(
          Int(service.currentRadioDbm),
          formatDbm(policy.actualEirpDbm(for: service.currentStep))
        ))
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
      }

      confirmationRow(service)
      escalationRow(service)
    }
    .accessibilityElement(children: .combine)
  }

  private func confirmationRow(_ service: AdaptivePowerService) -> some View {
    HStack(spacing: 4) {
      if service.lastApplyFailed {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
        Text(L10n.Settings.AdaptivePower.notConfirmed)
          .foregroundStyle(.red)
      } else if let confirmed = service.confirmedRadioDbm {
        let matches = confirmed == service.currentRadioDbm
        Image(systemName: matches ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
          .foregroundStyle(matches ? .green : .orange)
        Text(matches ? L10n.Settings.AdaptivePower.confirmed : L10n.Settings.AdaptivePower.mismatch(Int(confirmed)))
          .foregroundStyle(matches ? Color.secondary : Color.orange)
      } else {
        Image(systemName: "checkmark.circle")
          .foregroundStyle(.secondary)
        Text(L10n.Settings.AdaptivePower.notVerified)
          .foregroundStyle(.secondary)
      }
    }
    .font(.caption)
  }

  private func escalationRow(_ service: AdaptivePowerService) -> some View {
    HStack(spacing: 6) {
      if service.isElevated {
        Text(L10n.Settings.AdaptivePower.escalatedFrom(service.baseStep.label))
          .font(.caption)
          .foregroundStyle(.orange)
      } else {
        Text(L10n.Settings.AdaptivePower.atBase)
          .font(.caption)
          .foregroundStyle(.green)
      }

      if service.isUserOverride {
        Text(L10n.Settings.AdaptivePower.manual)
          .font(.caption2)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(.orange.opacity(0.2))
          .clipShape(.capsule)
      }

      Spacer()

      if service.isElevated || service.isUserOverride {
        Button(L10n.Settings.AdaptivePower.reset) {
          Task { await service.resetToBase() }
        }
        .font(.caption)
      }
    }
  }

  // MARK: - Formatting

  /// The connected radio's policy, or one derived from the picked gain alone while
  /// disconnected so the pickers still render sensible choices.
  private var policy: AdaptivePowerPolicy {
    service?.policy ?? AdaptivePowerPolicy(paGainDb: paGainDb)
  }

  private var availableSteps: [AdaptivePowerPolicy.PowerStep] {
    policy.availableSteps
  }

  private func statusColor(_ service: AdaptivePowerService) -> Color {
    if service.isAtMax { return .red }
    return service.isElevated ? .orange : .green
  }

  private func amplifierLabel(forGain gain: Double) -> String {
    switch gain {
    case 0: L10n.Settings.AdaptivePower.Amplifier.builtIn
    case 8: L10n.Settings.AdaptivePower.Amplifier.pocket1W
    case 11: L10n.Settings.AdaptivePower.Amplifier.heltecV4
    default: L10n.Settings.AdaptivePower.Amplifier.custom(Int(gain))
    }
  }

  /// Labels a step with what the radio will actually emit. With a measured amplifier
  /// curve the achieved output is capped at the step's nominal target, so a compressing
  /// PA never advertises more power than the step promises.
  private func stepLabel(_ step: AdaptivePowerPolicy.PowerStep) -> String {
    guard paGainDb > 0 else {
      return L10n.Settings.AdaptivePower.stepLabel(step.label, formatDbm(step.eirpDbm))
    }
    let cappedMilliwatts = min(policy.actualMilliwatts(for: step), step.targetMilliwatts)
    return L10n.Settings.AdaptivePower.stepLabel(
      formatPower(cappedMilliwatts),
      formatDbm(policy.actualEirpDbm(for: step))
    )
  }

  private func formatPower(_ milliwatts: Int) -> String {
    guard milliwatts >= 1000 else { return "\(milliwatts)mW" }
    let watts = Double(milliwatts) / 1000
    return watts == watts.rounded(.down)
      ? "\(Int(watts))W"
      : watts.formatted(.number.precision(.fractionLength(1))) + "W"
  }

  private func formatDbm(_ dbm: Double) -> String {
    dbm.formatted(.number.precision(.fractionLength(dbm == dbm.rounded() ? 0 : 1)))
  }

  // MARK: - Persistence

  /// A gain change can strand the stored base step above what the radio now reaches
  /// (the step table is filtered per amplifier), which would leave the picker with no
  /// matching tag. Snap down to the highest reachable step in that case.
  ///
  /// Derives the new step table from `gain` directly rather than from the service, whose
  /// policy is only re-derived once its write completes.
  private func clampBaseStepToReachable(forGain gain: Double) {
    let reachable = AdaptivePowerPolicy(paGainDb: gain, radioMaxDbm: policy.radioMaxDbm).availableSteps
    guard let highest = reachable.last, baseStepIndex > highest.id else { return }
    baseStepIndex = highest.id
  }

  private func load() {
    guard let deviceID else { return }
    let preferences = DevicePreferenceStore()
    isEnabled = preferences.isAdaptivePowerEnabled(deviceID: deviceID)
    paGainDb = preferences.paGainDb(deviceID: deviceID)
    baseStepIndex = preferences.adaptivePowerBaseStep(deviceID: deviceID)
  }

  private func save() {
    guard let deviceID else { return }
    let preferences = DevicePreferenceStore()
    preferences.setAdaptivePowerEnabled(isEnabled, deviceID: deviceID)
    preferences.setPAGainDb(paGainDb, deviceID: deviceID)
    preferences.setAdaptivePowerBaseStep(baseStepIndex, deviceID: deviceID)
  }
}
