import Testing

@testable import RCP3GraphEditor
import RCP3Document
import TMFormat

@Suite("ScriptGraph relational type resolution")
struct ScriptGraphRelationalTypeResolverTests {
    typealias Constraint = ScriptGraphNodeLibrary.PinTypeConstraint

    @Test("sameAs propagates concrete wire evidence across a generic node")
    func sameAsWireEvidence() throws {
        let number = concrete(ScriptGraphTypeRegistry.number)
        let contracts: [String: ScriptGraphNodeLibrary.NodeSpec] = [
            "source": spec(outputs: [.data("value", "Value", type: number)]),
            "generic": spec(
                inputs: [.data("input", "Input", type: .sameAs(connectorName: "output"))],
                outputs: [.data("output", "Output", type: .sameAs(connectorName: "input"))]
            ),
        ]
        let graph = RCP3ScriptGraph(
            nodes: [
                .init(id: "source", type: "test.source"),
                .init(id: "generic", type: "test.generic"),
            ],
            wires: [.init(
                id: "wire", from: "source", to: "generic",
                fromPin: TMHash.murmur64a("value"),
                toPin: TMHash.murmur64a("input")
            )],
            data: []
        )

        let resolved = ScriptGraphRelationalTypeResolver.resolve(contracts, in: graph)
        #expect(try #require(resolved["generic"]?.inputs.first).typeConstraint == number)
        #expect(try #require(resolved["generic"]?.outputs.first).typeConstraint == number)
    }

    @Test("array and arrayElement derive both sides of a String array")
    func arrayRelations() throws {
        let string = concrete(ScriptGraphTypeRegistry.string)
        let stringArray = concrete(ScriptGraphTypeRegistry.stringArray)
        let contracts: [String: ScriptGraphNodeLibrary.NodeSpec] = [
            "break": spec(
                inputs: [.data("array", "Array", type: stringArray)],
                outputs: [.data(
                    "element", "Element", type: .arrayElement(ofConnectorName: "array")
                )]
            ),
            "make": spec(
                inputs: [.data("element", "Element", type: .unknown)],
                outputs: [.data(
                    "array", "Array", type: .array(ofElementConnectorName: "element")
                )]
            ),
        ]
        let graph = RCP3ScriptGraph(
            nodes: [
                .init(id: "break", type: "test.break"),
                .init(id: "make", type: "test.make"),
            ],
            wires: [],
            data: [.init(
                id: "literal", toNode: "make", toPin: TMHash.murmur64a("element"),
                value: .string("value")
            )]
        )

        let resolved = ScriptGraphRelationalTypeResolver.resolve(contracts, in: graph)
        #expect(try #require(resolved["break"]?.outputs.first).typeConstraint == string)
        #expect(try #require(resolved["make"]?.outputs.first).typeConstraint == stringArray)
        // Unknown declarations can inform a relation but are not promoted into
        // source-backed exact contracts themselves.
        #expect(try #require(resolved["make"]?.inputs.first).typeConstraint == .unknown)
    }

    @Test("relations remain polymorphic without concrete graph evidence")
    func unresolvedRelation() throws {
        let relation = Constraint.sameAs(connectorName: "input")
        let contracts = [
            "generic": spec(
                inputs: [.data("input", "Input", type: .unknown)],
                outputs: [.data("output", "Output", type: relation)]
            ),
        ]
        let graph = RCP3ScriptGraph(
            nodes: [.init(id: "generic", type: "test.generic")], wires: [], data: []
        )

        let resolved = ScriptGraphRelationalTypeResolver.resolve(contracts, in: graph)
        #expect(try #require(resolved["generic"]?.outputs.first).typeConstraint == relation)
    }

    @Test("resolved array-element types reject incompatible wires")
    func arrayElementValidation() throws {
        let boolSource = ScriptGraphExternalAuthoringCatalog.Node(
            id: "test.bool-source",
            operationID: "bool-source",
            displayName: "Bool Source",
            category: .logic,
            execution: .pure,
            outputs: [.init(name: "value", displayName: "Value", typeToken: "Bool")]
        )
        let registry = ScriptGraphNodeRegistry(externalCatalog: .init(nodes: [boolSource]))
        let settings = try #require(
            ScriptGraphNodeLibrary.defaultDynamicConnectorSettings(for: "tm_array_find")
        )
        let graph = RCP3ScriptGraph(
            nodes: [
                .init(id: "bool", type: boolSource.id),
                .init(id: "find", type: "tm_array_find", dynamicConnectorSettings: settings),
            ],
            wires: [.init(
                id: "wrong", from: "bool", to: "find",
                fromPin: TMHash.murmur64a("value"),
                toPin: TMHash.murmur64a("searchValue")
            )],
            data: []
        )

        let contract = try #require(
            ScriptGraphPinResolver.resolvedContract(
                for: graph.nodes[1], in: graph, registry: registry
            )
        )
        #expect(contract.inputs.first {
            $0.connectorName == "searchValue"
        }?.typeConstraint == concrete(ScriptGraphTypeRegistry.string))

        let report = ScriptGraphValidator.validate(graph, registry: registry)
        #expect(report.errors.contains {
            $0.code == .incompatibleWireTypes && $0.subject == "wrong"
        })
    }

    @Test("resolved array-element types reject incompatible literals")
    func arrayElementLiteralValidation() throws {
        let settings = try #require(
            ScriptGraphNodeLibrary.defaultDynamicConnectorSettings(for: "tm_array_find")
        )
        let graph = RCP3ScriptGraph(
            nodes: [.init(
                id: "find", type: "tm_array_find", dynamicConnectorSettings: settings
            )],
            wires: [],
            data: [.init(
                id: "wrong", toNode: "find",
                toPin: TMHash.murmur64a("searchValue"), value: .bool(true)
            )]
        )

        let report = ScriptGraphValidator.validate(graph)
        #expect(report.errors.contains {
            $0.code == .incompatibleLiteralType && $0.subject == "wrong"
        })
    }

    private func spec(
        inputs: [ScriptGraphNodeLibrary.PinSpec] = [],
        outputs: [ScriptGraphNodeLibrary.PinSpec] = []
    ) -> ScriptGraphNodeLibrary.NodeSpec {
        .init(inputs: inputs, outputs: outputs, category: .utility)
    }

    private func concrete(_ identity: ScriptGraphTypeRegistry.Identity) -> Constraint {
        .concrete(token: identity.id, typeHash: identity.typeHash)
    }
}
