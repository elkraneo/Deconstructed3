import Foundation
import RCP3Document
import TMFormat

/// Materializes digest-bound RCP3 integration-test smoke projects from an
/// initialized project template.
///
/// Each project carries the exact canonical contract fixture as an unassigned
/// asset and executes a separate `tm_begin_test` -> `tm_finish_test` graph. This
/// is deliberately a harness/load smoke tier, not a claim that the subject
/// node's runtime semantics were asserted.
@MainActor
public enum RCP3IntegrationTestFixtureExporter {
    public enum ExportError: Error, CustomStringConvertible, Equatable {
        case templateIsNotRealityComposerProject(String)
        case unknownRequestedType(String)
        case semanticFixtureUnavailable(String)
        case destinationExists(String)
        case cannotAttachSmokeGraph

        public var description: String {
            switch self {
            case let .templateIsNotRealityComposerProject(path):
                "Template is not an initialized .realitycomposerpro project: \(path)"
            case let .unknownRequestedType(type):
                "No contract-matrix case exists for requested type \(type)."
            case let .semanticFixtureUnavailable(type):
                "No runtime-semantic certification fixture exists yet for requested type \(type)."
            case let .destinationExists(path):
                "Refusing to overwrite existing certification project: \(path)"
            case .cannotAttachSmokeGraph:
                "Could not add or assign the integration-test graph to the root entity."
            }
        }
    }

    public struct ExportedProject: Sendable, Equatable {
        public let requestedType: String
        public let fixtureDigest: String
        public let projectURL: URL
        public let subjectAssetID: String
        public let smokeAssetID: String

        public init(
            requestedType: String,
            fixtureDigest: String,
            projectURL: URL,
            subjectAssetID: String,
            smokeAssetID: String
        ) {
            self.requestedType = requestedType
            self.fixtureDigest = fixtureDigest
            self.projectURL = projectURL
            self.subjectAssetID = subjectAssetID
            self.smokeAssetID = smokeAssetID
        }
    }

    /// The minimum observed RCP3 integration-test harness graph.
    public static func smokeGraph() -> RCP3ScriptGraph {
        let beginID = "d3c30000-0000-4000-8000-000000000001"
        let finishID = "d3c30000-0000-4000-8000-000000000002"
        return RCP3ScriptGraph(
            id: "rcp3-integration-test-smoke",
            nodes: [
                .init(id: beginID, type: "tm_begin_test", label: "Certification Begin", x: 0, y: 0),
                .init(id: finishID, type: "tm_finish_test", label: "Certification Finish", x: 320, y: 0),
            ],
            wires: [
                .init(
                    id: "d3c30000-0000-4000-8000-000000000003",
                    from: beginID,
                    to: finishID
                ),
            ],
            data: [
                .init(
                    id: "d3c30000-0000-4000-8000-000000000004",
                    toNode: finishID,
                    toPin: TMHash.murmur64a("success"),
                    value: .bool(true)
                ),
                .init(
                    id: "d3c30000-0000-4000-8000-000000000005",
                    toNode: finishID,
                    toPin: TMHash.murmur64a("message"),
                    value: .string("")
                ),
            ]
        )
    }

    /// A runtime-semantic fixture for the Bool constructor. Unlike the generic
    /// smoke graph, this routes the subject's value through RCP3's assertion node
    /// and into the terminal test result.
    public static func makeBoolSemanticGraph() -> RCP3ScriptGraph {
        let beginID = "d3c30000-0000-4000-8000-000000000011"
        let makeID = "d3c30000-0000-4000-8000-000000000012"
        let assertID = "d3c30000-0000-4000-8000-000000000013"
        let finishID = "d3c30000-0000-4000-8000-000000000014"
        let value = TMHash.murmur64a("value")
        return RCP3ScriptGraph(
            id: "rcp3-make-bool-semantic-test",
            nodes: [
                .init(id: beginID, type: "tm_begin_test", label: "Certification Begin", x: 0, y: 0),
                .init(id: makeID, type: "tm_make_bool", label: "Bool Under Test", x: 0, y: 220),
                .init(id: assertID, type: "tm_test_assert", label: "Assert Bool", x: 320, y: 0),
                .init(id: finishID, type: "tm_finish_test", label: "Certification Finish", x: 680, y: 0),
            ],
            wires: [
                .init(id: "d3c30000-0000-4000-8000-000000000015", from: beginID, to: assertID),
                .init(
                    id: "d3c30000-0000-4000-8000-000000000016",
                    from: makeID, to: assertID,
                    fromPin: value, toPin: TMHash.murmur64a("condition")
                ),
                .init(
                    id: "d3c30000-0000-4000-8000-000000000017",
                    from: assertID, to: finishID,
                    fromPin: TMHash.murmur64a("always")
                ),
                .init(
                    id: "d3c30000-0000-4000-8000-000000000018",
                    from: makeID, to: finishID,
                    fromPin: value, toPin: TMHash.murmur64a("success")
                ),
            ],
            data: [
                .init(
                    id: "d3c30000-0000-4000-8000-000000000019",
                    toNode: makeID,
                    toPin: TMHash.murmur64a("initial_value"),
                    value: .bool(true)
                ),
                .init(
                    id: "d3c30000-0000-4000-8000-000000000020",
                    toNode: assertID,
                    toPin: TMHash.murmur64a("message"),
                    value: .string("Bool constructor returned false")
                ),
                .init(
                    id: "d3c30000-0000-4000-8000-000000000021",
                    toNode: finishID,
                    toPin: TMHash.murmur64a("message"),
                    value: .string("")
                ),
            ]
        )
    }

    /// Exports one digest-bound smoke project for `requestedType`.
    public static func export(
        templateProject: URL,
        certificationRoot: URL,
        requestedType: String,
        matrix: ScriptGraphContractMatrix = .make()
    ) throws -> ExportedProject {
        let item = try caseAndFixture(requestedType: requestedType, matrix: matrix)
        return try export(
            templateProject: templateProject,
            certificationRoot: certificationRoot,
            contractCase: item.contractCase,
            fixture: item.fixture
        )
    }

    /// Exports the first case-specific semantic fixture. Additional subjects can
    /// be added family-by-family without weakening generic smoke evidence.
    public static func exportSemantic(
        templateProject: URL,
        certificationRoot: URL,
        requestedType: String,
        matrix: ScriptGraphContractMatrix = .make()
    ) throws -> ExportedProject {
        let item = try caseAndFixture(requestedType: requestedType, matrix: matrix)
        guard requestedType == "tm_make_bool" else {
            throw ExportError.semanticFixtureUnavailable(requestedType)
        }
        return try export(
            templateProject: templateProject,
            certificationRoot: certificationRoot,
            contractCase: item.contractCase,
            fixture: item.fixture,
            testGraph: makeBoolSemanticGraph(),
            testAssetName: "Certification Semantic Test"
        )
    }

    /// Exports one smoke project for every current contract-matrix case.
    public static func exportAll(
        templateProject: URL,
        certificationRoot: URL,
        matrix: ScriptGraphContractMatrix = .make()
    ) throws -> [ExportedProject] {
        try validateTemplate(templateProject)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: certificationRoot, withIntermediateDirectories: true)
        let fixtureByType = Dictionary(
            uniqueKeysWithValues: ScriptGraphGeneratedCorpus.all.map { ($0.requestedType, $0) }
        )
        for contractCase in matrix.cases {
            guard fixtureByType[contractCase.requestedType] != nil else {
                throw ExportError.unknownRequestedType(contractCase.requestedType)
            }
            let destination = certificationRoot.appending(path: contractCase.certificationProjectName)
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw ExportError.destinationExists(destination.path)
            }
        }
        return try matrix.cases.map { contractCase in
            let fixture = fixtureByType[contractCase.requestedType]!
            return try export(
                templateProject: templateProject,
                certificationRoot: certificationRoot,
                contractCase: contractCase,
                fixture: fixture,
                templateAlreadyValidated: true
            )
        }
    }

    private static func caseAndFixture(
        requestedType: String,
        matrix: ScriptGraphContractMatrix
    ) throws -> (contractCase: ScriptGraphContractMatrix.ContractCase, fixture: ScriptGraphGeneratedCorpus.Case) {
        guard
            let contractCase = matrix.cases.first(where: { $0.requestedType == requestedType }),
            let fixture = ScriptGraphGeneratedCorpus.all.first(where: { $0.requestedType == requestedType })
        else { throw ExportError.unknownRequestedType(requestedType) }
        return (contractCase, fixture)
    }

    private static func export(
        templateProject: URL,
        certificationRoot: URL,
        contractCase: ScriptGraphContractMatrix.ContractCase,
        fixture: ScriptGraphGeneratedCorpus.Case,
        templateAlreadyValidated: Bool = false,
        testGraph: RCP3ScriptGraph? = nil,
        testAssetName: String = "Certification Smoke"
    ) throws -> ExportedProject {
        if !templateAlreadyValidated { try validateTemplate(templateProject) }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: certificationRoot, withIntermediateDirectories: true)
        let destination = certificationRoot.appending(path: contractCase.certificationProjectName)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw ExportError.destinationExists(destination.path)
        }
        try fileManager.copyItem(at: templateProject, to: destination)

        do {
            var editor = try RCP3Editor.open(destination)
            // The source project is never mutated. Sanitize only the clone so an
            // RCP3-saved project can be reused without inherited test graphs or a
            // stale Scripting Component assignment affecting certification.
            for asset in editor.scriptGraphAssets() {
                try editor.deleteScriptGraphAsset(id: asset.id)
            }
            _ = editor.removeScriptingComponent(fromEntityID: editor.entity.id)
            try editor.save()

            let subjectAsset = try editor.createScriptGraphAsset(named: "Certification Subject")
            try ScriptGraphWriteBack.write(
                model: ScriptGraphEditorModel(graph: fixture.graph),
                toAssetWithRootUUID: subjectAsset.id,
                in: destination
            )

            let smokeAsset = try editor.createScriptGraphAsset(named: testAssetName)
            try ScriptGraphWriteBack.write(
                model: ScriptGraphEditorModel(graph: testGraph ?? smokeGraph()),
                toAssetWithRootUUID: smokeAsset.id,
                in: destination
            )
            try ScriptGraphWriteBack.write(
                validationSettings: .integrationTest,
                toAssetWithRootUUID: smokeAsset.id,
                in: destination
            )

            let rootID = editor.entity.id
            if !editor.hasScriptingComponent(entityID: rootID) {
                guard editor.addScriptingComponent(toEntityID: rootID) else {
                    throw ExportError.cannotAttachSmokeGraph
                }
            }
            guard editor.assignScriptGraph(toEntityID: rootID, assetRootUUID: smokeAsset.id) else {
                throw ExportError.cannotAttachSmokeGraph
            }
            try editor.save()
            return ExportedProject(
                requestedType: contractCase.requestedType,
                fixtureDigest: contractCase.fixtureDigest,
                projectURL: destination,
                subjectAssetID: subjectAsset.id,
                smokeAssetID: smokeAsset.id
            )
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    private static func validateTemplate(_ templateProject: URL) throws {
        guard templateProject.pathExtension == "realitycomposerpro" else {
            throw ExportError.templateIsNotRealityComposerProject(templateProject.path)
        }
        do {
            _ = try RCP3Bundle.open(templateProject)
        } catch {
            throw ExportError.templateIsNotRealityComposerProject(templateProject.path)
        }
    }
}
