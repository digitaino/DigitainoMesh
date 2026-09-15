import Foundation
@testable import MC1Services
import MeshWX
import Testing

/// Developer tooling, not a test of anything: writes a `WeatherService` state file built from
/// the kit's nine wire vectors (the Austin bot: a severe thunderstorm warning over Travis and
/// Hays, a winter storm warning by zones, three stations, a seven-period forecast and a
/// two-chunk narrative) to the path in `WEATHER_SEED_URL`, so a simulator or a device can be
/// shown the tool with real-shaped data and no radio.
///
/// Skipped unless the variable is set, so the suite never touches a real container by accident:
///
///     WEATHER_SEED_URL="$(xcrun simctl get_app_container booted com.digitaino.PocketMesh data)/Library/Application Support/MeshWX/state.json" \
///       swift test --filter WeatherSeedTrialTests
@Suite("Weather seed trial", .enabled(if: ProcessInfo.processInfo.environment["WEATHER_SEED_URL"] != nil))
struct WeatherSeedTrialTests {
  @Test
  func `write the kit vectors as a state file`() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["WEATHER_SEED_URL"])
    let url = URL(fileURLWithPath: path)

    // The kit vectors, verbatim (MeshWXTests/Fixtures/meshwx_v5_vectors.json), in wire order.
    let hexes = [
      "117a4c1003232a00c913c70183043c0630a804a80cf15a0068011affd2001affa6ffc4ffa2febe0042ff02aad10001aac50101",
      "127a4c1018230700d417c701010000022abf00042ac80001",
      "147a4c309c13c701070303232a002d0018230700380403232b001400",
      "157a4c409513c70103ca005848730c150a5c3b075c0354460100000a5fff00d0038080daff00ffffff00",
      "167a4c5066002413c70101077f491482715d7f2813827f481e13815a7f3c58947f451402e2567f0a01027f41ff0000",
      "177a4c6000170002534556455245205448554e44455253544f524d205741524e494e4720464f52204e4f5254484541535445524e204841595320414e4420534f5554485745535445524e2054524156495320434f554e5449455320554e54494c2031343520414d204344542e204174203132353720414d206120736576657265207468756e64657273746f726d20776173206e656172204472697070696e6720537072696e",
      "187a4c600017010267732c206d6f76696e672065617374206174203430206d70682e2048415a4152443a203630206d706820677573747320616e6420717561727465722073697a65206861696c2e20534f555243453a20526164617220696e646963617465642e"
    ]

    // The vectors' clocks are fixed at 2026-09-15 ~00:45 UTC; shift every time field to "now"
    // so the countdowns and stale badges read as live rather than long expired.
    let vectorNowMinutes: UInt32 = 29_823_900
    let nowMinutes = MeshWXPresentation.unixMinutes(for: Date())
    let shift = Int64(nowMinutes) - Int64(vectorNowMinutes)
    func shifted(_ minutes: UInt32) -> UInt32 { UInt32(clamping: Int64(minutes) + shift) }

    var state = WeatherBotState(botID: 19578)
    for hex in hexes {
      var message = try MeshWXDecoder.decode(Data(hex: hex))
      switch message.payload {
      case var .warning(warning):
        warning.expiresMinutes = shifted(warning.expiresMinutes)
        message.payload = .warning(warning)
      case var .digest(digest):
        digest.nowMinutes = shifted(digest.nowMinutes)
        digest.entries = digest.entries.map {
          MeshWXDigest.Entry(identity: $0.identity, expiresRelativeMinutes: $0.expiresRelativeMinutes, expiresMinutes: shifted($0.expiresMinutes))
        }
        message.payload = .digest(digest)
      case var .observations(batch):
        batch.timestampMinutes = shifted(batch.timestampMinutes)
        message.payload = .observations(batch)
      case var .forecast(forecast):
        forecast.issuedMinutes = shifted(forecast.issuedMinutes)
        message.payload = .forecast(forecast)
      default:
        break
      }
      _ = WeatherStateReducer.apply(message, to: &state, receivedAt: Date())
    }

    try await FileWeatherStateStore(url: url).save([state.botID: state])
    let reloaded = try await FileWeatherStateStore(url: url).load()
    #expect(reloaded[19578]?.warnings.count == 2)
    #expect(reloaded[19578]?.observations.count == 3)
    #expect(reloaded[19578]?.texts[23]?.isComplete == true)
    print("wrote weather seed to \(url.path)")
  }
}

private extension Data {
  init(hex: String) {
    var bytes: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
      index = next
    }
    self.init(bytes)
  }
}
