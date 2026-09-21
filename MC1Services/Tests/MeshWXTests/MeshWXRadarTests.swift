import Foundation
import Testing

@testable import MeshWX

/// Radar (type 11, spec revision 11, §7D): the lattice, the quadtree, and the two ways a tile
/// stops being the whole picture — coarse and partial.
///
/// The lattice cases are the reference's own (`meshwx/tests/test_radar.py`), coordinate for
/// coordinate, because the whole point of `floor(x / step + 0.5)` is that three clients written in
/// three languages pick the same tile: a case that passes here and fails in Python is two phones
/// paying for two tiles of the same storm.
@Suite("MeshWX radar")
struct MeshWXRadarTests {

  // MARK: - The lattice

  @Test(arguments: [
    // Austin: centre 30, −98.
    (30.27, -97.74, 0, 29, -99),
    // Dallas: centre 33, −97.
    (32.78, -96.80, 0, 32, -98),
    // A tie rounds up, in every language.
    (30.5, -97.5, 0, 30, -98),
    // Across the equator and Greenwich, where a truncating divide would round the wrong way.
    (-0.4, 0.4, 0, -1, -1),
    (30.27, -97.74, 1, 28, -100),
    // Step 4: centre 32, −96.
    (30.27, -97.74, 2, 28, -100),
    // Step 8: the same centre, twice the tile.
    (30.27, -97.74, 3, 24, -104),
    (18.22, -66.59, 0, 17, -68)
  ])
  func `the tile for a coordinate is the one whose centre is nearest`(
    _ latitude: Double, _ longitude: Double, _ zoom: Int, _ south: Int, _ west: Int
  ) {
    #expect(
      MeshWXRadarTile.containing(latitude: latitude, longitude: longitude, zoom: zoom)
        == MeshWXRadarTile(south: south, west: west, zoom: zoom))
  }

  /// Why the lattice centres on the place rather than snapping to a corner: the asked coordinate
  /// is never nearer than a quarter of the span to an edge, which at zoom 0 is 55 km. A picture
  /// whose subject sits on its border is a picture of the county next door.
  @Test(arguments: 0...3)
  func `a place is never near the edge of its tile`(_ zoom: Int) {
    let places = [(30.27, -97.74), (47.61, -122.33), (25.76, -80.19), (64.84, -147.72), (-33.9, 151.2)]
    for (latitude, longitude) in places {
      let tile = MeshWXRadarTile.containing(latitude: latitude, longitude: longitude, zoom: zoom)
      let span = Double(tile.spanDegrees)
      #expect(tile.contains(latitude: latitude, longitude: longitude))
      for (value, edge) in [(latitude, tile.south), (longitude, tile.west)] {
        let inset = value - Double(edge)
        #expect(inset >= span / 4 && inset <= 3 * span / 4)
      }
    }
  }

  /// The lattice is not a request, so a zoom off the end is clamped rather than refused: every
  /// caller here wants a tile back, and the encoder is where an out-of-range zoom is a failure.
  @Test func `a zoom past the ceiling clamps to the widest tile`() {
    #expect(MeshWXRadarTile.containing(latitude: 30.27, longitude: -97.74, zoom: 4)
      == MeshWXRadarTile.containing(latitude: 30.27, longitude: -97.74, zoom: 3))
    #expect(MeshWXRadarTile.containing(latitude: 30.27, longitude: -97.74, zoom: -1)
      == MeshWXRadarTile.containing(latitude: 30.27, longitude: -97.74, zoom: 0))
  }

  /// Row 0 is the **northern** row and column 0 the western one, which is the picture's order
  /// rather than the lattice's — the one place a client that assumed "south-west first" would
  /// draw every storm upside down.
  @Test func `cells are laid out north row first`() {
    let tile = MeshWXRadarTile(south: 32, west: -98, zoom: 0)
    let top = tile.cellBox(row: 0, col: 0, size: 32)
    #expect(top.north == 34)
    #expect(top.south == 34 - 1.0 / 16)
    #expect(top.west == -98)
    #expect(top.east == -98 + 1.0 / 16)

    let bottom = tile.cellBox(row: 31, col: 31, size: 32)
    #expect(bottom.south == 32)
    #expect(bottom.east == -96)

    // The round trip: the centre of a cell is in that cell.
    for (row, col) in [(0, 0), (5, 19), (31, 31)] {
      let box = tile.cellBox(row: row, col: col, size: 32)
      let found = tile.cell(
        latitude: (box.south + box.north) / 2, longitude: (box.west + box.east) / 2, size: 32)
      #expect(found?.row == row)
      #expect(found?.col == col)
    }
  }

  @Test func `a coordinate outside the tile has no cell`() {
    let tile = MeshWXRadarTile(south: 32, west: -98, zoom: 0)
    #expect(tile.cell(latitude: 35.0, longitude: -97.0, size: 32) == nil)
    #expect(tile.cell(latitude: 33.0, longitude: -99.0, size: 32) == nil)
    // Half-open north and east, so two neighbouring tiles never both claim a point.
    #expect(tile.contains(latitude: 32.0, longitude: -98.0))
    #expect(!tile.contains(latitude: 34.0, longitude: -97.0))
    #expect(!tile.contains(latitude: 33.0, longitude: -96.0))
  }

  // MARK: - The quadtree

  /// An all-dry tile is one bit of split and two of level: one byte, and a 13-byte packet for
  /// 1,024 cells.
  @Test func `a dry tile is one byte of cells`() throws {
    let data = try MeshWXEncoder.radar(
      seq: 7, bot: 0x4C7A, takenMinutes: 29_832_458, south: 29, west: -99, zoom: 0, product: 1,
      cells: Self.grid(32), source: .goesSatellite)
    #expect(data.count == 13)
    #expect(data[3] == (MeshWXMessageType.radar.rawValue << 4) | 0x4)
    #expect(data[12] == 0, "split bit 0, level 00, then padding")

    guard case let .radar(radar) = try MeshWXDecoder.decode(data).payload else {
      Issue.record("expected a radar tile")
      return
    }
    #expect(radar.size == 32)
    #expect(!radar.isCoarse)
    #expect(radar.bounds == nil)
    #expect(radar.tile == MeshWXRadarTile(south: 29, west: -99, zoom: 0))
    #expect(radar.product == 1)
    #expect(radar.takenMinutes == 29_832_458)
    #expect(radar.wetCellCount == 0)
    #expect(radar.cells.allSatisfy { $0 == 0 })
  }

  /// One heavy cell in the north-west corner of a 16 × 16 tile: split at 16, 8, 4 and 2,
  /// north-west first each time, then the four cells of the last square and the nine dry squares
  /// that follow. Written out bit by bit because the bit order is the whole contract — a client
  /// that packed least significant bit first would round-trip against itself perfectly.
  @Test func `the quadtree splits north-west first, most significant bit first`() throws {
    var cells = Self.grid(16)
    cells[0] = 3
    let data = try MeshWXEncoder.radar(
      seq: 1, bot: 0x4C7A, takenMinutes: 1, south: 0, west: 0, zoom: 0, product: 0, cells: cells)
    #expect(data[3] & MeshWXWire.radarCoarseBit != 0, "a 16 × 16 grid is the coarse form")

    let bits = data.dropFirst(12).map { byte in
      (0..<8).map { String((byte >> (7 - UInt8($0))) & 1) }.joined()
    }.joined()
    // 16: split. 8 NW: split. 4 NW: split. 2 NW: split, then its four cells 11 00 00 00.
    // Then the three dry 2-squares, 4-squares and 8-squares, each `0 00`.
    #expect(bits.hasPrefix("1111" + "11000000" + String(repeating: "000", count: 9)))
    #expect(bits.dropFirst(4 + 8 + 27).allSatisfy { $0 == "0" }, "the rest is zero padding")

    guard case let .radar(radar) = try MeshWXDecoder.decode(data).payload else {
      Issue.record("expected a radar tile")
      return
    }
    #expect(radar.level(row: 0, col: 0) == .heavy)
    #expect(radar.wetCellCount == 1)
  }

  /// Three hundred random grids through the encoder and back. A fine grid that does not fit is
  /// the expected failure and the reason `coarsened` exists; a coarse one always fits.
  @Test func `every grid round trips`() throws {
    var seed: UInt64 = 11
    func random(_ bound: Int) -> Int {
      // xorshift: a generator whose sequence is fixed, so a failure is reproducible.
      seed ^= seed << 13
      seed ^= seed >> 7
      seed ^= seed << 17
      return Int(seed % UInt64(bound))
    }

    var roundTripped = 0
    for _ in 0..<300 {
      let size = random(2) == 0 ? 16 : 32
      let cells = (0..<(size * size)).map { _ -> UInt8 in
        guard random(100) < 15 else { return 0 }
        return [1, 1, 2, 3][random(4)]
      }
      let data: Data
      do {
        data = try MeshWXEncoder.radar(
          seq: 1, bot: 0x4C7A, takenMinutes: 5, south: -10, west: 170, zoom: 3, product: 14,
          cells: cells)
      } catch {
        #expect(size == 32, "a coarse tile always fits")
        continue
      }
      guard case let .radar(radar) = try MeshWXDecoder.decode(data).payload else {
        Issue.record("expected a radar tile")
        return
      }
      #expect(radar.cells == cells)
      #expect(radar.size == size)
      #expect(radar.tile == MeshWXRadarTile(south: -10, west: 170, zoom: 3))
      #expect(radar.product == 14)
      roundTripped += 1
    }
    #expect(roundTripped > 100)
  }

  /// The worst coarse tile there is — every neighbour a different level, so the tree never
  /// collapses — still fits one packet, bounds and all. That is what lets the bot promise an
  /// answer in one packet and never split a radar tile.
  @Test func `the worst coarse tile still fits one packet`() throws {
    let cells = (0..<16).flatMap { row in (0..<16).map { col in UInt8((row * 7 + col * 3) % 4) } }
    let data = try MeshWXEncoder.radar(
      seq: 1, bot: 0x4C7A, takenMinutes: 5, south: 0, west: 0, zoom: 0, product: 0, cells: cells,
      bounds: MeshWXRadarBounds(row0: 0, row1: 15, col0: 0, col1: 15))
    #expect(data.count <= MeshWXWire.maxData)
  }

  /// A tree that runs out of bits is refused; bits left over after it are padding.
  ///
  /// The asymmetry is the point. Trailing zeroes are the writer filling out its last byte, and a
  /// future bot appending a field would leave more of them. A tree that ends early, on the other
  /// hand, decodes the rest of the grid as level 0 — which on a radar picture reads as "the rain
  /// stopped here", the one error worth failing the whole packet over.
  @Test func `a cut-off tree is refused and padding is not`() throws {
    var cells = Self.grid(32)
    cells[5 * 32 + 5] = 2
    cells[20 * 32 + 9] = 1
    let data = try MeshWXEncoder.radar(
      seq: 1, bot: 0x4C7A, takenMinutes: 5, south: 0, west: 0, zoom: 0, product: 0, cells: cells)

    #expect(throws: MeshWXDecodeError.self) {
      _ = try MeshWXDecoder.decode(data.dropLast(2))
    }
    guard case let .radar(padded) = try MeshWXDecoder.decode(data + Data([0])).payload,
          case let .radar(plain) = try MeshWXDecoder.decode(data).payload
    else {
      Issue.record("expected radar tiles")
      return
    }
    #expect(padded.cells == plain.cells)
    #expect(plain.cells == cells)
  }

  /// A Radar packet with the fixed fields and no cell bytes at all is a truncation, not an empty
  /// picture: the shortest tree there is still costs a byte.
  @Test func `a radar packet with no cells is truncated`() throws {
    let data = try MeshWXEncoder.radar(
      seq: 1, bot: 0x4C7A, takenMinutes: 5, south: 0, west: 0, zoom: 0, product: 0,
      cells: Self.grid(32))
    #expect(throws: MeshWXDecodeError.truncated(what: "radar", need: 13, have: 12)) {
      _ = try MeshWXDecoder.decode(data.prefix(12))
    }
    // A partial tile needs its four bounds bytes and a byte of tree on top of them.
    let partial = try MeshWXEncoder.radar(
      seq: 1, bot: 0x4C7A, takenMinutes: 5, south: 0, west: 0, zoom: 0, product: 0,
      cells: Self.grid(32), bounds: MeshWXRadarBounds(row0: 0, row1: 9, col0: 0, col1: 31))
    #expect(throws: MeshWXDecodeError.truncated(what: "radar bounds", need: 17, have: 16)) {
      _ = try MeshWXDecoder.decode(partial.prefix(16))
    }
  }

  // MARK: - Partial tiles

  @Test func `bounds outside the grid are refused on both sides of the wire`() throws {
    #expect(throws: MeshWXEncodeError.self) {
      _ = try MeshWXEncoder.radar(
        seq: 1, bot: 0x4C7A, takenMinutes: 5, south: 0, west: 0, zoom: 0, product: 0,
        cells: Self.grid(16), bounds: MeshWXRadarBounds(row0: 0, row1: 20, col0: 0, col1: 15))
    }
    // Written by hand, because the encoder will not produce it: a coarse tile whose `row1` is 20.
    var data = try MeshWXEncoder.radar(
      seq: 1, bot: 0x4C7A, takenMinutes: 5, south: 0, west: 0, zoom: 0, product: 0,
      cells: Self.grid(16), bounds: MeshWXRadarBounds(row0: 0, row1: 9, col0: 0, col1: 15))
    data[13] = 20
    #expect(throws: MeshWXDecodeError.self) {
      _ = try MeshWXDecoder.decode(data)
    }
  }

  /// A whole tile's cells are never unknown, and a partial one's outside its bounds always are.
  @Test func `unknown cells are the ones outside the bounds`() throws {
    var cells = Self.grid(16)
    cells[2 * 16 + 3] = 1
    let partial = MeshWXRadar(
      takenMinutes: 5, south: 24, west: -100, zoom: 1, product: 1, isCoarse: true,
      bounds: MeshWXRadarBounds(row0: 0, row1: 9, col0: 0, col1: 15), cells: cells)
    #expect(!partial.isUnknown(row: 9, col: 15))
    #expect(partial.isUnknown(row: 10, col: 0))
    #expect(partial.level(row: 2, col: 3) == .light)

    let whole = MeshWXRadar(
      takenMinutes: 5, south: 24, west: -100, zoom: 1, product: 1, isCoarse: true, cells: cells)
    #expect(!whole.isUnknown(row: 15, col: 15))
  }

  // MARK: - Coarsening

  /// Each coarse cell is the highest of the four it replaces, so a hail core two cells across
  /// survives the halving. Averaging would lose exactly the cell a person is looking for.
  @Test func `coarsening keeps the strongest cell`() {
    var cells = Self.grid(32)
    cells[0 * 32 + 1] = 1
    cells[1 * 32 + 0] = 3
    cells[31 * 32 + 31] = 2
    let coarse = MeshWXRadar.coarsened(cells: cells, size: 32)
    #expect(coarse.count == 16 * 16)
    #expect(coarse[0] == 3)
    #expect(coarse[15 * 16 + 15] == 2)
    #expect(coarse.reduce(0) { $0 + Int($1) } == 5)
    // Already coarse: nothing to do, and nothing lost.
    #expect(MeshWXRadar.coarsened(cells: coarse, size: 16).count == 8 * 8)
    #expect(MeshWXRadar.coarsened(cells: coarse, size: 32) == coarse, "a size that is not the grid")
  }

  // MARK: - Field ranges

  @Test func `the encoder refuses what the wire cannot carry`() {
    func encode(
      zoom: UInt8 = 0, product: UInt8 = 0, south: Int8 = 0, west: Int16 = 0,
      cells: [UInt8] = MeshWXRadarTests.grid(16)
    ) throws {
      _ = try MeshWXEncoder.radar(
        seq: 1, bot: 0x4C7A, takenMinutes: 5, south: south, west: west, zoom: zoom,
        product: product, cells: cells)
    }
    #expect(throws: MeshWXEncodeError.outOfRange(field: "radar zoom", value: 4)) { try encode(zoom: 4) }
    #expect(throws: MeshWXEncodeError.outOfRange(field: "radar product", value: 64)) { try encode(product: 64) }
    #expect(throws: MeshWXEncodeError.outOfRange(field: "radar west", value: 180)) { try encode(west: 180) }
    #expect(throws: MeshWXEncodeError.outOfRange(field: "radar level", value: 4)) {
      var cells = Self.grid(16)
      cells[0] = 4
      try encode(cells: cells)
    }
    #expect(throws: MeshWXEncodeError.self) { try encode(cells: Self.grid(8)) }
  }

  // MARK: - Helpers

  /// A dry grid of `size` × `size` cells.
  static func grid(_ size: Int) -> [UInt8] {
    [UInt8](repeating: 0, count: size * size)
  }
}
