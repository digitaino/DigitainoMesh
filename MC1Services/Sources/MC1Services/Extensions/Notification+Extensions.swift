import Foundation

public extension Notification.Name {
    static let traceDataReceived = Notification.Name("traceDataReceived")
    static let rxLogTraceReceived = Notification.Name("rxLogTraceReceived")
    static let discoverResponseReceived = Notification.Name("discoverResponseReceived")
    /// Fired for every rxLogData packet that passed through at least one repeater.
    /// UserInfo: hexID (String), rxSnr (Double), rssi (Int?), deviceID (UUID)
    static let rxLogPacketReceived = Notification.Name("rxLogPacketReceived")
}
