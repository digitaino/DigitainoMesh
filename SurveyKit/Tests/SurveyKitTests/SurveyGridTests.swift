import Foundation
import Testing
@testable import SurveyKit

@Suite("SurveyGrid")
struct SurveyGridTests {
    // Austin, TX — the survey system's home turf.
    let austin = GeoCoordinate(latitude: 30.2672, longitude: -97.7431)

    @Test func cellRoundTripsThroughString() throws {
        let cell = try #require(SurveyGrid.cell(containing: austin))
        #expect(cell.resolution == 9)
        let reparsed = try #require(H3Cell(string: cell.stringValue))
        #expect(reparsed == cell)
        // Canonical lowercase hex form, 15 chars at res 9.
        #expect(cell.stringValue == cell.stringValue.lowercased())
        #expect(cell.stringValue.count == 15)
    }

    @Test func centerFallsInsideOwnCell() throws {
        let cell = try #require(SurveyGrid.cell(containing: austin))
        let center = SurveyGrid.center(of: cell)
        let recovered = try #require(SurveyGrid.cell(containing: center))
        #expect(recovered == cell)
    }

    @Test func boundaryIsAHexagon() throws {
        let cell = try #require(SurveyGrid.cell(containing: austin))
        let boundary = SurveyGrid.boundary(of: cell)
        #expect(boundary.count == 6)
        // All vertices within ~500 m of the center at res 9.
        let center = SurveyGrid.center(of: cell)
        for vertex in boundary {
            let dLat = abs(vertex.latitude - center.latitude)
            let dLon = abs(vertex.longitude - center.longitude)
            #expect(dLat < 0.005 && dLon < 0.005)
        }
    }

    @Test func parentContainsChild() throws {
        let cell = try #require(SurveyGrid.cell(containing: austin))
        let parent = try #require(SurveyGrid.parent(of: cell, resolution: 7))
        #expect(parent.resolution == 7)
        // The res-7 cell computed directly from the same coordinate matches.
        let direct = try #require(SurveyGrid.cell(containing: austin, resolution: 7))
        #expect(parent == direct)
        // Refining is refused.
        #expect(SurveyGrid.parent(of: parent, resolution: 9) == nil)
        // Same-res parent is identity.
        #expect(SurveyGrid.parent(of: cell, resolution: 9) == cell)
    }

    @Test func invalidInputsReturnNil() {
        #expect(SurveyGrid.cell(containing: GeoCoordinate(latitude: 91, longitude: 0)) == nil)
        #expect(SurveyGrid.cell(containing: GeoCoordinate(latitude: .nan, longitude: 0)) == nil)
        #expect(SurveyGrid.cell(containing: austin, resolution: 16) == nil)
        #expect(H3Cell(string: "not-a-cell") == nil)
        #expect(H3Cell(string: "") == nil)
        #expect(H3Cell(rawValue: 0) == nil)
    }

    @Test func codableUsesHexStringForm() throws {
        let cell = try #require(SurveyGrid.cell(containing: austin))
        let data = try JSONEncoder().encode([cell])
        let json = String(decoding: data, as: UTF8.self)
        #expect(json == "[\"\(cell.stringValue)\"]")
        let decoded = try JSONDecoder().decode([H3Cell].self, from: data)
        #expect(decoded == [cell])
    }

    // MARK: - Spherical geometry

    @Test func distanceIsZeroToItselfAndSymmetric() {
        let elsewhere = GeoCoordinate(latitude: 30.3672, longitude: -97.6431)
        #expect(SurveyGrid.distanceMeters(from: austin, to: austin) == 0)
        #expect(
            abs(SurveyGrid.distanceMeters(from: austin, to: elsewhere)
                - SurveyGrid.distanceMeters(from: elsewhere, to: austin)) < 0.001
        )
    }

    @Test func distanceMatchesAKnownSeparation() {
        // One degree of latitude is very close to 111.2 km on this sphere.
        let north = GeoCoordinate(latitude: austin.latitude + 1, longitude: austin.longitude)
        let measured = SurveyGrid.distanceMeters(from: austin, to: north)
        #expect(abs(measured - 111_195) < 200)
    }

    @Test func offsettingByADistanceThenMeasuringItRoundTrips() {
        // The two helpers are inverses, which is what the anchor discs rely on: a centre
        // displaced by 450 m must measure 450 m away.
        for bearing in stride(from: 0.0, to: 2 * .pi, by: .pi / 5) {
            let moved = SurveyGrid.coordinate(from: austin, bearingRadians: bearing, distanceMeters: 450)
            #expect(abs(SurveyGrid.distanceMeters(from: austin, to: moved) - 450) < 0.5)
        }
    }

    @Test func offsettingDueNorthIncreasesLatitudeOnly() {
        let north = SurveyGrid.coordinate(from: austin, bearingRadians: 0, distanceMeters: 1000)
        #expect(north.latitude > austin.latitude)
        #expect(abs(north.longitude - austin.longitude) < 0.0001)
    }

    @Test func offsettingAcrossTheAntimeridianStaysInRange() {
        let edge = GeoCoordinate(latitude: 0, longitude: 179.99)
        let across = SurveyGrid.coordinate(from: edge, bearingRadians: .pi / 2, distanceMeters: 50_000)
        #expect(across.longitude > -180)
        #expect(across.longitude <= 180)
        #expect(SurveyGrid.cell(containing: across) != nil)
    }

    @Test func cellsWithinARadiusAreExactlyThoseWhoseCentresAreInside() throws {
        let radius = 900.0
        let cells = SurveyGrid.cells(within: radius, of: austin)

        #expect(!cells.isEmpty)
        #expect(Set(cells).count == cells.count)
        // The definition is centre-membership, so enumeration and the one-cell test agree.
        #expect(cells.allSatisfy {
            SurveyGrid.distanceMeters(from: austin, to: SurveyGrid.center(of: $0)) <= radius
        })
        #expect(cells.allSatisfy { $0.resolution == SurveyGrid.baseResolution })
        // The cell the centre falls in is always covered.
        #expect(cells.contains(try #require(SurveyGrid.cell(containing: austin))))
    }

    @Test func aBiggerRadiusCoversAtLeastAsMuch() {
        let small = Set(SurveyGrid.cells(within: 500, of: austin))
        let large = Set(SurveyGrid.cells(within: 1500, of: austin))
        #expect(small.isSubset(of: large))
        #expect(large.count > small.count)
    }

    @Test func aNonPositiveRadiusCoversNothing() {
        #expect(SurveyGrid.cells(within: 0, of: austin).isEmpty)
        #expect(SurveyGrid.cells(within: -100, of: austin).isEmpty)
    }

    @Test func tierResolutionsMatchDesign() {
        #expect(SamplingTier.fine.resolution == 9)
        #expect(SamplingTier.medium.resolution == 8)
        #expect(SamplingTier.coarse.resolution == 7)
        // Sanity-check the advertised cell scale (H3 4.4 average edge lengths).
        #expect(SurveyGrid.averageEdgeMeters(resolution: 9).rounded() == 201)
        #expect(SurveyGrid.averageEdgeMeters(resolution: 8).rounded() == 531)
        #expect(SurveyGrid.averageEdgeMeters(resolution: 7).rounded() == 1406)
    }
}
