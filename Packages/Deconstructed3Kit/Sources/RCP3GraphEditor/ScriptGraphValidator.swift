import Foundation
import RCP3Document
import TMFormat

/// A pure, coverage-aware validation pass for an authored Script Graph.
///
/// The validator deliberately separates structural/settings errors from coverage.
/// A graph can be structurally valid while still containing a node whose declared
/// interface is unknown. Callers that need a proof, rather than a best-effort check,
/// should require ``ScriptGraphValidationReport/isFullyValidated``.
public enum ScriptGraphValidator {
    public static func validate(
        _ graph: RCP3ScriptGraph,
        registry: ScriptGraphNodeRegistry = .builtins
    ) -> ScriptGraphValidationReport {
        var issues: [ScriptGraphValidationIssue] = []
        var coverage: [ScriptGraphValidationCoverage] = []

        appendDuplicateIssues(
            graph.nodes.map(\.id), code: .duplicateNodeID, noun: "node", to: &issues
        )
        appendDuplicateIssues(
            graph.wires.map(\.id), code: .duplicateWireID, noun: "wire", to: &issues
        )
        appendDuplicateIssues(
            graph.variables.map(\.uuid), code: .duplicateVariableID, noun: "variable", to: &issues
        )
        appendDuplicateVariableNameIssues(graph.variables, to: &issues)

        let nodeIDs = Set(graph.nodes.map(\.id))
        for wire in graph.wires {
            if !nodeIDs.contains(wire.from) {
                issues.append(.error(
                    .missingWireSource, subject: wire.id,
                    "Wire \(wire.id) references missing source node \(wire.from)."
                ))
            }
            if !nodeIDs.contains(wire.to) {
                issues.append(.error(
                    .missingWireTarget, subject: wire.id,
                    "Wire \(wire.id) references missing target node \(wire.to)."
                ))
            }
            if (wire.fromPin == nil) != (wire.toPin == nil),
               !isValidPartiallyNamedExecWire(wire, in: graph, registry: registry) {
                issues.append(.error(
                    .incompleteWirePins, subject: wire.id,
                    "Wire \(wire.id) has only one connector hash and it is not a declared named execution pin."
                ))
            }
        }

        validateEndpointsAndContracts(
            in: graph,
            registry: registry,
            issues: &issues,
            coverage: &coverage
        )

        for literal in graph.data where !nodeIDs.contains(literal.toNode) {
            issues.append(.error(
                .missingLiteralTarget, subject: literal.id,
                "Literal \(literal.id) references missing node \(literal.toNode)."
            ))
        }

        validateVariables(in: graph, issues: &issues, coverage: &coverage)

        for node in graph.nodes {
            let settingsAreValid = validateSettings(of: node, issues: &issues)
            let status: ScriptGraphValidationCoverage.Status
            if !settingsAreValid {
                status = .unknown(reason: "The node settings are invalid or incomplete.")
            } else if exactSpec(for: node, in: graph, registry: registry) != nil {
                status = .exact
            } else {
                let reason = "No declared interface is available for node type \(node.type)."
                status = .unknown(reason: reason)
                issues.append(.warning(
                    .unknownNodeInterface, subject: node.id,
                    "Node \(node.id) (\(node.type)) was not interface-validated: \(reason)"
                ))
            }
            coverage.append(.init(
                subject: .node(id: node.id, type: node.type),
                status: status
            ))
        }

        return ScriptGraphValidationReport(
            issues: issues.sorted(by: issueOrder),
            coverage: coverage.sorted(by: coverageOrder)
        )
    }

    // MARK: - Endpoints and pin contracts

    private enum WireValueKind { case exec, data }

    private static func validateEndpointsAndContracts(
        in graph: RCP3ScriptGraph,
        registry: ScriptGraphNodeRegistry,
        issues: inout [ScriptGraphValidationIssue],
        coverage: inout [ScriptGraphValidationCoverage]
    ) {
        let nodes = graph.nodes.reduce(into: [String: RCP3ScriptGraph.Node]()) {
            if $0[$1.id] == nil { $0[$1.id] = $1 }
        }
        let specs = graph.nodes.reduce(
            into: [String: ScriptGraphNodeLibrary.NodeSpec]()
        ) { result, node in
            if result[node.id] == nil {
                result[node.id] = exactSpec(for: node, in: graph, registry: registry)
            }
        }

        for node in graph.nodes {
            guard let spec = specs[node.id] else { continue }
            for (direction, pins) in [("input", spec.inputs), ("output", spec.outputs)] {
                for pin in pins {
                    let status: ScriptGraphValidationCoverage.Status
                    if pin.isExec {
                        status = .exact
                    } else {
                        let typeKnown: Bool = switch pin.typeConstraint {
                        case .unknown, .sameAs, .arrayElement, .array: false
                        case .any, .concrete: true
                        }
                        let presenceKnown = direction == "output" || pin.presence != .unknown
                        if typeKnown && presenceKnown {
                            status = .exact
                        } else {
                            let missing = [
                                typeKnown ? nil : "type",
                                presenceKnown ? nil : "presence",
                            ].compactMap { $0 }.joined(separator: " and ")
                            status = .unknown(reason: "No source-backed \(missing) contract.")
                        }
                    }
                    coverage.append(.init(
                        subject: .pin(
                            nodeID: node.id,
                            nodeType: node.type,
                            direction: direction,
                            connectorName: pin.connectorName
                        ),
                        status: status
                    ))
                }
            }
        }

        for wire in graph.wires {
            guard let source = nodes[wire.from], let target = nodes[wire.to],
                  let sourceSpec = specs[source.id], let targetSpec = specs[target.id]
            else { continue }

            let sourcePin = endpointPin(hash: wire.fromPin, among: sourceSpec.outputs)
            let targetPin = endpointPin(hash: wire.toPin, among: targetSpec.inputs)
            if sourcePin == nil {
                let reversed = endpointPin(hash: wire.fromPin, among: sourceSpec.inputs) != nil
                issues.append(.error(
                    reversed ? .reversedWireEndpoint : .unknownWireSourcePin,
                    subject: wire.id,
                    "Wire \(wire.id) source connector is not a declared output of \(source.id)."
                ))
            }
            if targetPin == nil {
                let reversed = endpointPin(hash: wire.toPin, among: targetSpec.outputs) != nil
                issues.append(.error(
                    reversed ? .reversedWireEndpoint : .unknownWireTargetPin,
                    subject: wire.id,
                    "Wire \(wire.id) target connector is not a declared input of \(target.id)."
                ))
            }
            guard let sourcePin, let targetPin else { continue }
            let sourceKind: WireValueKind = sourcePin.isExec ? .exec : .data
            let targetKind: WireValueKind = targetPin.isExec ? .exec : .data
            guard sourceKind == targetKind else {
                issues.append(.error(
                    .mixedWireKinds, subject: wire.id,
                    "Wire \(wire.id) connects an execution pin to a data pin."
                ))
                continue
            }
            if sourceKind == .data,
               constraintsConflict(sourcePin.typeConstraint, targetPin.typeConstraint) {
                issues.append(.error(
                    .incompatibleWireTypes, subject: wire.id,
                    "Wire \(wire.id) connects incompatible data-pin types."
                ))
            }
        }

        for literal in graph.data {
            guard let node = nodes[literal.toNode], let spec = specs[node.id] else { continue }
            guard let pin = spec.inputs.first(where: {
                !$0.isExec && $0.connectorHash == literal.toPin
            }) else {
                let reversed = spec.outputs.contains {
                    !$0.isExec && $0.connectorHash == literal.toPin
                }
                issues.append(.error(
                    reversed ? .reversedLiteralEndpoint : .unknownLiteralTargetPin,
                    subject: literal.id,
                    "Literal \(literal.id) does not target a declared data input of \(node.id)."
                ))
                continue
            }
            if let literalType = literalTypeConstraint(literal),
               constraintsConflict(literalType, pin.typeConstraint) {
                issues.append(.error(
                    .incompatibleLiteralType, subject: literal.id,
                    "Literal \(literal.id) is incompatible with its target pin type."
                ))
            }
        }

        for node in graph.nodes {
            guard let spec = specs[node.id] else { continue }
            for pin in spec.inputs where !pin.isExec && pin.presence == .required {
                let satisfiedByWire = graph.wires.contains {
                    $0.to == node.id && $0.toPin == pin.connectorHash
                }
                let satisfiedByLiteral = graph.data.contains {
                    $0.toNode == node.id && $0.toPin == pin.connectorHash
                }
                guard !satisfiedByWire && !satisfiedByLiteral else { continue }
                issues.append(.warning(
                    .missingRequiredInput,
                    subject: node.id,
                    "Node \(node.id) has no value for required input \(pin.displayName)."
                ))
            }
        }
    }

    private static func endpointPin(
        hash: UInt64?,
        among pins: [ScriptGraphNodeLibrary.PinSpec]
    ) -> ScriptGraphNodeLibrary.PinSpec? {
        if let hash {
            return pins.first { $0.connectorHash == hash }
        }
        let execPins = pins.filter(\.isExec)
        return execPins.first(where: { $0.connectorName.isEmpty })
            ?? (execPins.count == 1 ? execPins.first : nil)
    }

    private static func constraintsConflict(
        _ lhs: ScriptGraphNodeLibrary.PinTypeConstraint,
        _ rhs: ScriptGraphNodeLibrary.PinTypeConstraint
    ) -> Bool {
        switch (lhs, rhs) {
        case (.unknown, _), (_, .unknown), (.any, _), (_, .any):
            return false
        case let (.concrete(leftToken, leftHash), .concrete(rightToken, rightHash)):
            if let leftHash, let rightHash { return leftHash != rightHash }
            return leftToken != rightToken
        default:
            // Relational constraints are checked once both sides resolve to a
            // concrete instance type; an unresolved relation remains coverage,
            // never a guessed incompatibility.
            return false
        }
    }

    private static func literalTypeConstraint(
        _ literal: RCP3ScriptGraph.DataLiteral
    ) -> ScriptGraphNodeLibrary.PinTypeConstraint? {
        if let value = literal.value {
            switch value {
            case .number:
                return .concrete(token: "Number", typeHash: ScriptGraphTypeRegistry.number.typeHash)
            case .bool:
                return .concrete(token: "Bool", typeHash: ScriptGraphTypeRegistry.bool.typeHash)
            case .string:
                return .concrete(token: "String", typeHash: ScriptGraphTypeRegistry.string.typeHash)
            case .variableRef:
                break
            }
        }
        return switch literal.valueType {
        case "tm_double", "tm_float": .concrete(token: "Number", typeHash: ScriptGraphTypeRegistry.number.typeHash)
        case "tm_bool": .concrete(token: "Bool", typeHash: ScriptGraphTypeRegistry.bool.typeHash)
        case "tm_string": .concrete(token: "String", typeHash: ScriptGraphTypeRegistry.string.typeHash)
        default: nil
        }
    }

    // MARK: - Structure and variables

    private static func appendDuplicateIssues(
        _ identifiers: [String],
        code: ScriptGraphValidationIssue.Code,
        noun: String,
        to issues: inout [ScriptGraphValidationIssue]
    ) {
        for (identifier, count) in Dictionary(grouping: identifiers, by: { $0 })
            .mapValues(\.count)
            .filter({ $0.value > 1 })
            .sorted(by: { $0.key < $1.key }) {
            issues.append(.error(
                code, subject: identifier,
                "Duplicate \(noun) id \(identifier) appears \(count) times."
            ))
        }
    }

    /// RCP3 omits the hash for an unnamed execution endpoint while preserving the
    /// opposite named execution hash (for example Delay.Once → an action input).
    private static func isValidPartiallyNamedExecWire(
        _ wire: RCP3ScriptGraph.Wire,
        in graph: RCP3ScriptGraph,
        registry: ScriptGraphNodeRegistry
    ) -> Bool {
        guard
            let source = graph.nodes.first(where: { $0.id == wire.from }),
            let target = graph.nodes.first(where: { $0.id == wire.to }),
            let sourceSpec = exactSpec(for: source, in: graph, registry: registry),
            let targetSpec = exactSpec(for: target, in: graph, registry: registry)
        else { return false }

        let sourceIsExec = if let hash = wire.fromPin {
            sourceSpec.outputs.contains { $0.isExec && !$0.connectorName.isEmpty && $0.connectorHash == hash }
        } else {
            sourceSpec.outputs.contains { $0.isExec && $0.connectorName.isEmpty }
        }
        let targetIsExec = if let hash = wire.toPin {
            targetSpec.inputs.contains { $0.isExec && !$0.connectorName.isEmpty && $0.connectorHash == hash }
        } else {
            targetSpec.inputs.contains { $0.isExec && $0.connectorName.isEmpty }
        }
        return sourceIsExec && targetIsExec
    }

    private static func appendDuplicateVariableNameIssues(
        _ variables: [RCP3ScriptGraph.Variable],
        to issues: inout [ScriptGraphValidationIssue]
    ) {
        let grouped = Dictionary(grouping: variables) { $0.name.lowercased() }
        for (_, matches) in grouped.filter({ $0.value.count > 1 })
            .sorted(by: { $0.key < $1.key }) {
            let names = matches.map(\.name).sorted().joined(separator: ", ")
            issues.append(.error(
                .duplicateVariableName, subject: matches.map(\.name).sorted().first ?? "",
                "Variable names must be unique case-insensitively; found: \(names)."
            ))
        }
    }

    private static func validateVariables(
        in graph: RCP3ScriptGraph,
        issues: inout [ScriptGraphValidationIssue],
        coverage: inout [ScriptGraphValidationCoverage]
    ) {
        let variablesByID = Dictionary(grouping: graph.variables, by: \.uuid)
        let variablesByName = Dictionary(grouping: graph.variables) { $0.name.lowercased() }

        for variable in graph.variables {
            let fields: [Any?] = [variable.typeHash, variable.editHash, variable.dataType]
            let presentCount = fields.reduce(0) { $0 + ($1 == nil ? 0 : 1) }
            let status: ScriptGraphValidationCoverage.Status
            if presentCount == 0 {
                status = .unknown(reason: "The variable has no declared runtime/edit/default type.")
            } else if presentCount != fields.count
                        || variable.typeHash == 0
                        || variable.editHash == 0
                        || variable.dataType?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                issues.append(.error(
                    .incompleteVariableType, subject: variable.uuid,
                    "Variable \(variable.name) must declare a nonzero runtime hash, edit hash, and data type together."
                ))
                status = .unknown(reason: "The variable type declaration is incomplete.")
            } else {
                status = .exact
            }
            coverage.append(.init(
                subject: .variable(id: variable.uuid, name: variable.name),
                status: status
            ))
        }

        for node in graph.nodes where node.variableName != nil || node.variableRefUUID != nil {
            switch (node.variableName, node.variableRefUUID) {
            case let (name?, ref?):
                guard let matches = variablesByID[ref], let variable = matches.first else {
                    issues.append(.error(
                        .danglingVariableReference, subject: node.id,
                        "Node \(node.id) references missing variable id \(ref)."
                    ))
                    continue
                }
                if matches.count == 1, variable.name != name {
                    issues.append(.error(
                        .mismatchedVariableReference, subject: node.id,
                        "Node \(node.id) names variable \(name), but \(ref) is \(variable.name)."
                    ))
                }
            case let (name?, nil):
                if variablesByName[name.lowercased()] == nil {
                    issues.append(.error(
                        .danglingVariableReference, subject: node.id,
                        "Node \(node.id) references missing variable name \(name)."
                    ))
                } else {
                    issues.append(.error(
                        .incompleteVariableReference, subject: node.id,
                        "Node \(node.id) names variable \(name) but has no variable id."
                    ))
                }
            case let (nil, ref?):
                let detail = variablesByID[ref]?.first?.name ?? ref
                issues.append(.error(
                    variablesByID[ref] == nil ? .danglingVariableReference : .incompleteVariableReference,
                    subject: node.id,
                    "Node \(node.id) references variable \(detail) but has no variable name."
                ))
            case (nil, nil):
                break
            }
        }
    }

    // MARK: - Settings

    private static func validateSettings(
        of node: RCP3ScriptGraph.Node,
        issues: inout [ScriptGraphValidationIssue]
    ) -> Bool {
        var valid = true
        let settingCount = [
            node.enumSelection != nil,
            node.dynamicConnectorSettings != nil,
            node.materialSettings != nil,
            node.entityParameterSettings != nil,
        ].filter { $0 }.count
        if settingCount > 1 {
            issues.append(.error(
                .conflictingSettings, subject: node.id,
                "Node \(node.id) carries more than one settings schema."
            ))
            valid = false
        }

        valid = validateEnumSettings(of: node, issues: &issues) && valid
        valid = validateDynamicSettings(of: node, issues: &issues) && valid
        valid = validateMaterialSettings(of: node, issues: &issues) && valid
        valid = validateEntityParameterSettings(of: node, issues: &issues) && valid
        return valid
    }

    private static func validateEnumSettings(
        of node: RCP3ScriptGraph.Node,
        issues: inout [ScriptGraphValidationIssue]
    ) -> Bool {
        let policy = ScriptGraphNodeLibrary.enumPinPolicy(for: node.type)
        guard let policy else {
            guard node.enumSelection != nil else { return true }
            issues.append(.error(
                .unexpectedEnumSettings, subject: node.id,
                "Node type \(node.type) does not support enum settings."
            ))
            return false
        }
        guard let selection = node.enumSelection else {
            issues.append(.error(
                .missingEnumSettings, subject: node.id,
                "Enum node \(node.id) has no selected case."
            ))
            return false
        }
        guard let selected = policy.schema.cases.first(where: { $0.name == selection.caseName }) else {
            issues.append(.error(
                .invalidEnumSettings, subject: node.id,
                "Enum node \(node.id) selects unknown case \(selection.caseName)."
            ))
            return false
        }
        let expectedTypeHash = TMHash.murmur64a(policy.schema.typeName)
        let expectedAssociated = selected.associatedValues.enumerated().map { index, value in
            RCP3ScriptGraph.Node.EnumSelection.AssociatedValue(
                index: UInt32(index), typeHash: TMHash.murmur64a(value.swiftType)
            )
        }
        guard selection.typeHash == expectedTypeHash,
              selection.associatedValues == expectedAssociated else {
            issues.append(.error(
                .invalidEnumSettings, subject: node.id,
                "Enum node \(node.id) has a type hash or associated-value schema inconsistent with \(selection.caseName)."
            ))
            return false
        }
        return true
    }

    private static func validateDynamicSettings(
        of node: RCP3ScriptGraph.Node,
        issues: inout [ScriptGraphValidationIssue]
    ) -> Bool {
        // Entity Parameter registrations expose a dynamic value connector at
        // runtime, but serialize their selection in the dedicated settings record.
        // Treating that record as generic dynamic settings would validate the
        // wrong on-disk shape.
        if entityParameterNodeTypes.contains(node.type) {
            guard node.dynamicConnectorSettings == nil else {
                issues.append(.error(
                    .unexpectedDynamicSettings, subject: node.id,
                    "Entity-parameter node \(node.id) must use its dedicated settings schema."
                ))
                return false
            }
            return true
        }
        let policy = ScriptGraphNodeLibrary.dynamicPinPolicy(for: node.type)
        guard let policy else {
            guard node.dynamicConnectorSettings != nil else { return true }
            issues.append(.error(
                .unexpectedDynamicSettings, subject: node.id,
                "Node type \(node.type) does not support dynamic connector settings."
            ))
            return false
        }
        guard let settings = node.dynamicConnectorSettings else {
            issues.append(.error(
                .missingDynamicSettings, subject: node.id,
                "Dynamic node \(node.id) has no connector settings."
            ))
            return false
        }

        var valid = true
        let fixedDataInputCount = policy.fixedInputs.filter { !$0.isExec }.count
        let totalInputCount = fixedDataInputCount + settings.inputs.count
        if totalInputCount < policy.minimumInputCount
            || policy.maximumInputCount.map({ totalInputCount > $0 }) == true {
            issues.append(.error(
                .invalidDynamicSettings, subject: node.id,
                "Dynamic node \(node.id) exposes \(totalInputCount) data inputs outside its supported limits."
            ))
            valid = false
        }

        let expectsArrayContainer = node.type == "tm_array_create"
        switch settings.container {
        case .direct where expectsArrayContainer,
             .array where !expectsArrayContainer:
            issues.append(.error(
                .invalidDynamicSettings, subject: node.id,
                "Dynamic node \(node.id) uses the wrong settings container."
            ))
            valid = false
        case let .array(arrayType, elementType):
            if arrayType == nil || arrayType == 0 || elementType == nil || elementType == 0 {
                issues.append(.error(
                    .invalidDynamicSettings, subject: node.id,
                    "Array node \(node.id) must declare nonzero array and element type hashes."
                ))
                valid = false
            }
            if let arrayType, let elementType {
                if settings.inputs.contains(where: { $0.typeHash != elementType })
                    || settings.outputs.contains(where: { $0.typeHash != arrayType }) {
                    issues.append(.error(
                        .invalidDynamicSettings, subject: node.id,
                        "Array node \(node.id) connector types do not match its container types."
                    ))
                    valid = false
                }
            }
        case .direct:
            break
        }

        valid = validateConnectors(settings.inputs, direction: "input", node: node, issues: &issues) && valid
        valid = validateConnectors(settings.outputs, direction: "output", node: node, issues: &issues) && valid
        if !policy.acceptsMixedInputTypes,
           Set(settings.inputs.map(\.typeHash)).count > 1 {
            issues.append(.error(
                .invalidDynamicSettings, subject: node.id,
                "Dynamic node \(node.id) requires a single input type."
            ))
            valid = false
        }
        return valid
    }

    private static func validateConnectors(
        _ connectors: [RCP3ScriptGraph.Node.DynamicConnector],
        direction: String,
        node: RCP3ScriptGraph.Node,
        issues: inout [ScriptGraphValidationIssue]
    ) -> Bool {
        let normalizedNames = connectors.map {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let orders = connectors.map(\.order)
        let invalid = normalizedNames.contains(where: \.isEmpty)
            || Set(normalizedNames).count != normalizedNames.count
            || connectors.contains(where: { $0.typeHash == 0 || !$0.order.isFinite || $0.optionality > 1 })
            || Set(orders).count != orders.count
        guard invalid else { return true }
        issues.append(.error(
            .invalidDynamicSettings, subject: node.id,
            "Dynamic node \(node.id) has invalid or duplicate \(direction) connectors."
        ))
        return false
    }

    private static let materialNodeTypes: Set<String> = [
        "tm_get_material_parameter", "tm_set_material_parameter_v2", "tm_modify_any_material",
    ]

    private static func validateMaterialSettings(
        of node: RCP3ScriptGraph.Node,
        issues: inout [ScriptGraphValidationIssue]
    ) -> Bool {
        let supports = materialNodeTypes.contains(node.type)
        guard supports else {
            guard node.materialSettings != nil else { return true }
            issues.append(.error(
                .unexpectedMaterialSettings, subject: node.id,
                "Node type \(node.type) does not support material settings."
            ))
            return false
        }
        guard let settings = node.materialSettings else {
            issues.append(.error(
                .missingMaterialSettings, subject: node.id,
                "Material node \(node.id) has no Inspectable schema settings."
            ))
            return false
        }
        let invalid = settings.typeHash == 0
            || settings.objectIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || settings.inputs.isEmpty
            || settings.outputs.isEmpty
            || !validMaterialProperties(settings.inputs)
            || !validMaterialProperties(settings.outputs)
        guard !invalid else {
            issues.append(.error(
                .invalidMaterialSettings, subject: node.id,
                "Material node \(node.id) has an incomplete or inconsistent property schema."
            ))
            return false
        }
        return true
    }

    private static func validMaterialProperties(
        _ properties: [RCP3ScriptGraph.Node.MaterialSettings.Property]
    ) -> Bool {
        let names = properties.map {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return !names.contains(where: \.isEmpty)
            && Set(names).count == names.count
            && properties.allSatisfy { $0.typeHash != 0 && $0.editTypeHash != 0 }
    }

    private static let entityParameterNodeTypes: Set<String> = [
        "tm_get_entity_parameter", "tm_set_entity_parameter",
    ]

    private static func validateEntityParameterSettings(
        of node: RCP3ScriptGraph.Node,
        issues: inout [ScriptGraphValidationIssue]
    ) -> Bool {
        let supports = entityParameterNodeTypes.contains(node.type)
        guard supports else {
            guard node.entityParameterSettings != nil else { return true }
            issues.append(.error(
                .unexpectedEntityParameterSettings, subject: node.id,
                "Node type \(node.type) does not support entity-parameter settings."
            ))
            return false
        }
        guard let settings = node.entityParameterSettings else {
            issues.append(.error(
                .missingEntityParameterSettings, subject: node.id,
                "Entity-parameter node \(node.id) has no selected value type."
            ))
            return false
        }
        guard settings.typeHash != 0 else {
            issues.append(.error(
                .invalidEntityParameterSettings, subject: node.id,
                "Entity-parameter node \(node.id) has a zero value-type hash."
            ))
            return false
        }
        return true
    }

    private static func exactSpec(
        for node: RCP3ScriptGraph.Node,
        in graph: RCP3ScriptGraph,
        registry: ScriptGraphNodeRegistry
    ) -> ScriptGraphNodeLibrary.NodeSpec? {
        ScriptGraphPinResolver.resolvedContract(for: node, in: graph, registry: registry)
    }

    private static func issueOrder(
        _ lhs: ScriptGraphValidationIssue,
        _ rhs: ScriptGraphValidationIssue
    ) -> Bool {
        (lhs.code.rawValue, lhs.subject, lhs.message) < (rhs.code.rawValue, rhs.subject, rhs.message)
    }

    private static func coverageOrder(
        _ lhs: ScriptGraphValidationCoverage,
        _ rhs: ScriptGraphValidationCoverage
    ) -> Bool {
        lhs.subject.sortKey < rhs.subject.sortKey
    }
}

public struct ScriptGraphValidationReport: Codable, Sendable, Equatable {
    public let issues: [ScriptGraphValidationIssue]
    public let coverage: [ScriptGraphValidationCoverage]

    public init(
        issues: [ScriptGraphValidationIssue],
        coverage: [ScriptGraphValidationCoverage]
    ) {
        self.issues = issues
        self.coverage = coverage
    }

    public var errors: [ScriptGraphValidationIssue] { issues.filter { $0.severity == .error } }
    public var warnings: [ScriptGraphValidationIssue] { issues.filter { $0.severity == .warning } }
    public var staticReadinessIssues: [ScriptGraphValidationIssue] {
        issues.filter { $0.code == .missingRequiredInput }
    }
    public var isStructurallyValid: Bool { errors.isEmpty }
    public var hasCompleteCoverage: Bool { coverage.allSatisfy { $0.status == .exact } }
    public var isFullyValidated: Bool { isStructurallyValid && hasCompleteCoverage }
    /// Static authoring readiness only. External execution in RCP3 is a separate
    /// certification tier and is never implied by this value.
    public var isStaticallyReady: Bool {
        isFullyValidated && staticReadinessIssues.isEmpty
    }
}

public struct ScriptGraphValidationIssue: Codable, Sendable, Equatable, Identifiable {
    public enum Severity: String, Codable, Sendable, Equatable { case error, warning }

    public enum Code: String, Codable, Sendable, Equatable {
        case duplicateNodeID
        case duplicateWireID
        case duplicateVariableID
        case duplicateVariableName
        case missingWireSource
        case missingWireTarget
        case incompleteWirePins
        case unknownWireSourcePin
        case unknownWireTargetPin
        case reversedWireEndpoint
        case mixedWireKinds
        case incompatibleWireTypes
        case missingLiteralTarget
        case unknownLiteralTargetPin
        case reversedLiteralEndpoint
        case incompatibleLiteralType
        case missingRequiredInput
        case danglingVariableReference
        case incompleteVariableReference
        case mismatchedVariableReference
        case incompleteVariableType
        case conflictingSettings
        case missingEnumSettings
        case unexpectedEnumSettings
        case invalidEnumSettings
        case missingDynamicSettings
        case unexpectedDynamicSettings
        case invalidDynamicSettings
        case missingMaterialSettings
        case unexpectedMaterialSettings
        case invalidMaterialSettings
        case missingEntityParameterSettings
        case unexpectedEntityParameterSettings
        case invalidEntityParameterSettings
        case unknownNodeInterface
    }

    public let severity: Severity
    public let code: Code
    public let subject: String
    public let message: String

    public var id: String { "\(severity.rawValue):\(code.rawValue):\(subject):\(message)" }

    public init(severity: Severity, code: Code, subject: String, message: String) {
        self.severity = severity
        self.code = code
        self.subject = subject
        self.message = message
    }

    fileprivate static func error(_ code: Code, subject: String, _ message: String) -> Self {
        .init(severity: .error, code: code, subject: subject, message: message)
    }

    fileprivate static func warning(_ code: Code, subject: String, _ message: String) -> Self {
        .init(severity: .warning, code: code, subject: subject, message: message)
    }
}

public struct ScriptGraphValidationCoverage: Codable, Sendable, Equatable {
    public enum Subject: Codable, Sendable, Equatable {
        case node(id: String, type: String)
        case variable(id: String, name: String)
        case pin(
            nodeID: String,
            nodeType: String,
            direction: String,
            connectorName: String
        )

        fileprivate var sortKey: String {
            switch self {
            case let .node(id, type): "node:\(id):\(type)"
            case let .variable(id, name): "variable:\(id):\(name)"
            case let .pin(nodeID, nodeType, direction, connectorName):
                "pin:\(nodeID):\(nodeType):\(direction):\(connectorName)"
            }
        }
    }

    public enum Status: Codable, Sendable, Equatable {
        case exact
        case unknown(reason: String)
    }

    public let subject: Subject
    public let status: Status

    public init(subject: Subject, status: Status) {
        self.subject = subject
        self.status = status
    }
}
