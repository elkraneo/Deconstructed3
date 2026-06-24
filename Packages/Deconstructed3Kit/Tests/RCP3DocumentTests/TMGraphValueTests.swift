import Testing
import TMFormat
import RCP3Document

/// The canonical script-graph pin-literal value model. Parsing the inner
/// `data: { … }` value object is centralized here, so these pin the two observed
/// encodings (number, variable reference) and that unmodeled shapes classify as
/// `nil` (left for the caller to preserve).
@Suite struct TMGraphValueTests {
    private func object(_ members: [(String, TMValue)]) -> TMObject {
        TMObject(members: members.map { .init(key: $0.0, value: $0.1) })
    }

    @Test func parsesNumber() {
        let value = TMGraphValue(valueObject: object([("value", .number("2.5"))]))
        #expect(value == .number(2.5))
        #expect(value?.number == 2.5)
    }

    @Test func parsesBoolean() {
        // Observed shape (bool.realitycomposerpro): { __type: "tm_bool", bool: true }.
        let value = TMGraphValue(valueObject: object([
            ("__type", .string("tm_bool")),
            ("bool", .bool(true)),
        ]))
        #expect(value == .bool(true))
        #expect(value?.bool == true)
        #expect(value?.number == nil)

        let falseValue = TMGraphValue(valueObject: object([
            ("__type", .string("tm_bool")),
            ("bool", .bool(false)),
        ]))
        #expect(falseValue == .bool(false))
    }

    @Test func parsesVariableReference() {
        let value = TMGraphValue(valueObject: object([
            ("__type", .string("tm_graph_variable_ref")),
            ("name", .string("spin")),
            ("ref", .string("uuid-1")),
        ]))
        #expect(value == .variableRef(name: "spin", ref: "uuid-1"))
        #expect(value?.number == nil)
    }

    @Test func variableReferenceRefIsOptional() {
        let value = TMGraphValue(valueObject: object([
            ("__type", .string("tm_graph_variable_ref")),
            ("name", .string("t")),
        ]))
        #expect(value == .variableRef(name: "t", ref: nil))
    }

    @Test func unmodeledShapeIsNil() {
        // A component_type literal carries a named `type` hash, not a value — not a
        // kind we model yet, so it classifies as nil (caller preserves it untouched).
        let componentType = TMGraphValue(valueObject: object([("type", .string("8c878bd87b046f80"))]))
        #expect(componentType == nil)
        // An empty value object is likewise nil.
        #expect(TMGraphValue(valueObject: object([])) == nil)
    }
}
