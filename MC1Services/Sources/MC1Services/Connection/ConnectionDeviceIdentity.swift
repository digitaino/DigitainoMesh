import Foundation

/// Facts acquired about a radio independently of the address used to reach it.
struct ConnectionDeviceIdentity: Sendable, Equatable {
  var deviceID: UUID?
  var publicKey: Data?
  var radioID: UUID?
  /// Set when another radio carries the same identity (docs/RADIO_SWAP.md, R1): the radio ID
  /// and key then name every sibling, so only the device ID identifies this radio.
  var scopedToDevice = false

  init(deviceID: UUID? = nil, publicKey: Data? = nil, radioID: UUID? = nil, scopedToDevice: Bool = false) {
    self.deviceID = deviceID
    self.publicKey = publicKey
    self.radioID = radioID
    self.scopedToDevice = scopedToDevice
  }

  init(_ device: DeviceDTO) {
    deviceID = device.id
    publicKey = device.publicKey
    radioID = device.radioID
  }

  func matches(_ other: Self) -> Bool {
    if scopedToDevice || other.scopedToDevice {
      guard let deviceID, let otherID = other.deviceID else { return false }
      return deviceID == otherID
    }
    if let radioID, radioID == other.radioID { return true }
    if let publicKey, !publicKey.isEmpty, publicKey == other.publicKey { return true }
    if let deviceID, deviceID == other.deviceID { return true }
    return false
  }
}
