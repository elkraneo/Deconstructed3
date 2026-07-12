import Testing
@testable import RCP3GraphEditor

@Suite("Script Graph type registry")
struct ScriptGraphTypeRegistryTests {
    @Test func liveABIRecoveredCoreIsUniqueAndBidirectional() throws {
        let identities = ScriptGraphTypeRegistry.pickerCore
        #expect(Set(identities.map(\.id)).count == identities.count)
        #expect(Set(identities.map(\.typeHash)).count == identities.count)
        for identity in identities {
            #expect(ScriptGraphTypeRegistry.identity(named: identity.id) == identity)
            #expect(ScriptGraphTypeRegistry.identity(typeHash: identity.typeHash) == identity)
        }
    }

    @Test func numericSwiftTypesShareOneScriptGraphIdentity() {
        #expect(ScriptGraphTypeRegistry.number.typeHash == 0x3c2f3d0fe92dd9a0)
        #expect(ScriptGraphTypeRegistry.number.editHash == 0x0ef2dd9a55accbe4)
    }

    @Test func connectorFactoryPreservesSeparateRuntimeAndEditorHashes() {
        let connector = ScriptGraphTypeRegistry.vector3.connector(
            name: "position", displayName: "Position", order: 2
        )
        #expect(connector.typeHash == 0xacb19c32c360b8b0)
        #expect(connector.editHash == 0x8d1487af36b1e3e1)
        #expect(connector.order == 2)
        #expect(connector.optionality == 1)
    }
}
