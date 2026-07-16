import RCP3Document
import TMFormat

extension ScriptGraphNodeLibrary {
    public struct EnumPinPolicy: Sendable, Hashable {
        public enum Direction: Sendable, Hashable {
            case make
            case `break`
        }

        public let direction: Direction
        public let schema: ScriptGraphValueSchema.EnumNodeSchema

        /// The fixed side of the interface. The other side is populated with the
        /// selected case's associated values, using their public descriptor labels.
        public var fixedPins: [PinSpec] {
            switch direction {
            case .make:
                return [.data(
                    "value", "Value",
                    type: Self.schemaType(schema.typeName),
                    evidence: .publicSchema
                )]
            case .break:
                return [.data(
                    "source", "Source",
                    type: Self.schemaType(schema.typeName),
                    presence: .required,
                    evidence: .publicSchema
                )]
            }
        }

        private static func schemaType(_ name: String) -> PinTypeConstraint {
            if let identity = ScriptGraphTypeRegistry.identity(named: name) {
                return .concrete(token: identity.id, typeHash: identity.typeHash)
            }
            return .concrete(token: name, typeHash: nil)
        }

        public func selectedCase(named name: String?) -> ScriptGraphValueSchema.EnumCase? {
            if let name, let match = schema.cases.first(where: { $0.name == name }) { return match }
            return schema.cases.first
        }
    }

    /// Source-backed enum connector policy. `RCP3ScriptGraph.Node` carries the
    /// selected-case setting, so the resolver can author the case-dependent pins.
    public static func enumPinPolicy(for type: String) -> EnumPinPolicy? {
        if let schema = ScriptGraphValueSchema.enumMakeNodes[type] {
            return EnumPinPolicy(direction: .make, schema: schema)
        }
        if let schema = ScriptGraphValueSchema.enumBreakNodes[type] {
            return EnumPinPolicy(direction: .break, schema: schema)
        }
        return nil
    }

    /// Initial settings for inserting an enum node. RCP's registry identifies enum
    /// types by the same schema-name Murmur hash used elsewhere in graph metadata.
    public static func defaultEnumSelection(for type: String) -> RCP3ScriptGraph.Node.EnumSelection? {
        guard let policy = enumPinPolicy(for: type), let selected = policy.schema.cases.first else {
            return nil
        }
        return enumSelection(policy: policy, selectedCase: selected)
    }

    public static func enumSelection(
        for type: String,
        caseName: String
    ) -> RCP3ScriptGraph.Node.EnumSelection? {
        guard
            let policy = enumPinPolicy(for: type),
            let selected = policy.schema.cases.first(where: { $0.name == caseName })
        else { return nil }
        return enumSelection(policy: policy, selectedCase: selected)
    }

    private static func enumSelection(
        policy: EnumPinPolicy,
        selectedCase: ScriptGraphValueSchema.EnumCase
    ) -> RCP3ScriptGraph.Node.EnumSelection {
        return .init(
            typeHash: TMHash.murmur64a(policy.schema.typeName),
            caseName: selectedCase.name,
            associatedValues: selectedCase.associatedValues.enumerated().map { index, value in
                .init(index: UInt32(index), typeHash: TMHash.murmur64a(value.swiftType))
            }
        )
    }

    /// Fixed Break/Write interfaces derived from Apple's public
    /// `RealityKitScripting` property registry and restricted to node types in the
    /// shipped RCP3 catalog. Existing directly observed specs win when both exist.
    ///
    /// Enum Make/Break nodes use the first public registry case as their insert-time
    /// interface; parsed nodes resolve their actual selected case dynamically.
    static let schemaDerivedSpecsByType: [String: NodeSpec] = {
        var result: [String: NodeSpec] = [:]
        for (type, schema) in ScriptGraphValueSchema.breakNodes {
            result[type] = NodeSpec(
                inputs: [.data(
                    "source", "Source",
                    type: schemaType(schema.typeName),
                    presence: .required,
                    evidence: .publicSchema
                )],
                outputs: schema.properties.map {
                    .data(
                        $0.name,
                        displayName(forSchemaProperty: $0.name),
                        type: schemaType($0.swiftType),
                        evidence: .publicSchema
                    )
                },
                category: .make
            )
        }
        for (type, schema) in ScriptGraphValueSchema.writeNodes {
            result[type] = NodeSpec(
                inputs: [.data(
                    "source", "Source",
                    type: schemaType(schema.typeName),
                    presence: .required,
                    evidence: .publicSchema
                )] + schema.properties.map {
                    .data(
                        $0.name,
                        displayName(forSchemaProperty: $0.name),
                        type: schemaType($0.swiftType),
                        // Inspectable optionality describes the Swift value, not
                        // whether RCP3 requires a graph binding. A non-optional
                        // property may still have a registration default.
                        presence: $0.isOptional ? .optional : .unknown,
                        evidence: .publicSchema
                    )
                },
                outputs: [.data(
                    "source", "Source",
                    type: schemaType(schema.typeName),
                    evidence: .publicSchema
                )],
                category: .make
            )
        }
        // Enum interfaces are selected-case dependent. The fixed dictionary carries
        // their default (first registry case) so they are insertable; the resolver
        // replaces it with the actual selected case for every parsed/edited node.
        for (type, schema) in ScriptGraphValueSchema.enumMakeNodes {
            guard let selected = schema.cases.first else { continue }
            result[type] = NodeSpec(
                inputs: selected.associatedValues.map {
                    .data(
                        $0.name,
                        displayName(forSchemaProperty: $0.name),
                        type: schemaType($0.swiftType),
                        presence: .unknown,
                        evidence: .publicSchema
                    )
                },
                outputs: [.data(
                    "value", "Value",
                    type: schemaType(schema.typeName),
                    evidence: .publicSchema
                )],
                category: .make
            )
        }
        for (type, schema) in ScriptGraphValueSchema.enumBreakNodes {
            guard let selected = schema.cases.first else { continue }
            result[type] = NodeSpec(
                inputs: [.data(
                    "source", "Source",
                    type: schemaType(schema.typeName),
                    presence: .required,
                    evidence: .publicSchema
                )],
                outputs: selected.associatedValues.map {
                    .data(
                        $0.name,
                        displayName(forSchemaProperty: $0.name),
                        type: schemaType($0.swiftType),
                        evidence: .publicSchema
                    )
                },
                category: .make
            )
        }
        return result
    }()

    static func schemaType(_ swiftType: String) -> PinTypeConstraint {
        let normalized: String
        switch swiftType {
        case "Swift.Bool": normalized = "Bool"
        case "Swift.String": normalized = "String"
        case "Swift.Float", "Swift.Double", "Swift.Int", "Swift.UInt", "Swift.UInt64",
             "CoreGraphics.CGFloat": normalized = "Number"
        case "Swift.SIMD2<Swift.Float>": normalized = "Vector2"
        case "Swift.SIMD3<Swift.Float>": normalized = "Vector3"
        case "Swift.SIMD4<Swift.Float>": normalized = "Vector4"
        case "__C.simd_quatf": normalized = "Quaternion"
        case "__C.simd_float2x2": normalized = "Matrix2x2"
        case "__C.simd_float3x3": normalized = "Matrix3x3"
        case "__C.simd_float4x4": normalized = "Matrix4x4"
        case "RealityKit.Entity": normalized = "Entity"
        case "Swift.Array<Swift.String>": normalized = "Array<String>"
        default: normalized = swiftType
        }
        if let identity = ScriptGraphTypeRegistry.identity(named: normalized) {
            return .concrete(token: identity.id, typeHash: identity.typeHash)
        }
        return .concrete(token: normalized, typeHash: nil)
    }

    private static func displayName(forSchemaProperty name: String) -> String {
        let separated = name.reduce(into: "") { result, character in
            if character.isUppercase, !result.isEmpty { result.append(" ") }
            result.append(character)
        }
        return separated
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
