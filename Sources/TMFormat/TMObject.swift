/// An ordered set of `key: value` members — the object node of the `.tm_*` format.
///
/// Member order is preserved (the format is order-significant for re-emit). Keys
/// are generally unique within an object; `subscript(_:)` returns the first match.
public struct TMObject: Equatable, Sendable {
    public struct Member: Equatable, Sendable {
        public let key: String
        public var value: TMValue

        public init(key: String, value: TMValue) {
            self.key = key
            self.value = value
        }
    }

    public var members: [Member]

    public init(members: [Member] = []) {
        self.members = members
    }

    /// First value bound to `key`, or `nil`.
    public subscript(_ key: String) -> TMValue? {
        members.first { $0.key == key }?.value
    }

    // Reserved (`__`-prefixed) keys observed in the format.

    /// `__type` — the object's type name (resolvable in `__type_index.tm_meta`).
    public var type: String? { self["__type"]?.stringValue }

    /// `__uuid` — stable object identity.
    public var uuid: String? { self["__uuid"]?.stringValue }

    /// `__prototype_type` — the type this object inherits from.
    public var prototypeType: String? { self["__prototype_type"]?.stringValue }

    /// `__prototype_uuid` — the prototype object this one derives from.
    public var prototypeUUID: String? { self["__prototype_uuid"]?.stringValue }

    /// `name` — the human-facing name, when present.
    public var name: String? { self["name"]?.stringValue }
}
