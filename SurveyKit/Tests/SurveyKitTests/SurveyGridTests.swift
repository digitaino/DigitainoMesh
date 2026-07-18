import Foundation
import Testing
@testable import SurveyKit

@Suite("SurveyGrid")
struct SurveyGridTests {
    // Austin, TX — the survey system's home turf.
    let austin = GeoCoordinate(latitude: 30.2672, longitude: -97.7431)

    @Test func cellRoundTripsThroughString() throws {
        let cell = try #require(SurveyGrid.cell(containing: austin))
        #expect(cell.resolution == 10)
        let reparsed = try #require(H3Cell(string: cell.stringValue))
        #expect(reparsed == cell)
        // Canonical lowercase hex form, 15 chars at res 10.
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
        // All vertices within ~200 m of the center at res 10.
        let center = SurveyGrid.center(of: cell)
        for vertex in boundary {
            let dLat = abs(vertex.latitude - center.latitude)
            let dLon = abs(vertex.longitude - center.longitude)
            #expect(dLat < 0.002 && dLon < 0.002)
        }
    }

    @Test func parentContainsChild() throws {
        let cell = try #require(SurveyGrid.cell(containing: austin))
        let parent = try #require(SurveyGrid.parent(of: cell, resolution: 8))
        #expect(parent.resolution == 8)
        // The res-8 cell computed directly from the same coordinate matches.
        let direct = try #require(SurveyGrid.cell(containing: austin, resolution: 8))
        #expect(parent == direct)
        // Refining is refused.
        #expect(SurveyGrid.parent(of: parent, resolution: 10) == nil)
        // Same-res parent is identity.
        #expect(SurveyGrid.parent(of: cell, resolution: 10) == cell)
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

    @Test func tierResolutionsMatchDesign() {
        #expect(SamplingTier.fine.resolution == 10)
        #expect(SamplingTier.medium.resolution == 9)
        #expect(SamplingTier.coarse.resolution == 8)
        // Sanity-check the advertised cell scale (H3 4.4 average edge lengths).
        #expect(SurveyGrid.averageEdgeMeters(resolution: 10).rounded() == 76)
        #expect(SurveyGrid.averageEdgeMeters(resolution: 9).rounded() == 201)
        #expect(SurveyGrid.averageEdgeMeters(resolution: 8).rounded() == 531)
    }

    @Test func legacyAxialGridMatchesOriginalMath() {
        // Golden values captured from the original MC1/Utilities/HexGrid.swift.
        let coord = LegacyAxialGrid.axial(latitude: 30.2672, longitude: -97.7431, referenceLatitude: 30)
        let center = LegacyAxialGrid.center(of: coord, referenceLatitude: 30)
        #expect(abs(center.latitude - 30.2672) < LegacyAxialGrid.size * 2)
        #expect(abs(center.longitude - (-97.7431)) < LegacyAxialGrid.size * 2)
        #expect(LegacyAxialGrid.fixedReferenceLatitude(for: 32.7) == 30)
        #expect(LegacyAxialGrid.fixedReferenceLatitude(for: -7.3) == -10)
    }
}
