import TMFormat

/// A constant value bound to a script-graph pin — the *meaning* of a `tm_graph`
/// `data[]` entry's inner `data: { … }` value object.
///
/// This is the single, closed model the whole pipeline is meant to speak (parse →
/// edit → write-back → compile), replacing a scalar-only `Double?` that would grow a
/// new optional per kind ("a mole per type"). Adding a value kind is then one `case`
/// here + one row in the value-format table in `Docs/CleanRoom-Spec.md` + one inspector
/// affordance — not a structural change.
///
/// CLEAN-ROOM: only the encodings we have **observed** are modeled. The numeric and
/// variable-reference shapes are captured (see the format table in the spec). The
/// remaining kinds (boolean, string, enum, vector, color, entity/asset reference) are
/// deliberately absent until a capture pins their on-disk `data: { … }` shape — they
/// must not be guessed. Each lands as a new `case` + parser branch when captured.
public enum TMGraphValue: Equatable, Sendable {
    /// A plain number — `data: { value: <number> }`. The kind an unwired numeric pin
    /// (a `make_vector*` component, a math operand) carries; the compiler reads it.
    case number(Double)

    /// A boolean — `data: { __type: "tm_bool", bool: <true|false> }`. Observed from
    /// `bool.realitycomposerpro` (a `tm_make_bool` node's *Initial Value*).
    case bool(Bool)

    /// A reference to a graph variable — `data: { __type: "tm_graph_variable_ref",
    /// name: "<var>", ref: "<uuid>" }` — bound to a Get/Set/Clear variable node's
    /// `name` connector. `ref` is the variable table entry's uuid, when present.
    case variableRef(name: String, ref: String?)

    // PENDING observed captures — see the "Pin literal value encodings" table in
    // Docs/CleanRoom-Spec.md. Do NOT add these until the capture pins the shape:
    //   case string(String)
    //   case enumCase(type: String, caseName: String)   // script_graph_enum
    //   case vector([Double])                            // make_vector* literals
    //   case color(...)                                  // re_* color literal
    //   case entityRef(String) / assetRef(String)

    /// Classifies the inner `data: { … }` value object into a known value, or `nil`
    /// when its shape isn't one we've observed yet (e.g. a `component_type` literal,
    /// which carries a named `type` hash rather than a value — left to the caller to
    /// preserve untouched). The single source of truth for "what is this literal?".
    public init?(valueObject: TMObject) {
        if valueObject.type == "tm_graph_variable_ref" {
            guard let name = valueObject.name else { return nil }
            self = .variableRef(name: name, ref: valueObject["ref"]?.stringValue)
            return
        }
        if valueObject.type == "tm_bool" {
            self = .bool(valueObject["bool"]?.boolValue ?? false)
            return
        }
        if let number = valueObject["value"]?.doubleValue {
            self = .number(number)
            return
        }
        return nil
    }

    /// The numeric value, when this is a `.number` (else `nil`). Bridge for the
    /// scalar-literal pipeline still keyed on `Double`.
    public var number: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    /// The boolean value, when this is a `.bool` (else `nil`).
    public var bool: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }
}
