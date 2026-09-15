import Foundation
@testable import MC1Services
import Testing

/// Channel datagrams (`GRP_DATA`) reach the app only from firmware v11 (MeshCore v1.15.0);
/// older radios drop them without an error, so the weather tool's whole "why is nothing
/// arriving" answer hangs on this one flag.
@Suite("Weather firmware capability")
struct WeatherCapabilityTests {
  @Test
  func `channel datagrams need firmware v11`() {
    #expect(!DeviceDTO.testDevice(firmwareVersion: 10, firmwareVersionString: "v1.14.0").supportsChannelDatagrams)
    #expect(DeviceDTO.testDevice(firmwareVersion: 11, firmwareVersionString: "v1.15.0").supportsChannelDatagrams)
    #expect(DeviceDTO.testDevice(firmwareVersion: 13, firmwareVersionString: "v1.16.0").supportsChannelDatagrams)
  }
}
