import Foundation
import Testing
@testable import MC1

@Suite("MapTimeFilter")
struct MapTimeFilterTests {

    @Test("allCases contains all 6 filters")
    func allCasesCount() {
        #expect(MapTimeFilter.allCases.count == 6)
    }

    @Test("allTime displayName")
    func allTimeDisplayName() {
        #expect(MapTimeFilter.allTime.displayName == "All Time")
    }

    @Test("days5 displayName")
    func days5DisplayName() {
        #expect(MapTimeFilter.days5.displayName == "5 Days")
    }

    @Test("days3 displayName")
    func days3DisplayName() {
        #expect(MapTimeFilter.days3.displayName == "3 Days")
    }

    @Test("day1 displayName")
    func day1DisplayName() {
        #expect(MapTimeFilter.day1.displayName == "1 Day")
    }

    @Test("hours12 displayName")
    func hours12DisplayName() {
        #expect(MapTimeFilter.hours12.displayName == "12 Hours")
    }

    @Test("hour1 displayName")
    func hour1DisplayName() {
        #expect(MapTimeFilter.hour1.displayName == "1 Hour")
    }

    @Test("allTime maxAge is nil")
    func allTimeMaxAgeNil() {
        #expect(MapTimeFilter.allTime.maxAge == nil)
    }

    @Test("days5 maxAge is 5 days in seconds")
    func days5MaxAge() {
        #expect(MapTimeFilter.days5.maxAge == 5 * 24 * 3600)
    }

    @Test("days3 maxAge is 3 days in seconds")
    func days3MaxAge() {
        #expect(MapTimeFilter.days3.maxAge == 3 * 24 * 3600)
    }

    @Test("day1 maxAge is 1 day in seconds")
    func day1MaxAge() {
        #expect(MapTimeFilter.day1.maxAge == 24 * 3600)
    }

    @Test("hours12 maxAge is 12 hours in seconds")
    func hours12MaxAge() {
        #expect(MapTimeFilter.hours12.maxAge == 12 * 3600)
    }

    @Test("hour1 maxAge is 1 hour in seconds")
    func hour1MaxAge() {
        #expect(MapTimeFilter.hour1.maxAge == 3600)
    }

    @Test("id matches rawValue")
    func idMatchesRawValue() {
        for filter in MapTimeFilter.allCases {
            #expect(filter.id == filter.rawValue)
        }
    }

    @Test("maxAge values are in decreasing order")
    func maxAgeDecreasingOrder() {
        let nonNilMaxAges = MapTimeFilter.allCases.compactMap(\.maxAge)
        for i in 0..<nonNilMaxAges.count - 1 {
            #expect(nonNilMaxAges[i] > nonNilMaxAges[i + 1])
        }
    }
}
