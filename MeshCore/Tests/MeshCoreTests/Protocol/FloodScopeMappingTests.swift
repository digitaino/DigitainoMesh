import Testing
import Foundation
@testable import MeshCore

@Suite("Region scope to FloodScope mapping")
struct FloodScopeMappingTests {

    @Test("nil regionScope maps to disabled")
    func nilScopeMapsToDisabled() {
        let regionScope: String? = nil
        let floodScope: FloodScope = regionScope.map { .region($0) } ?? .disabled

        #expect(floodScope.scopeKey() == FloodScope.disabled.scopeKey())
    }

    @Test("non-nil regionScope maps to region")
    func regionScopeMapsToRegion() {
        let regionScope: String? = "Europe"
        let floodScope: FloodScope = regionScope.map { .region($0) } ?? .disabled

        #expect(floodScope.scopeKey() == FloodScope.region("Europe").scopeKey())
    }

    @Test("disabled scope key differs from any region scope key")
    func disabledDiffersFromRegion() {
        let disabled = FloodScope.disabled.scopeKey()
        let region = FloodScope.region("Europe").scopeKey()

        #expect(disabled != region)
    }

    @Test("different region names produce different scope keys")
    func differentRegionsProduceDifferentKeys() {
        let europe = FloodScope.region("Europe").scopeKey()
        let uk = FloodScope.region("UK").scopeKey()

        #expect(europe != uk)
    }
}
