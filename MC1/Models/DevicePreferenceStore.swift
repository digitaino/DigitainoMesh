import Foundation
import MC1Services

enum GPSSource: String, CaseIterable {
  case phone
  case device
}

struct DevicePreferenceStore {
  private let userDefaults: UserDefaults

  init(userDefaults: UserDefaults = .standard) {
    self.userDefaults = userDefaults
  }

  // MARK: - Auto-Update Location

  func isAutoUpdateLocationEnabled(deviceID: UUID) -> Bool {
    userDefaults.bool(forKey: Self.autoUpdateLocationKey(deviceID: deviceID))
  }

  func setAutoUpdateLocationEnabled(_ enabled: Bool, deviceID: UUID) {
    userDefaults.set(enabled, forKey: Self.autoUpdateLocationKey(deviceID: deviceID))
  }

  // MARK: - GPS Source

  func gpsSource(deviceID: UUID) -> GPSSource {
    guard let raw = userDefaults.string(forKey: Self.gpsSourceKey(deviceID: deviceID)),
          let source = GPSSource(rawValue: raw) else {
      return .phone
    }
    return source
  }

  func hasSetGPSSource(deviceID: UUID) -> Bool {
    userDefaults.string(forKey: Self.gpsSourceKey(deviceID: deviceID)) != nil
  }

  func setGPSSource(_ source: GPSSource, deviceID: UUID) {
    userDefaults.set(source.rawValue, forKey: Self.gpsSourceKey(deviceID: deviceID))
  }

  // MARK: - Adaptive Power

  func isAdaptivePowerEnabled(deviceID: UUID) -> Bool {
    userDefaults.bool(forKey: Self.adaptivePowerEnabledKey(deviceID: deviceID))
  }

  func setAdaptivePowerEnabled(_ enabled: Bool, deviceID: UUID) {
    userDefaults.set(enabled, forKey: Self.adaptivePowerEnabledKey(deviceID: deviceID))
  }

  /// External PA gain in dB (0 = no amplifier, 8 = WisMesh Pocket 1W, 11 = Heltec V4).
  func paGainDb(deviceID: UUID) -> Double {
    userDefaults.object(forKey: Self.paGainDbKey(deviceID: deviceID)) as? Double ?? 0
  }

  func setPAGainDb(_ gain: Double, deviceID: UUID) {
    userDefaults.set(gain, forKey: Self.paGainDbKey(deviceID: deviceID))
  }

  /// Base power step index into `AdaptivePowerPolicy.allSteps`.
  func adaptivePowerBaseStep(deviceID: UUID) -> Int {
    userDefaults.object(forKey: Self.adaptivePowerBaseStepKey(deviceID: deviceID)) as? Int
      ?? AdaptivePowerPolicy.defaultBaseStepIndex
  }

  func setAdaptivePowerBaseStep(_ step: Int, deviceID: UUID) {
    userDefaults.set(step, forKey: Self.adaptivePowerBaseStepKey(deviceID: deviceID))
  }

  // MARK: - Keys

  private static func autoUpdateLocationKey(deviceID: UUID) -> String {
    "device.\(deviceID.uuidString).autoUpdateLocation"
  }

  private static func gpsSourceKey(deviceID: UUID) -> String {
    "device.\(deviceID.uuidString).gpsSource"
  }

  private static func adaptivePowerEnabledKey(deviceID: UUID) -> String {
    "device.\(deviceID.uuidString).adaptivePower.enabled"
  }

  private static func paGainDbKey(deviceID: UUID) -> String {
    "device.\(deviceID.uuidString).adaptivePower.paGainDb"
  }

  private static func adaptivePowerBaseStepKey(deviceID: UUID) -> String {
    "device.\(deviceID.uuidString).adaptivePower.baseStep"
  }
}
