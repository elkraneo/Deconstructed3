import Foundation
import RCP3Document
import Testing
import TMFormat
@testable import RCP3GraphEditor

@MainActor
@Suite struct RCP3IntegrationTestFixtureExporterTests {
    @Test func smokeGraphHasObservedMinimumTestContract() throws {
        let graph = RCP3IntegrationTestFixtureExporter.smokeGraph()
        let begin = try #require(graph.nodes.first { $0.type == "tm_begin_test" })
        let finish = try #require(graph.nodes.first { $0.type == "tm_finish_test" })

        #expect(graph.nodes.count == 2)
        #expect(graph.wires == [.init(
            id: "d3c30000-0000-4000-8000-000000000003",
            from: begin.id,
            to: finish.id
        )])
        #expect(graph.data.contains {
            $0.toNode == finish.id
                && $0.toPin == TMHash.murmur64a("success")
                && $0.value == .bool(true)
        })
        #expect(graph.data.contains {
            $0.toNode == finish.id
                && $0.toPin == TMHash.murmur64a("message")
                && $0.value == .string("")
        })
        let validation = ScriptGraphValidator.validate(graph)
        #expect(validation.errors.isEmpty)
        #expect(validation.isStructurallyValid)
    }

    @Test func makeBoolSemanticGraphAssertsAndTerminatesWithSubjectValue() throws {
        let graph = RCP3IntegrationTestFixtureExporter.makeBoolSemanticGraph()
        let make = try #require(graph.nodes.first { $0.type == "tm_make_bool" })
        let assertion = try #require(graph.nodes.first { $0.type == "tm_test_assert" })
        let finish = try #require(graph.nodes.first { $0.type == "tm_finish_test" })
        let valueHash = TMHash.murmur64a("value")

        #expect(graph.nodes.count == 4)
        #expect(graph.wires.count == 4)
        #expect(graph.wires.contains {
            $0.from == make.id && $0.fromPin == valueHash
                && $0.to == assertion.id && $0.toPin == TMHash.murmur64a("condition")
        })
        #expect(graph.wires.contains {
            $0.from == make.id && $0.fromPin == valueHash
                && $0.to == finish.id && $0.toPin == TMHash.murmur64a("success")
        })
        #expect(graph.data.contains {
            $0.toNode == make.id && $0.toPin == TMHash.murmur64a("initial_value")
                && $0.value == .bool(true)
        })
        let validation = ScriptGraphValidator.validate(graph)
        #expect(validation.errors.isEmpty)
        #expect(validation.isStructurallyValid)
    }

    @Test func exportsDigestBoundProjectWithSubjectAndAttachedSmokeAssets() throws {
        let template = try makeTemplate()
        let root = FileManager.default.temporaryDirectory
            .appending(path: "rcp3-test-export-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: template)
            try? FileManager.default.removeItem(at: root)
        }

        let matrix = ScriptGraphContractMatrix.make()
        let contractCase = try #require(matrix.cases.first)
        let result = try RCP3IntegrationTestFixtureExporter.export(
            templateProject: template,
            certificationRoot: root,
            requestedType: contractCase.requestedType,
            matrix: matrix
        )

        #expect(result.projectURL.lastPathComponent == contractCase.certificationProjectName)
        #expect(result.fixtureDigest == contractCase.fixtureDigest)
        let editor = try RCP3Editor.open(result.projectURL)
        #expect(editor.scriptGraphAssets().count == 2)
        #expect(editor.assignedScriptGraphAssetID(entityID: editor.entity.id) == result.smokeAssetID)
        let smoke = try #require(editor.scriptGraph(assetID: result.smokeAssetID))
        #expect(smoke.nodes.map(\.type) == ["tm_begin_test", "tm_finish_test"])
        #expect(smoke.data.contains { $0.value == .bool(true) })
        #expect(smoke.data.contains { $0.value == .string("") })
        let smokeAsset = try #require(assetObject(rootUUID: result.smokeAssetID, in: result.projectURL))
        #expect(ScriptGraphWriteBack.validationSettings(in: smokeAsset) == .integrationTest)

        let subject = try #require(editor.scriptGraph(assetID: result.subjectAssetID))
        let fixture = try #require(ScriptGraphGeneratedCorpus.all.first {
            $0.requestedType == contractCase.requestedType
        })
        #expect(subject.nodes.map(\.type) == fixture.graph.nodes.map(\.type))
        #expect(subject.wires.count == fixture.graph.wires.count)
        #expect(subject.data.map(\.toPin) == fixture.graph.data.map(\.toPin))
        let subjectAsset = try #require(assetObject(rootUUID: result.subjectAssetID, in: result.projectURL))
        #expect(ScriptGraphWriteBack.validationSettings(in: subjectAsset)?.isTest == false)
    }

    @Test func exportsAttachedRegisteredMakeBoolSemanticTest() throws {
        let template = try makeTemplate()
        let root = FileManager.default.temporaryDirectory
            .appending(path: "rcp3-semantic-export-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: template)
            try? FileManager.default.removeItem(at: root)
        }

        let result = try RCP3IntegrationTestFixtureExporter.exportSemantic(
            templateProject: template,
            certificationRoot: root,
            requestedType: "tm_make_bool"
        )
        let editor = try RCP3Editor.open(result.projectURL)
        #expect(editor.assignedScriptGraphAssetID(entityID: editor.entity.id) == result.smokeAssetID)
        let graph = try #require(editor.scriptGraph(assetID: result.smokeAssetID))
        #expect(Set(graph.nodes.map(\.type)) == [
            "tm_begin_test", "tm_make_bool", "tm_test_assert", "tm_finish_test",
        ])
        let asset = try #require(assetObject(rootUUID: result.smokeAssetID, in: result.projectURL))
        #expect(ScriptGraphWriteBack.validationSettings(in: asset) == .integrationTest)
    }

    @Test func sanitizesACloneWithoutMutatingTemplateGraphs() throws {
        let template = try makeTemplate()
        let root = FileManager.default.temporaryDirectory
            .appending(path: "rcp3-test-export-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: template)
            try? FileManager.default.removeItem(at: root)
        }
        let existing = try RCP3Bundle.open(template).createScriptGraphAsset(named: "Existing")
        let requestedType = try #require(ScriptGraphContractMatrix.make().cases.first?.requestedType)

        let result = try RCP3IntegrationTestFixtureExporter.export(
            templateProject: template,
            certificationRoot: root,
            requestedType: requestedType
        )
        let sourceAfterExport = try RCP3Bundle.open(template)
        let exportedBundle = try RCP3Bundle.open(result.projectURL)
        #expect(sourceAfterExport.scriptGraphAssets().map(\.id) == [existing.id])
        #expect(exportedBundle.scriptGraphAssets().count == 2)
    }

    private func makeTemplate() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "rcp3-test-template-\(UUID().uuidString).realitycomposerpro")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: directory.appending(path: "project.rcp").path,
            contents: Data()
        )
        try """
        __type: "tm_entity"
        __uuid: "d3c30000-0000-4000-8000-000000000100"
        name: "world"
        """.write(
            to: directory.appending(path: "world.tm_entity"),
            atomically: true,
            encoding: .utf8
        )
        return directory
    }

    private func assetObject(rootUUID: String, in bundleURL: URL) -> TMObject? {
        let entries = try? FileManager.default.contentsOfDirectory(
            at: bundleURL,
            includingPropertiesForKeys: nil
        )
        for url in entries ?? [] where url.pathExtension == "tm_script_graph" {
            guard
                let text = try? String(contentsOf: url, encoding: .utf8),
                let object = try? TM.parse(text).objectValue,
                object.uuid == rootUUID
            else { continue }
            return object
        }
        return nil
    }
}
