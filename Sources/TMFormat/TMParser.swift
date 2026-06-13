/// Parser for the RCP 3 `.tm_*` text object-database grammar.
///
/// Grammar (observed; see `Docs/CleanRoom-Spec.md`):
/// - Whitespace (incl. tabs/newlines) is insignificant beyond separating tokens;
///   structure comes from `{ }` and `[ ]`. Members and array elements are
///   whitespace-separated (no commas).
/// - A document root is either a bracketed array `[ … ]` or a *bare* object — a
///   sequence of `key: value` members with no enclosing braces.
/// - Values: quoted string, number, `true`/`false`, bareword symbol, `{ object }`,
///   `[ array ]`. Keys are barewords followed by `:`.
public enum TM {
    /// Parse a full `.tm_*` document.
    public static func parse(_ text: String) throws -> TMValue {
        var scanner = Scanner(text)
        scanner.skipTrivia()
        let value: TMValue
        switch scanner.peek() {
        case "["?: value = try scanner.parseArray()
        case "{"?: value = .object(try scanner.parseBracedObject())
        default: value = .object(try scanner.parseBareObject())
        }
        scanner.skipTrivia()
        guard scanner.isAtEnd else {
            throw scanner.error("unexpected trailing content")
        }
        return value
    }
}

private struct Scanner {
    let chars: [Character]
    var i = 0
    var line = 1
    var column = 1

    init(_ text: String) { chars = Array(text) }

    var isAtEnd: Bool { i >= chars.count }

    func peek() -> Character? { i < chars.count ? chars[i] : nil }

    @discardableResult
    mutating func advance() -> Character? {
        guard i < chars.count else { return nil }
        let c = chars[i]
        i += 1
        if c == "\n" { line += 1; column = 1 } else { column += 1 }
        return c
    }

    mutating func skipTrivia() {
        while let c = peek(), c == " " || c == "\t" || c == "\n" || c == "\r" {
            advance()
        }
    }

    func error(_ message: String) -> TMParseError {
        TMParseError(message: message, line: line, column: column)
    }

    mutating func parseValue() throws -> TMValue {
        skipTrivia()
        guard let c = peek() else { throw error("expected value, got end of input") }
        switch c {
        case "\"": return .string(try parseString())
        case "{": return .object(try parseBracedObject())
        case "[": return try parseArray()
        default:
            if c == "-" || c.isNumber { return .number(try parseNumber()) }
            let word = try parseIdent()
            switch word {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default: return .symbol(word)
            }
        }
    }

    mutating func parseBracedObject() throws -> TMObject {
        advance() // consume '{'
        return try parseMembers(closing: "}")
    }

    mutating func parseBareObject() throws -> TMObject {
        try parseMembers(closing: nil)
    }

    private mutating func parseMembers(closing: Character?) throws -> TMObject {
        var members: [TMObject.Member] = []
        while true {
            skipTrivia()
            if let close = closing {
                if peek() == close { advance(); break }
                if isAtEnd { throw error("expected '\(close)'") }
            } else if isAtEnd {
                break
            }
            let key = try parseIdent()
            skipTrivia()
            guard peek() == ":" else { throw error("expected ':' after key '\(key)'") }
            advance() // consume ':'
            let value = try parseValue()
            members.append(.init(key: key, value: value))
        }
        return TMObject(members: members)
    }

    mutating func parseArray() throws -> TMValue {
        advance() // consume '['
        var items: [TMValue] = []
        while true {
            skipTrivia()
            if peek() == "]" { advance(); break }
            if isAtEnd { throw error("expected ']'") }
            items.append(try parseValue())
        }
        return .array(items)
    }

    mutating func parseString() throws -> String {
        advance() // consume opening quote
        var out = ""
        while let c = advance() {
            if c == "\"" { return out }
            if c == "\\" {
                guard let escaped = advance() else { throw error("unterminated escape") }
                switch escaped {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                default: out.append("\\"); out.append(escaped)
                }
            } else {
                out.append(c)
            }
        }
        throw error("unterminated string")
    }

    mutating func parseNumber() throws -> String {
        var s = ""
        while let c = peek(),
              c == "-" || c == "+" || c == "." || c == "e" || c == "E" || c.isNumber {
            s.append(c)
            advance()
        }
        guard !s.isEmpty else { throw error("invalid number") }
        return s
    }

    /// A bareword run: any non-delimiter, non-whitespace characters. Used for keys
    /// and bareword (symbol) values.
    mutating func parseIdent() throws -> String {
        var s = ""
        while let c = peek(),
              !c.isWhitespace, c != ":", c != "{", c != "}", c != "[", c != "]", c != "\"" {
            s.append(c)
            advance()
        }
        guard !s.isEmpty else { throw error("expected identifier") }
        return s
    }
}
