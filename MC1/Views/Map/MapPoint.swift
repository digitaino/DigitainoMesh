import CoreLocation

struct MapPoint: Identifiable, Equatable {
  let id: UUID
  let coordinate: CLLocationCoordinate2D
  let pinStyle: PinStyle
  let label: String?
  let isClusterable: Bool

  enum PinStyle: String, Hashable {
    case contactChat
    case contactRepeater
    case contactRoom
    case repeater
    case repeaterRingBlue
    case repeaterRingGreen
    case repeaterRingWhite
    case repeaterHop
    case pointA
    case pointB
    case crosshair
    case obstruction
    case badge
    case droppedPin
    /// A sampled node location report: a small neutral dot threaded onto the
    /// history trail. Center-anchored, unlike the bottom-anchored teardrops.
    case locationFix
    /// The node's most recent location report: the emphasized hero teardrop that
    /// caps the trail.
    case locationFixLatest
  }

  let hopIndex: Int?
  let badgeText: String?
  /// How strongly this pin reads: `1` in focus, ``recessedEmphasis`` when it is
  /// not part of what the screen is showing. Discrete and never animated — it
  /// is part of `==`, the diff key for both point sources, so a continuous
  /// value would re-upload every feature per frame. Emitted as the
  /// `pinOpacity` feature attribute on the icon, name-pill and badge layers.
  var emphasis: Double = 1
  /// Placement priority for the name pill; **lower wins a collision**. Consulted
  /// only when the host map sets `labelPlacement: .collide`; `0` is never
  /// dropped. The default sits below every deliberate priority.
  var labelPriority: Int = 1000

  /// The one recessed value. Two values, not a scale: a pin is either part of
  /// the focus or it is not.
  static let recessedEmphasis = 0.25

  static func == (lhs: MapPoint, rhs: MapPoint) -> Bool {
    lhs.id == rhs.id
      && lhs.coordinate.latitude == rhs.coordinate.latitude
      && lhs.coordinate.longitude == rhs.coordinate.longitude
      && lhs.pinStyle == rhs.pinStyle
      && lhs.label == rhs.label
      && lhs.isClusterable == rhs.isClusterable
      && lhs.hopIndex == rhs.hopIndex
      && lhs.badgeText == rhs.badgeText
      && lhs.emphasis == rhs.emphasis
      && lhs.labelPriority == rhs.labelPriority
  }
}
