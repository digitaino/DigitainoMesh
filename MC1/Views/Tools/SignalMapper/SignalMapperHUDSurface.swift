import SwiftUI

extension View {
  /// The one surface the Signal Mapper's HUD is made of.
  ///
  /// **Opaque, not glass.** Glass over a moving map failed the sunlight test in the field
  /// (UI review S2) — a rider at 25 km/h cannot pick a number out of a translucent panel
  /// with streets scrolling behind it.
  ///
  /// **One material, one radius.** The ride HUD had four surfaces in three materials at
  /// three margins with four corner radii, which is what "disjointed" meant (UI review
  /// P0-2). Everything that floats over this map goes through here.
  func mapperHUDSurface(in shape: some Shape = .rect(cornerRadius: 16)) -> some View {
    background(Color(.secondarySystemBackground).opacity(0.96), in: shape)
  }
}
