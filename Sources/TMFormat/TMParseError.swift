/// A failure while parsing `.tm_*` text, with 1-based source position.
public struct TMParseError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public let line: Int
    public let column: Int

    public init(message: String, line: Int, column: Int) {
        self.message = message
        self.line = line
        self.column = column
    }

    public var description: String {
        "TM parse error at \(line):\(column): \(message)"
    }
}
