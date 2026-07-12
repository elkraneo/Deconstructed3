import Testing
import TMFormat
@testable import RCP3Document

@Suite struct ScriptGraphComponentRuntimeCapabilityTests {
    @Test func catalogContainsOnlyIndependentlyEvidencedContracts() throws {
        #expect(ScriptGraphComponentRuntimeCapabilities.all.count == 4)
        #expect(Set(ScriptGraphComponentRuntimeCapabilities.all.map(\.typeHash)).count == 4)

        let transform = try #require(ScriptGraphComponentRuntimeCapabilities.capability(
            forTypeHash: TMHash.murmur64a("Transform")
        ))
        guard case let .entityProperties(properties) = transform.strategy else {
            Issue.record("Transform must use Entity property mutation")
            return
        }
        #expect(properties.map(\.connectorName) == ["translation", "rotation", "scale"])
        #expect(properties.map(\.entityPropertyName) == ["position", "orientation", "scale"])

        #expect(ScriptGraphComponentRuntimeCapabilities.capability(
            forTypeHash: TMHash.murmur64a("PhysicsBodyComponent")
        ) == nil)
    }
}
