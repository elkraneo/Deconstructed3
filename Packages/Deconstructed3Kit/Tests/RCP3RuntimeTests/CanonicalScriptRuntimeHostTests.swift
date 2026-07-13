import Testing
import TMFormat
import RCP3Document
@testable import RCP3Runtime

@MainActor
@Suite struct CanonicalScriptRuntimeHostTests {
    private func variable(_ name: String, host: CanonicalScriptRuntimeHost) -> Any? {
        host.context
            .objectForKeyedSubscript(CanonicalScriptGraphCompiler.variableSlot(for: name))?
            .toObject()
    }

    @Test func case1ComponentAccessExecutesAgainstEntityState() throws {
        let update = RCP3ScriptGraph.Node(id: "update", type: "tm_update")
        let get = RCP3ScriptGraph.Node(id: "get", type: "tm_get_component")
        let capture = RCP3ScriptGraph.Node(id: "capture", type: "tm_set_variable_node", variableName: "translation")
        let graph = RCP3ScriptGraph(nodes: [update, get, capture], wires: [
            .init(id: "exec", from: "update", to: "capture"),
            .init(id: "value", from: "get", to: "capture", fromPin: TMHash.murmur64a("translation"), toPin: TMHash.murmur64a("value")),
        ], data: [])
        let host = CanonicalScriptRuntimeHost(state: RuntimeEntityState(translation: .init(1, 2, 3)))

        host.load(graph)
        host.dispatch("update", payload: ["deltaTime": 1])

        try #require(host.lastException == nil)
        #expect(variable("translation", host: host) as? [Double] == [1, 2, 3])
    }

    @Test func case2RuntimeEventDispatchCarriesCallbackOutputs() throws {
        let event = RCP3ScriptGraph.Node(id: "collision", type: "tm_collision_event_began")
        let capture = RCP3ScriptGraph.Node(id: "capture", type: "tm_set_variable_node", variableName: "impulse")
        let graph = RCP3ScriptGraph(nodes: [event, capture], wires: [
            .init(id: "exec", from: "collision", to: "capture"),
            .init(id: "value", from: "collision", to: "capture", fromPin: TMHash.murmur64a("impulse"), toPin: TMHash.murmur64a("value")),
        ], data: [])
        let host = CanonicalScriptRuntimeHost()

        host.load(graph)
        host.dispatch("collisionBegan", payload: ["impulse": 4.5])

        try #require(host.lastException == nil)
        #expect(variable("impulse", host: host) as? Double == 4.5)
        #expect(host.observation.operations.contains(.event("collisionBegan")))
    }

    @Test func case3FixedHierarchyActionIsObservablyInvoked() throws {
        let update = RCP3ScriptGraph.Node(id: "update", type: "tm_update")
        let add = RCP3ScriptGraph.Node(id: "add", type: "tm_add_child")
        let graph = RCP3ScriptGraph(nodes: [update, add], wires: [
            .init(id: "exec", from: "update", to: "add"),
        ], data: [
            .init(id: "preserve", toNode: "add", toPin: TMHash.murmur64a("preservingWorldTransform"), value: .bool(true)),
        ])
        let host = CanonicalScriptRuntimeHost()

        host.load(graph)
        host.dispatch("update")

        try #require(host.lastException == nil)
        #expect(host.observation.operations.contains(.addChild(preservingWorldTransform: true)))
    }

    @Test func case4MaterialReadWriteExecutesThroughGenericComponentAdapter() throws {
        let update = RCP3ScriptGraph.Node(id: "update", type: "tm_update")
        let set = RCP3ScriptGraph.Node(id: "set", type: "tm_set_material_parameter_v2")
        let get = RCP3ScriptGraph.Node(id: "get", type: "tm_get_material_parameter")
        let capture = RCP3ScriptGraph.Node(id: "capture", type: "tm_set_variable_node", variableName: "roughness")
        let graph = RCP3ScriptGraph(nodes: [update, set, get, capture], wires: [
            .init(id: "exec-set", from: "update", to: "set"),
            .init(id: "exec-capture", from: "set", to: "capture"),
            .init(id: "read", from: "get", to: "capture", fromPin: TMHash.murmur64a("value"), toPin: TMHash.murmur64a("value")),
        ], data: [
            .init(id: "set-slot", toNode: "set", toPin: TMHash.murmur64a("slot"), value: .number(0)),
            .init(id: "set-name", toNode: "set", toPin: TMHash.murmur64a("parameter"), value: .string("roughness")),
            .init(id: "set-value", toNode: "set", toPin: TMHash.murmur64a("value"), value: .number(0.65)),
            .init(id: "get-slot", toNode: "get", toPin: TMHash.murmur64a("slot"), value: .number(0)),
            .init(id: "get-name", toNode: "get", toPin: TMHash.murmur64a("parameter"), value: .string("roughness")),
        ])
        let host = CanonicalScriptRuntimeHost()
        host.seedMaterial(slot: 0)

        host.load(graph)
        host.dispatch("update")

        try #require(host.lastException == nil)
        #expect(variable("roughness", host: host) as? Double == 0.65)
        #expect(host.observation.operations.contains(.getComponent("ModelComponent")))
        #expect(host.observation.operations.contains(.setMaterialParameter("roughness")))
        #expect(host.observation.operations.contains(.getMaterialParameter("roughness")))
        #expect(host.observation.operations.contains(.setComponent("ModelComponent")))
    }

    @Test func comboTargetRunsAsAThreeTapStatefulProgram() throws {
        let host = CanonicalScriptRuntimeHost()
        host.load(ScriptGraphExamples.comboTarget.graph)
        host.activate()

        host.dispatchGesture("tap")
        try #require(host.lastException == nil)
        #expect(host.state.translation == SIMD3(0.25, 0, 0))

        host.dispatchGesture("tap")
        #expect(host.state.translation == SIMD3(0.5, 0, 0))

        host.dispatchGesture("tap")
        #expect(host.state.translation == SIMD3(0, 0.8, 0))
        #expect(host.state.scale == SIMD3(1.5, 1.5, 1.5))

        host.dispatchGesture("tap")
        #expect(host.state.translation == SIMD3(0.25, 0, 0))
        #expect(host.state.scale == SIMD3(1, 1, 1))
        #expect(host.lastException == nil)
    }

    @Test func floorSelectorCyclesFourComputedStates() throws {
        let host = CanonicalScriptRuntimeHost()
        host.load(ScriptGraphExamples.floorSelector.graph)
        host.activate()

        for expectedY in [0.4, 0.8, 1.2] {
            host.dispatchGesture("tap")
            try #require(host.lastException == nil)
            #expect(abs(host.state.translation.y - expectedY) < 0.000_001)
            #expect(host.state.scale == SIMD3(1, 1, 1))
        }

        host.dispatchGesture("tap")
        #expect(host.state.translation == .zero)
        #expect(host.state.scale == SIMD3(1.6, 0.8, 1))
        #expect(host.lastException == nil)
    }

    @Test func batchBuilderCommitsAfterFiveLoopSteps() throws {
        let host = CanonicalScriptRuntimeHost()
        host.load(ScriptGraphExamples.batchBuilder.graph)
        host.activate()
        host.dispatchGesture("tap")

        try #require(host.lastException == nil)
        #expect(abs(host.state.translation.x - 1) < 0.000_001)
        #expect(abs(host.state.scale.x - 1) < 0.000_001)
        #expect(abs(host.state.scale.y - 1) < 0.000_001)
        #expect(abs(host.state.scale.z - 1) < 0.000_001)
    }
}
