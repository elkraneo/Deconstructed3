import Foundation
import RCP3Document
@testable import RCP3GraphEditor
import RCP3NodeLib
import Testing

@Suite struct ScriptGraphNodeRegistryTests {
    @Test @MainActor func resolvesRegisteredNodeLibMethodAsStaticInterface() throws {
        let method = NodeLibLibrary.Method(
            name: "addChild",
            type: "instance",
            parameters: [
                .init(name: "arg0", type: "Entity", module: "RealityKit"),
                .init(name: "arg1", type: "Bool", module: "PrimitiveTypes"),
            ]
        )
        let library = NodeLibLibrary(
            name: "MyGameLibrary",
            uniqueID: "deconstructed3-certification-nodelib-v1",
            nodes: [
                .init(
                    name: "spawnPlayer",
                    displayName: "Spawn Player",
                    category: "Gameplay",
                    object: "Entity",
                    isPure: false,
                    method: method
                )
            ]
        )
        let registry = ScriptGraphNodeRegistry(nodeLibraries: [library])
        let identity = try #require(library.methodDeclarations.first?.identity)
        let spec = try #require(registry.spec(for: identity))

        #expect(identity == "node_17854906811712824314")
        #expect(spec.inputs.map(\.connectorName) == ["exec", "source", "arg0", "arg1"])
        #expect(spec.outputs.map(\.connectorName) == ["exec"])
        #expect(registry.nodeLibPaletteItems.first?.displayName == "Spawn Player")
        let spawnMatches = Set(
            registry.paletteSections(matching: "spawn").flatMap(\.items).map(\.type)
        )
        #expect(spawnMatches.contains(identity))
        #expect(spawnMatches.contains("tm_spawn_entity"))

        let graph = RCP3ScriptGraph(
            nodes: [.init(id: "custom", type: identity)],
            wires: [],
            data: []
        )
        let node = try #require(graph.nodes.first)
        let pins = ScriptGraphPinResolver.pins(for: node, in: graph, registry: registry)
        #expect(pins.count == 5)

        let model = ScriptGraphEditorModel(graph: graph, nodeRegistry: registry)
        #expect(model.nodes.first?.payload.pins.count == 5)
    }

    @Test func externalCatalogRetainsOpaqueTypedAuthoringMetadata() throws {
        let move = ScriptGraphExternalAuthoringCatalog.Node(
            id: "private::game::move",
            operationID: "game.move(instance:distance:)",
            displayName: "Move",
            category: .components,
            execution: .action,
            isAsync: true,
            inputs: [
                .init(name: "source", displayName: "Source", typeToken: "Game.Mover"),
                .init(
                    name: "distance", displayName: "Distance", typeToken: "Swift.Double",
                    isOptional: true, isVariadic: true
                ),
            ],
            outputs: [.init(name: "result", displayName: "Result", typeToken: "Swift.Bool")]
        )
        let registry = ScriptGraphNodeRegistry(
            externalCatalog: .init(nodes: [move])
        )

        let moveSpec = try #require(registry.spec(for: move.id))
        #expect(moveSpec.inputs.map(\.connectorName) == ["exec", "source", "distance"])
        #expect(moveSpec.outputs.map(\.connectorName) == ["exec", "result"])
        #expect(registry.nodeLibPaletteItems.contains { $0.id == move.id })
        #expect(registry.externalNodes[move.id]?.operationID == move.operationID)
        #expect(registry.externalNodes[move.id]?.isAsync == true)
        #expect(registry.externalNodes[move.id]?.inputs.last?.typeToken == "Swift.Double")
        #expect(registry.externalNodes[move.id]?.inputs.last?.isOptional == true)
        #expect(registry.externalNodes[move.id]?.inputs.last?.isVariadic == true)
    }
}
