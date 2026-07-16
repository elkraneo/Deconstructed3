import RCP3Document
import TMFormat

/// Resolves graph-instance polymorphism without inventing missing type facts.
///
/// Static concrete contracts and typed literals seed the pass. Data wires can
/// carry a concrete identity onto an otherwise relational pin, while `sameAs`,
/// `arrayElement`, and `array` relations propagate that identity within a node.
/// Relations remain unchanged when no concrete evidence reaches them.
enum ScriptGraphRelationalTypeResolver {
    typealias Constraint = ScriptGraphNodeLibrary.PinTypeConstraint
    typealias Spec = ScriptGraphNodeLibrary.NodeSpec

    private struct PinKey: Hashable, Comparable {
        enum Direction: Int, Comparable {
            case input
            case output

            static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
        }

        let nodeID: String
        let direction: Direction
        let connectorName: String

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.nodeID, lhs.direction, lhs.connectorName)
                < (rhs.nodeID, rhs.direction, rhs.connectorName)
        }
    }

    private struct Relation {
        enum Kind { case equal, elementOfArray, arrayOfElement }
        let subject: PinKey
        let reference: PinKey
        let kind: Kind
    }

    static func resolve(
        _ contracts: [String: Spec],
        in graph: RCP3ScriptGraph
    ) -> [String: Spec] {
        var declared: [PinKey: Constraint] = [:]
        var pinsByNodeAndName: [String: [String: [PinKey]]] = [:]

        for nodeID in contracts.keys.sorted() {
            guard let spec = contracts[nodeID] else { continue }
            for (direction, pins) in [
                (PinKey.Direction.input, spec.inputs),
                (.output, spec.outputs),
            ] {
                for pin in pins where !pin.isExec {
                    let key = PinKey(
                        nodeID: nodeID,
                        direction: direction,
                        connectorName: pin.connectorName
                    )
                    declared[key] = pin.typeConstraint
                    pinsByNodeAndName[nodeID, default: [:]][pin.connectorName, default: []]
                        .append(key)
                }
            }
        }

        var assignments: [PinKey: Constraint] = declared.compactMapValues {
            if case .concrete = $0 { return $0 }
            return nil
        }

        // A literal is direct evidence about its target input.
        for literal in graph.data.sorted(by: { $0.id < $1.id }) {
            let key = inputKey(
                nodeID: literal.toNode,
                connectorHash: literal.toPin,
                contracts: contracts
            )
            guard let key, assignments[key] == nil,
                  let concrete = literalConstraint(literal)
            else { continue }
            assignments[key] = concrete
        }

        let relations = declared.keys.sorted().flatMap { key -> [Relation] in
            guard let constraint = declared[key] else { return [] }
            let referenceName: String
            let kind: Relation.Kind
            switch constraint {
            case let .sameAs(name):
                referenceName = name
                kind = .equal
            case let .arrayElement(name):
                referenceName = name
                kind = .elementOfArray
            case let .array(name):
                referenceName = name
                kind = .arrayOfElement
            default:
                return []
            }
            return (pinsByNodeAndName[key.nodeID]?[referenceName] ?? [])
                .filter { $0 != key }
                .sorted()
                .map { Relation(subject: key, reference: $0, kind: kind) }
        }

        let wires = graph.wires.sorted { $0.id < $1.id }.compactMap { wire -> (PinKey, PinKey)? in
            guard let fromHash = wire.fromPin, let toHash = wire.toPin,
                  let source = outputKey(
                    nodeID: wire.from, connectorHash: fromHash, contracts: contracts
                  ),
                  let target = inputKey(
                    nodeID: wire.to, connectorHash: toHash, contracts: contracts
                  )
            else { return nil }
            return (source, target)
        }

        // Each successful iteration adds or refines at least one assignment. The
        // small bound is defensive; normal graphs converge in a handful of passes.
        let maximumPasses = max(1, declared.count * 2)
        for _ in 0..<maximumPasses {
            var changed = false

            for (source, target) in wires {
                if assignments[target] == nil, let concrete = assignments[source] {
                    assignments[target] = concrete
                    changed = true
                }
                if assignments[source] == nil, let concrete = assignments[target] {
                    assignments[source] = concrete
                    changed = true
                }
            }

            for relation in relations {
                let subject = assignments[relation.subject]
                let reference = assignments[relation.reference]
                switch relation.kind {
                case .equal:
                    // The referenced connector is authoritative when both sides
                    // have conflicting wire-derived candidates.
                    if let reference, subject != reference,
                       canInfer(declared[relation.subject]) {
                        assignments[relation.subject] = reference
                        changed = true
                    } else if reference == nil, let subject,
                              canInfer(declared[relation.reference]) {
                        assignments[relation.reference] = subject
                        changed = true
                    }
                case .elementOfArray:
                    if let reference, let element = elementConstraint(of: reference),
                       subject != element, canInfer(declared[relation.subject]) {
                        assignments[relation.subject] = element
                        changed = true
                    } else if reference == nil, let subject,
                              let array = arrayConstraint(of: subject),
                              canInfer(declared[relation.reference]) {
                        assignments[relation.reference] = array
                        changed = true
                    }
                case .arrayOfElement:
                    if let reference, let array = arrayConstraint(of: reference),
                       subject != array, canInfer(declared[relation.subject]) {
                        assignments[relation.subject] = array
                        changed = true
                    } else if reference == nil, let subject,
                              let element = elementConstraint(of: subject),
                              canInfer(declared[relation.reference]) {
                        assignments[relation.reference] = element
                        changed = true
                    }
                }
            }
            if !changed { break }
        }

        return contracts.reduce(into: [String: Spec]()) { result, entry in
            let (nodeID, spec) = entry
            result[nodeID] = Spec(
                inputs: resolvedPins(
                    spec.inputs, nodeID: nodeID, direction: .input, assignments: assignments
                ),
                outputs: resolvedPins(
                    spec.outputs, nodeID: nodeID, direction: .output, assignments: assignments
                ),
                category: spec.category
            )
        }
    }

    private static func resolvedPins(
        _ pins: [ScriptGraphNodeLibrary.PinSpec],
        nodeID: String,
        direction: PinKey.Direction,
        assignments: [PinKey: Constraint]
    ) -> [ScriptGraphNodeLibrary.PinSpec] {
        pins.map { pin in
            let key = PinKey(
                nodeID: nodeID, direction: direction, connectorName: pin.connectorName
            )
            guard !pin.isExec, let concrete = assignments[key],
                  shouldMaterialize(pin.typeConstraint)
            else { return pin }
            return .init(
                connectorName: pin.connectorName,
                displayName: pin.displayName,
                isExec: false,
                typeConstraint: concrete,
                presence: pin.presence,
                contractEvidence: pin.contractEvidence
            )
        }
    }

    private static func canInfer(_ constraint: Constraint?) -> Bool {
        switch constraint {
        case .unknown, .sameAs, .arrayElement, .array: true
        case .any, .concrete, nil: false
        }
    }

    private static func shouldMaterialize(_ constraint: Constraint) -> Bool {
        switch constraint {
        case .sameAs, .arrayElement, .array: true
        case .unknown, .any, .concrete: false
        }
    }

    private static func inputKey(
        nodeID: String,
        connectorHash: UInt64,
        contracts: [String: Spec]
    ) -> PinKey? {
        guard let pin = contracts[nodeID]?.inputs.first(where: {
            !$0.isExec && $0.connectorHash == connectorHash
        }) else { return nil }
        return .init(nodeID: nodeID, direction: .input, connectorName: pin.connectorName)
    }

    private static func outputKey(
        nodeID: String,
        connectorHash: UInt64,
        contracts: [String: Spec]
    ) -> PinKey? {
        guard let pin = contracts[nodeID]?.outputs.first(where: {
            !$0.isExec && $0.connectorHash == connectorHash
        }) else { return nil }
        return .init(nodeID: nodeID, direction: .output, connectorName: pin.connectorName)
    }

    private static func literalConstraint(
        _ literal: RCP3ScriptGraph.DataLiteral
    ) -> Constraint? {
        if let value = literal.value {
            switch value {
            case .number:
                return concrete(ScriptGraphTypeRegistry.number)
            case .bool:
                return concrete(ScriptGraphTypeRegistry.bool)
            case .string:
                return concrete(ScriptGraphTypeRegistry.string)
            case .variableRef:
                break
            }
        }
        return switch literal.valueType {
        case "tm_double", "tm_float": concrete(ScriptGraphTypeRegistry.number)
        case "tm_bool": concrete(ScriptGraphTypeRegistry.bool)
        case "tm_string": concrete(ScriptGraphTypeRegistry.string)
        default: nil
        }
    }

    private static func concrete(_ identity: ScriptGraphTypeRegistry.Identity) -> Constraint {
        .concrete(token: identity.id, typeHash: identity.typeHash)
    }

    private static func elementConstraint(of array: Constraint) -> Constraint? {
        guard case let .concrete(token, typeHash) = array else { return nil }
        let normalized = ScriptGraphTypeRegistry.identity(typeHash: typeHash ?? 0)?.id ?? token
        guard normalized.hasPrefix("Array<"), normalized.hasSuffix(">") else { return nil }
        let elementToken = String(normalized.dropFirst(6).dropLast())
        if let identity = ScriptGraphTypeRegistry.identity(named: elementToken) {
            return concrete(identity)
        }
        return .concrete(token: elementToken, typeHash: nil)
    }

    private static func arrayConstraint(of element: Constraint) -> Constraint? {
        guard case let .concrete(token, typeHash) = element else { return nil }
        let elementToken = ScriptGraphTypeRegistry.identity(typeHash: typeHash ?? 0)?.id ?? token
        let arrayToken = "Array<\(elementToken)>"
        if let identity = ScriptGraphTypeRegistry.identity(named: arrayToken) {
            return concrete(identity)
        }
        return .concrete(token: arrayToken, typeHash: nil)
    }
}
