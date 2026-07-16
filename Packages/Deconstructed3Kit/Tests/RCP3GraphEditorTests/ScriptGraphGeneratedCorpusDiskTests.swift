import Foundation
import Testing
import RCP3Document
import TMFormat
@testable import RCP3GraphEditor

/// Disk-level evidence for the complete creator-visible authoring surface.
///
/// The generated corpus is deliberately broader than the curated behavioral
/// gallery: it contains one deterministic fixture for every palette item whose
/// RCP3 authoring recipe is concrete. This suite takes every one of those
/// fixtures through the real asset writer and parser instead of stopping at an
/// in-memory graph.
@MainActor
@Suite struct ScriptGraphGeneratedCorpusDiskTests {
    @Test func everyCreatorVisibleRecipeMaterializesAndReopensFromDisk() throws {
        let creatorVisibleTypes = Set(
            ScriptGraphNodeLibrary.paletteItems.compactMap { item in
                ScriptGraphAuthoringRecipes.recipe(for: item.type) == nil ? nil : item.type
            }
        )
        let generatedCases = ScriptGraphGeneratedCorpus.all
        let generatedTypes = Set(generatedCases.map(\.requestedType))
        let cases = generatedCases.map { ($0.requestedType, $0.graph) }

        // Keep the disk gate coupled to the live palette/recipe intersection, so
        // adding a newly authorable RCP3 node cannot silently miss this test.
        #expect(generatedCases.count == generatedTypes.count, "Generated cases must be unique by requested type")
        #expect(Set(cases.map(\.0)) == creatorVisibleTypes)
        #expect(cases.count == 344)

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "rcp3-generated-corpus-\(UUID().uuidString).realitycomposerpro")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        FileManager.default.createFile(
            atPath: directory.appending(path: "project.rcp").path,
            contents: Data()
        )
        try "__type: \"tm_entity\"\n__uuid: \"w\"\nname: \"world\""
            .write(to: directory.appending(path: "world.tm_entity"), atomically: true, encoding: .utf8)

        let bundle = try RCP3Bundle.open(directory)
        var expectedByAssetID: [String: (String, RCP3ScriptGraph)] = [:]
        for (requestedType, graph) in cases {
            let validation = ScriptGraphValidator.validate(graph)
            #expect(validation.errors.isEmpty, "\(requestedType): structural/settings validation")
            let asset = try bundle.createScriptGraphAsset(named: requestedType)
            try ScriptGraphWriteBack.write(
                model: ScriptGraphEditorModel(graph: graph),
                toAssetWithRootUUID: asset.id,
                in: bundle.url
            )
            expectedByAssetID[asset.id] = (requestedType, graph)
        }

        let reopened = try RCP3Bundle.open(directory)
        let assets = reopened.scriptGraphAssets()
        #expect(assets.count == cases.count)
        #expect(Set(assets.map(\.id)) == Set(expectedByAssetID.keys))

        for asset in assets {
            let item = try #require(expectedByAssetID[asset.id])
            let graph = try #require(reopened.scriptGraph(assetID: asset.id))
            assertDiskStructure(graph, equals: item.1, requestedType: item.0)
        }
    }

    private func assertDiskStructure(
        _ actual: RCP3ScriptGraph,
        equals source: RCP3ScriptGraph,
        requestedType: String
    ) {
        let expectedNodes = Dictionary(uniqueKeysWithValues: source.nodes.enumerated().map { index, node in
            // Fresh graph nodes have no position. The writer materializes the
            // editor's deterministic 320-point fallback lane, so compare against
            // that documented materialization boundary.
            let canonical = RCP3ScriptGraph.Node(
                id: node.id,
                type: node.type,
                label: node.label,
                x: node.x ?? Double(index) * 320,
                y: node.y ?? 0,
                variableName: node.variableName,
                variableRefUUID: node.variableRefUUID,
                instanceOf: node.instanceOf,
                enumSelection: node.enumSelection,
                dynamicConnectorSettings: node.dynamicConnectorSettings,
                materialSettings: node.materialSettings,
                entityParameterSettings: node.entityParameterSettings
            )
            return (node.id, canonical)
        })
        let actualNodes = Dictionary(uniqueKeysWithValues: actual.nodes.map { ($0.id, $0) })
        #expect(Set(actualNodes.keys) == Set(expectedNodes.keys), "\(requestedType): node identities")
        for (id, expected) in expectedNodes {
            #expect(actualNodes[id] == expected, "\(requestedType)/\(id): complete node settings")
        }

        struct Connection: Hashable {
            let from: String
            let to: String
            let fromPin: UInt64?
            let toPin: UInt64?
        }
        let expectedConnections = Set(source.wires.map {
            Connection(from: $0.from, to: $0.to, fromPin: $0.fromPin, toPin: $0.toPin)
        })
        let actualConnections = Set(actual.wires.map {
            Connection(from: $0.from, to: $0.to, fromPin: $0.fromPin, toPin: $0.toPin)
        })
        #expect(actualConnections == expectedConnections, "\(requestedType): wire connectivity and hashes")

        struct Literal: Hashable {
            let toNode: String
            let toPin: UInt64
            let valueType: String?
            let valueHash: UInt64?
            let value: TMGraphValue?
        }
        let expectedLiterals = Set(source.data.map {
            Literal(
                toNode: $0.toNode,
                toPin: $0.toPin,
                valueType: $0.valueType ?? canonicalValueType(for: $0.value),
                valueHash: $0.valueHash,
                value: $0.value
            )
        })
        let actualLiterals = Set(actual.data.map {
            Literal(
                toNode: $0.toNode,
                toPin: $0.toPin,
                valueType: $0.valueType,
                valueHash: $0.valueHash,
                value: $0.value
            )
        })
        #expect(actualLiterals == expectedLiterals, "\(requestedType): typed literals")

        let expectedVariables = Dictionary(uniqueKeysWithValues: source.variables.map { ($0.uuid, $0) })
        let actualVariables = Dictionary(uniqueKeysWithValues: actual.variables.map { ($0.uuid, $0) })
        #expect(actualVariables == expectedVariables, "\(requestedType): typed variable table")
    }

    /// Plain in-memory bool/string values acquire their canonical typed wrapper
    /// when serialized. Number values intentionally use the untyped scalar form.
    private func canonicalValueType(for value: TMGraphValue?) -> String? {
        switch value {
        case .bool?: "tm_bool"
        case .string?: "tm_string"
        case .number?, .variableRef?, nil: nil
        }
    }
}
