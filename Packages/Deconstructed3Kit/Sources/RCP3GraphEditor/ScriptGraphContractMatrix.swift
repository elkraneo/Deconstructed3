import CryptoKit
import Foundation
import RCP3Document
import TMFormat

/// Deterministic, field-level accounting for the RCP3 Script Graph authoring
/// contract. The matrix deliberately exposes independent denominators instead of
/// collapsing structural, typing, and external execution evidence into one score.
public struct ScriptGraphContractMatrix: Codable, Sendable, Equatable {
    public static let baseline = "reality-composer-pro-3"
    public static let currentSchemaVersion = 1

    public enum FieldStatus: String, Codable, Sendable {
        case exact
        case relational
        case notApplicable
        case gap
    }

    public enum Resolution: String, Codable, Sendable {
        case exact
        case partial
        case unresolved
    }

    public enum EvidenceStatus: String, Codable, Sendable {
        case pass
        case fail
        case notRecorded
    }

    public struct PinContract: Codable, Sendable, Equatable {
        public let ordinal: Int
        public let direction: String
        public let kind: String
        public let connectorName: String
        public let displayName: String
        public let connectorHash: String?
        public let typeConstraint: String
        public let resolvedTypeToken: String?
        public let resolvedTypeHash: String?
        public let presence: String
        public let evidence: String
        public let identityStatus: FieldStatus
        public let directionStatus: FieldStatus
        public let typeStatus: FieldStatus
        public let presenceStatus: FieldStatus
    }

    public struct Validation: Codable, Sendable, Equatable {
        public let structurallyValid: Bool
        public let completeCoverage: Bool
        public let staticallyReady: Bool
        public let errors: [String]
        public let warnings: [String]
    }

    public struct Evidence: Codable, Sendable, Equatable {
        public let status: EvidenceStatus
        public let fixtureDigest: String
        public let applicationVersion: String?
        public let applicationBuild: String?

        public init(
            status: EvidenceStatus = .notRecorded,
            fixtureDigest: String,
            applicationVersion: String? = nil,
            applicationBuild: String? = nil
        ) {
            self.status = status
            self.fixtureDigest = fixtureDigest
            self.applicationVersion = applicationVersion
            self.applicationBuild = applicationBuild
        }
    }

    public struct ContractCase: Codable, Sendable, Equatable {
        public let requestedType: String
        public let authoredType: String
        public let category: String
        public let topology: String
        public let fixtureKind: String
        public let variantID: String
        public let coverageMode: String
        public let settingsKind: String
        public let settingsFingerprint: String
        public let subjectNodeID: String
        public let fixtureDigest: String
        public let contractResolution: Resolution
        public let pins: [PinContract]
        public let validation: Validation
        public let serialization: Evidence
        public let compiler: Evidence
        public let rcp3AuthoringCertification: Evidence
        public let rcp3RuntimeCertification: Evidence
    }

    public struct Metric: Codable, Sendable, Equatable {
        public let id: String
        public let numerator: Int
        public let denominator: Int
        public let unit: String
        public let criterion: String
        public let exclusions: [String]
        public let gapIDs: [String]
    }

    public let schemaVersion: Int
    public let baseline: String
    public let catalogDigest: String
    public let generatorRevision: String
    public let cases: [ContractCase]
    public let metrics: [Metric]

    public static func make(
        registry: ScriptGraphNodeRegistry = .builtins
    ) -> ScriptGraphContractMatrix {
        let cases = ScriptGraphGeneratedCorpus.all.map { item in
            makeCase(item, registry: registry)
        }
        let catalogDigest = digest(cases.map {
            "\($0.requestedType)|\($0.authoredType)|\($0.settingsFingerprint)|\($0.fixtureDigest)"
        }.joined(separator: "\n"))
        return .init(
            schemaVersion: currentSchemaVersion,
            baseline: baseline,
            catalogDigest: catalogDigest,
            generatorRevision: "contract-matrix-v1",
            cases: cases,
            metrics: makeMetrics(cases)
        )
    }

    private static func makeCase(
        _ item: ScriptGraphGeneratedCorpus.Case,
        registry: ScriptGraphNodeRegistry
    ) -> ContractCase {
        let subject = item.graph.nodes.first { $0.type == item.authoredType }
            ?? item.graph.nodes.last!
        let spec = ScriptGraphPinResolver.resolvedContract(
            for: subject,
            in: item.graph,
            registry: registry
        )
        // Coverage/readiness belongs to the canonical subject, not to the Update
        // helper that merely makes action/scoped fixtures reachable.
        let subjectGraph = RCP3ScriptGraph(
            id: item.graph.id,
            nodes: [subject],
            wires: item.graph.wires.filter { $0.from == subject.id && $0.to == subject.id },
            data: item.graph.data.filter { $0.toNode == subject.id },
            variables: item.graph.variables
        )
        let report = ScriptGraphValidator.validate(subjectGraph, registry: registry)
        let pins = spec.map { makePins($0) } ?? []
        let fixtureDigest = digest(graphFingerprint(item.graph))
        let settingsFingerprint = digest(settingsDescription(subject))
        let resolution: Resolution
        if spec == nil {
            resolution = .unresolved
        } else if pins.allSatisfy({
            $0.identityStatus != .gap && $0.typeStatus != .gap && $0.presenceStatus != .gap
        }) {
            resolution = .exact
        } else {
            resolution = .partial
        }
        let validation = Validation(
            structurallyValid: report.isStructurallyValid,
            completeCoverage: report.hasCompleteCoverage,
            staticallyReady: report.isStaticallyReady,
            errors: report.errors.map { "\($0.code.rawValue):\($0.subject)" },
            warnings: report.warnings.map { "\($0.code.rawValue):\($0.subject)" }
        )
        let unrecorded = Evidence(fixtureDigest: fixtureDigest)
        return ContractCase(
            requestedType: item.requestedType,
            authoredType: item.authoredType,
            category: item.category.rawValue,
            topology: topologyName(item.topology),
            fixtureKind: "canonical-authoring",
            variantID: "canonical",
            coverageMode: "canonical",
            settingsKind: settingsKind(subject),
            settingsFingerprint: settingsFingerprint,
            subjectNodeID: subject.id,
            fixtureDigest: fixtureDigest,
            contractResolution: resolution,
            pins: pins,
            validation: validation,
            serialization: unrecorded,
            compiler: unrecorded,
            rcp3AuthoringCertification: unrecorded,
            rcp3RuntimeCertification: unrecorded
        )
    }

    private static func makePins(
        _ spec: ScriptGraphNodeLibrary.NodeSpec
    ) -> [PinContract] {
        func convert(
            _ pin: ScriptGraphNodeLibrary.PinSpec,
            ordinal: Int,
            direction: String
        ) -> PinContract {
            let type = typeDescription(pin.typeConstraint)
            let typeStatus: FieldStatus = if pin.isExec {
                .notApplicable
            } else {
                switch pin.typeConstraint {
                case .concrete, .any: .exact
                case .sameAs, .arrayElement, .array: .relational
                case .unknown: .gap
                }
            }
            let presenceStatus: FieldStatus = if direction == "output" || pin.isExec {
                .notApplicable
            } else {
                pin.presence == .unknown ? .gap : .exact
            }
            let concrete: (String?, UInt64?) = switch pin.typeConstraint {
            case let .concrete(token, hash): (token, hash)
            default: (nil, nil)
            }
            return .init(
                ordinal: ordinal,
                direction: direction,
                kind: pin.isExec ? "execution" : "data",
                connectorName: pin.connectorName,
                displayName: pin.displayName,
                connectorHash: pin.isExec ? nil : TMHash.hex(pin.connectorHash),
                typeConstraint: type,
                resolvedTypeToken: concrete.0,
                resolvedTypeHash: concrete.1.map(TMHash.hex),
                presence: presenceName(pin.presence),
                evidence: pin.contractEvidence.rawValue,
                identityStatus: pin.contractEvidence == .unknown ? .gap : .exact,
                directionStatus: .exact,
                typeStatus: typeStatus,
                presenceStatus: presenceStatus
            )
        }
        return spec.inputs.enumerated().map { convert($0.element, ordinal: $0.offset, direction: "input") }
            + spec.outputs.enumerated().map { convert($0.element, ordinal: $0.offset, direction: "output") }
    }

    private static func makeMetrics(_ cases: [ContractCase]) -> [Metric] {
        let pins = cases.flatMap { item in item.pins.map { (item, $0) } }
        let dataPins = pins.filter { $0.1.kind == "data" }
        let inputDataPins = dataPins.filter { $0.1.direction == "input" }

        func metric(
            _ id: String,
            _ values: [(String, Bool)],
            unit: String,
            criterion: String,
            exclusions: [String] = []
        ) -> Metric {
            .init(
                id: id,
                numerator: values.count(where: \.1),
                denominator: values.count,
                unit: unit,
                criterion: criterion,
                exclusions: exclusions,
                gapIDs: values.filter { !$0.1 }.map(\.0).sorted()
            )
        }

        return [
            metric(
                "subject-contract-resolution",
                cases.map { ($0.requestedType, $0.contractResolution != .unresolved) },
                unit: "subject",
                criterion: "A graph-aware node contract resolves for the canonical subject."
            ),
            metric(
                "structural-validity",
                cases.map { ($0.requestedType, $0.validation.structurallyValid) },
                unit: "fixture",
                criterion: "The canonical fixture has no structural or settings error."
            ),
            metric(
                "pin-identity-evidence",
                pins.map { (pinID($0.0, $0.1, field: "identity"), $0.1.identityStatus == .exact) },
                unit: "pin",
                criterion: "The connector identity carries non-unknown contract provenance."
            ),
            metric(
                "pin-direction-kind",
                pins.map { (pinID($0.0, $0.1, field: "direction"), $0.1.directionStatus == .exact) },
                unit: "pin",
                criterion: "Input/output direction and execution/data kind are resolved."
            ),
            metric(
                "data-pin-concrete-type",
                dataPins.map { (pinID($0.0, $0.1, field: "type"), $0.1.typeStatus == .exact) },
                unit: "data-pin",
                criterion: "The data pin resolves to a concrete or explicitly Any value contract.",
                exclusions: ["Relational constraints remain gaps until instance unification."]
            ),
            metric(
                "input-data-presence",
                inputDataPins.map { (pinID($0.0, $0.1, field: "presence"), $0.1.presenceStatus == .exact) },
                unit: "input-data-pin",
                criterion: "Required, optional, registration-default, or implicit-self presence is observed."
            ),
            metric(
                "complete-subject-contract",
                cases.map { ($0.requestedType, $0.contractResolution == .exact) },
                unit: "subject",
                criterion: "Every subject pin has evidenced identity and complete type/presence semantics."
            ),
            metric(
                "static-readiness",
                cases.map { ($0.requestedType, $0.validation.staticallyReady) },
                unit: "fixture",
                criterion: "The validator reports complete coverage and no unresolved required input."
            ),
            metric(
                "rcp3-authoring-certification",
                cases.map { ($0.requestedType, $0.rcp3AuthoringCertification.status == .pass) },
                unit: "fixture",
                criterion: "The exact fingerprint is externally accepted by the recorded RCP3 build."
            ),
            metric(
                "rcp3-runtime-certification",
                cases.map { ($0.requestedType, $0.rcp3RuntimeCertification.status == .pass) },
                unit: "fixture",
                criterion: "The exact fingerprint executes successfully in the recorded RCP3 build."
            ),
        ]
    }

    private static func pinID(
        _ item: ContractCase,
        _ pin: PinContract,
        field: String
    ) -> String {
        "\(field):\(item.requestedType):\(pin.direction):\(pin.ordinal):\(pin.connectorName)"
    }

    private static func topologyName(_ topology: ScriptGraphAuthoringRecipe.Topology) -> String {
        switch topology {
        case .pure: "pure"
        case .event: "event"
        case .action: "action"
        case .scoped: "scoped"
        }
    }

    private static func settingsKind(_ node: RCP3ScriptGraph.Node) -> String {
        if node.enumSelection != nil { return "enum" }
        if node.dynamicConnectorSettings != nil { return "dynamic-connectors" }
        if node.materialSettings != nil { return "material-schema" }
        if node.entityParameterSettings != nil { return "entity-parameter" }
        if node.variableName != nil { return "graph-variable" }
        return "none"
    }

    private static func typeDescription(
        _ type: ScriptGraphNodeLibrary.PinTypeConstraint
    ) -> String {
        switch type {
        case .unknown: "unknown"
        case .any: "any"
        case let .concrete(token, hash): "concrete:\(token):\(hash.map(TMHash.hex) ?? "none")"
        case let .sameAs(name): "same-as:\(name)"
        case let .arrayElement(name): "array-element:\(name)"
        case let .array(name): "array:\(name)"
        }
    }

    private static func presenceName(_ presence: ScriptGraphNodeLibrary.PinPresence) -> String {
        switch presence {
        case .unknown: "unknown"
        case .required: "required"
        case .optional: "optional"
        case .registrationDefault: "registration-default"
        case .implicitSelf: "implicit-self"
        }
    }

    private static func settingsDescription(_ node: RCP3ScriptGraph.Node) -> String {
        var fields = ["type=\(node.type)", "variable=\(node.variableName ?? "")"]
        if let value = node.enumSelection {
            fields.append("enum=\(value.typeHash):\(value.caseName):\(value.associatedValues.map { "\($0.index):\($0.typeHash)" }.joined(separator: ","))")
        }
        if let value = node.dynamicConnectorSettings {
            let container = switch value.container {
            case .direct: "direct"
            case let .array(array, element): "array:\(array.map(String.init) ?? ""):\(element.map(String.init) ?? "")"
            }
            fields.append("dynamic=\(container):\(connectors(value.inputs)):\(connectors(value.outputs))")
        }
        if let value = node.materialSettings {
            func properties(_ values: [RCP3ScriptGraph.Node.MaterialSettings.Property]) -> String {
                values.map { "\($0.name):\($0.typeHash):\($0.editTypeHash):\($0.isOptional)" }.joined(separator: ",")
            }
            fields.append("material=\(value.typeHash):\(value.objectIdentifier):\(properties(value.inputs)):\(properties(value.outputs))")
        }
        if let value = node.entityParameterSettings {
            fields.append("entity-parameter=\(value.typeHash)")
        }
        return fields.joined(separator: "|")
    }

    private static func connectors(
        _ values: [RCP3ScriptGraph.Node.DynamicConnector]
    ) -> String {
        values.map {
            "\($0.name):\($0.displayName ?? ""):\($0.typeHash):\($0.editHash):\($0.order):\($0.optionality)"
        }.joined(separator: ",")
    }

    private static func graphFingerprint(_ graph: RCP3ScriptGraph) -> String {
        let nodes = graph.nodes.sorted { $0.id < $1.id }.map {
            "node:\($0.id):\($0.type):\($0.label ?? ""):\(settingsDescription($0))"
        }
        let wires = graph.wires.sorted { $0.id < $1.id }.map {
            "wire:\($0.id):\($0.from):\($0.to):\($0.fromPin.map(String.init) ?? ""):\($0.toPin.map(String.init) ?? "")"
        }
        let data = graph.data.sorted { $0.id < $1.id }.map {
            "data:\($0.id):\($0.toNode):\($0.toPin):\($0.valueType ?? ""):\($0.valueHash.map(String.init) ?? ""):\(valueDescription($0.value))"
        }
        let variables = graph.variables.sorted { $0.uuid < $1.uuid }.map {
            "variable:\($0.uuid):\($0.name):\($0.typeHash.map(String.init) ?? ""):\($0.editHash.map(String.init) ?? ""):\($0.dataType ?? "")"
        }
        return (["graph:\(graph.id ?? "")"] + nodes + wires + data + variables).joined(separator: "\n")
    }

    private static func valueDescription(_ value: TMGraphValue?) -> String {
        switch value {
        case nil: "none"
        case let .number(number): "number:\(number)"
        case let .bool(bool): "bool:\(bool)"
        case let .string(string): "string:\(string)"
        case let .variableRef(name, ref): "variable:\(name):\(ref ?? "")"
        }
    }

    private static func digest(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
