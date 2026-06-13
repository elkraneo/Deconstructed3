/// A parsed value in the RCP 3 `.tm_*` text object-database format.
///
/// The format is a self-describing, tab-indented text grammar (see
/// `Docs/CleanRoom-Spec.md`). Scalars keep their original lexeme so the tree can
/// be re-emitted faithfully later; numbers are not eagerly converted to `Double`.
public indirect enum TMValue: Equatable, Sendable {
    case string(String)
    /// Raw numeric lexeme (e.g. `"-9.8100004196166992"`), preserved for round-trip.
    case number(String)
    case bool(Bool)
    /// A bareword (unquoted) value, e.g. an enum case written without quotes.
    case symbol(String)
    case object(TMObject)
    case array([TMValue])
}

public extension TMValue {
    var stringValue: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    var objectValue: TMObject? {
        if case let .object(o) = self { return o }
        return nil
    }

    var arrayValue: [TMValue]? {
        if case let .array(a) = self { return a }
        return nil
    }

    var boolValue: Bool? {
        if case let .bool(b) = self { return b }
        return nil
    }

    /// The numeric lexeme parsed as a `Double`, if this is a number.
    var doubleValue: Double? {
        if case let .number(n) = self { return Double(n) }
        return nil
    }

    /// The raw numeric lexeme, preserved exactly as written.
    var numberLexeme: String? {
        if case let .number(n) = self { return n }
        return nil
    }
}
