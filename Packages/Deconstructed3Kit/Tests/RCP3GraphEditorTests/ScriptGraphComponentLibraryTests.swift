import Testing
import TMFormat
@testable import RCP3GraphEditor

/// The component registry, populated from the per-category
/// `ScriptGraphComponentLibrary+*.swift` files, resolves component types (by name
/// hash) to their display name + property pins — what a Set/Get Component node
/// exposes once a Component Type is chosen.
@Suite struct ScriptGraphComponentLibraryTests {
    private func name(_ component: String) -> String? {
        ScriptGraphNodeLibrary.componentTypeName(forHash: TMHash.murmur64a(component))
    }

    private func propertyNames(_ component: String) -> [String] {
        (ScriptGraphNodeLibrary.componentProperties(
            forComponentTypeHash: TMHash.murmur64a(component)
        ) ?? []).map(\.connectorName)
    }

    @Test func resolvesComponentsAcrossEveryCategory() {
        // One representative per fanned-out category, by name hash.
        #expect(name("Transform") == "Transform")               // spatial
        #expect(name("ModelComponent") == "ModelComponent")     // rendering
        #expect(name("PhysicsBodyComponent") == "PhysicsBodyComponent") // physics
        #expect(name("PointLightComponent") == "PointLightComponent")   // lighting
        #expect(name("InputTargetComponent") == "InputTargetComponent") // anchoring
        #expect(name("SpatialAudioComponent") == "SpatialAudioComponent") // audio
        // Unknown component types stay unresolved (bridge falls back).
        #expect(name("NotARealComponent") == nil)
    }

    @Test func exposesExpectedPropertyPins() {
        #expect(propertyNames("Transform").contains("translation"))
        #expect(propertyNames("ModelComponent").contains("mesh"))
        #expect(propertyNames("ModelComponent").contains("materials"))
        #expect(propertyNames("PhysicsBodyComponent").contains("isAffectedByGravity"))
        #expect(propertyNames("PhysicsMotionComponent").contains("linearVelocity"))
        #expect(propertyNames("PointLightComponent").contains("intensity"))
        #expect(propertyNames("SpotLightComponent").contains("outerAngleInDegrees"))
        #expect(propertyNames("OpacityComponent").contains("opacity"))
        #expect(propertyNames("SpatialAudioComponent").contains("gain"))
    }

    @Test func completeRegistryHasStableUniqueComponentAndPropertyIdentity() {
        let components = ScriptGraphNodeLibrary.registeredComponents
        #expect(components.count == 46)
        #expect(Set(components.map(\.name)).count == components.count)
        #expect(Set(components.map(\.typeHash)).count == components.count)

        for component in components {
            let propertyNames = component.properties.map(\.connectorName)
            let propertyHashes = component.properties.map(\.connectorHash)
            #expect(Set(propertyNames).count == propertyNames.count, "duplicate property name in \(component.name)")
            #expect(Set(propertyHashes).count == propertyHashes.count, "duplicate property hash in \(component.name)")
            #expect(component.properties.allSatisfy { !$0.isExec })
        }
    }
}
