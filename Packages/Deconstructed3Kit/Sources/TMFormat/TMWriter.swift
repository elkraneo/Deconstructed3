/// Serializes a `TMValue` back to `.tm_*` text.
///
/// Matches the observed RCP 3 style: tab indentation, `key: value`, objects and
/// arrays expanded across lines. A document root that is an object is emitted
/// *bare* (no enclosing braces), as RCP writes entity/settings files; a root array
/// is emitted with `[ … ]`, as RCP writes `__type_index.tm_meta`.
///
/// v1 targets **semantic** fidelity (parse → write → parse yields an equal tree).
/// Byte-exact reproduction of every spacing nuance is a later refinement.
public extension TMValue {
    func tmText() -> String {
        var out = ""
        switch self {
        case .object(let object):
            writeMembers(object, depth: 0, into: &out) // bare root object
        case .array(let items):
            writeArray(items, depth: 0, into: &out)
        case .string, .number, .bool, .symbol:
            writeScalar(self, into: &out)
        }
        if !out.hasSuffix("\n") { out.append("\n") }
        return out
    }
}

public extension TMObject {
    /// Emit this object as a document root (bare, no enclosing braces).
    func tmText() -> String { TMValue.object(self).tmText() }
}

private func indent(_ depth: Int) -> String {
    String(repeating: "\t", count: depth)
}

private func writeScalar(_ value: TMValue, into out: inout String) {
    switch value {
    case .string(let s): out += "\"" + escaped(s) + "\""
    case .number(let n): out += n
    case .bool(let b): out += b ? "true" : "false"
    case .symbol(let s): out += s
    case .object, .array: break // not scalars
    }
}

private func writeValue(_ value: TMValue, depth: Int, into out: inout String) {
    switch value {
    case .object(let object):
        out += "{\n"
        writeMembers(object, depth: depth + 1, into: &out)
        out += indent(depth) + "}"
    case .array(let items):
        writeArray(items, depth: depth, into: &out)
    case .string, .number, .bool, .symbol:
        writeScalar(value, into: &out)
    }
}

private func writeMembers(_ object: TMObject, depth: Int, into out: inout String) {
    for member in object.members {
        out += indent(depth) + keyText(member.key) + ": "
        writeValue(member.value, depth: depth, into: &out)
        out += "\n"
    }
}

/// Bareword keys are emitted as-is; keys with whitespace/delimiters (or empty) are
/// quoted so they round-trip (e.g. `"Max AO distance"`).
private func keyText(_ key: String) -> String {
    let needsQuoting = key.isEmpty || key.contains { $0.isWhitespace || ":{}[]\"".contains($0) }
    return needsQuoting ? "\"" + escaped(key) + "\"" : key
}

private func writeArray(_ items: [TMValue], depth: Int, into out: inout String) {
    out += "[\n"
    for item in items {
        out += indent(depth + 1)
        writeValue(item, depth: depth + 1, into: &out)
        out += "\n"
    }
    out += indent(depth) + "]"
}

private func escaped(_ s: String) -> String {
    var result = ""
    for c in s {
        switch c {
        case "\"": result += "\\\""
        case "\\": result += "\\\\"
        case "\n": result += "\\n"
        case "\t": result += "\\t"
        case "\r": result += "\\r"
        default: result.append(c)
        }
    }
    return result
}
