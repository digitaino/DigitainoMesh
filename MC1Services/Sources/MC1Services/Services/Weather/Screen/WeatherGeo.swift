import Foundation
import MeshWX

/// Small geometry helpers the screen types share.
enum WeatherGeo {
  static func kilometres(_ from: MeshWXCoordinate, _ to: MeshWXCoordinate) -> Double {
    MeshWXGeo.distanceKilometres(fromLat: from.latitude, lon: from.longitude, toLat: to.latitude, lon: to.longitude)
  }

  /// The vertex average: a label anchor, not a true centroid, which is all a direction needs.
  static func centre(of coordinates: [MeshWXCoordinate]) -> MeshWXCoordinate? {
    guard !coordinates.isEmpty else { return nil }
    let latitude = coordinates.reduce(0) { $0 + $1.latitude } / Double(coordinates.count)
    let longitude = coordinates.reduce(0) { $0 + $1.longitude } / Double(coordinates.count)
    return MeshWXCoordinate(latitude: latitude, longitude: longitude)
  }

  /// The 16-point compass direction from one coordinate towards another.
  static func direction(from: MeshWXCoordinate, to: MeshWXCoordinate) -> MeshWXCompass {
    let lat1 = from.latitude * .pi / 180
    let lat2 = to.latitude * .pi / 180
    let dLon = (to.longitude - from.longitude) * .pi / 180
    let y = sin(dLon) * cos(lat2)
    let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
    let degrees = (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    return MeshWXCompass(degrees: degrees)
  }
}

/// What alert placement needs from the zone and county outlines. A protocol so tests can say
/// "still loading" without waiting on a 10 MB parse.
public protocol WeatherAreaGeometry: Sendable {
  var isLoaded: Bool { get }
  func distanceKilometres(from point: MeshWXCoordinate, toArea ugc: String) -> Double?
  func centre(ofArea ugc: String) -> MeshWXCoordinate?
}

extension MeshWXGeometry: WeatherAreaGeometry {
  public var isLoaded: Bool { isZoneFileLoaded && isCountyFileLoaded }

  public func centre(ofArea ugc: String) -> MeshWXCoordinate? {
    rings(for: ugc).flatMap { WeatherGeo.centre(of: $0.flatMap { $0 }) }
  }
}
