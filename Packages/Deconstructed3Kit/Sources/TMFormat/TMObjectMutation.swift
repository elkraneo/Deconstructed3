/// Mutation API for `TMObject` — the "edit" half of open → edit → save.
///
/// All operations preserve member order: setting an existing key rewrites that
/// member in place; setting a new key appends it. Only the targeted member
/// changes — siblings are untouched. The functional `setting(_:forKey:)` variants
/// return a copy and never observe side effects, which suits value-type editing in
/// SwiftUI/TCA; the mutating `set(_:forKey:)` variants edit in place.
///
/// Path-based variants address nested members through a `TMPath`, mixing object
/// member keys and array indices (`children[0].name`), so an editing UI can target
/// a deep field by route without manually unwrapping the tree.
public extension TMObject {
    // MARK: Flat member set

    /// Returns a copy with `key` bound to `value`. If `key` already exists, the
    /// first matching member is rewritten in place (order preserved); otherwise a
    /// new member is appended.
    func setting(_ value: TMValue, forKey key: String) -> TMObject {
        var copy = self
        copy.set(value, forKey: key)
        return copy
    }

    /// Binds `key` to `value` in place. Rewrites the first matching member if
    /// present (order preserved), else appends.
    mutating func set(_ value: TMValue, forKey key: String) {
        if let index = members.firstIndex(where: { $0.key == key }) {
            members[index].value = value
        } else {
            members.append(.init(key: key, value: value))
        }
    }

    /// Removes the first member bound to `key`, returning a copy. No-op if absent.
    func removing(key: String) -> TMObject {
        var copy = self
        copy.remove(key: key)
        return copy
    }

    /// Removes the first member bound to `key` in place. No-op if absent.
    mutating func remove(key: String) {
        if let index = members.firstIndex(where: { $0.key == key }) {
            members.remove(at: index)
        }
    }

    // MARK: Convenience

    /// Returns a copy with `name` set to `value` (the entity/object display name).
    func settingName(_ value: String) -> TMObject {
        setting(.string(value), forKey: "name")
    }

    // MARK: Path-based set (nested)

    /// Returns a copy with the value addressed by `path` set to `value`. Throws
    /// `TMPathError` if any intermediate step cannot be resolved.
    ///
    /// The path's last step must be a `.member`, since the format writes through
    /// object members; the leading steps may descend through members and array
    /// indices alike. Empty paths are invalid.
    func setting(_ value: TMValue, at path: TMPath) throws -> TMObject {
        guard let last = path.steps.last, case .member = last else {
            throw TMPathError.expectedMemberStep(path.steps.last)
        }
        guard case let .object(updated) = try Self.replacing(at: path.steps[...], in: .object(self), with: value) else {
            throw TMPathError.notAnObject(path.steps.first)
        }
        return updated
    }

    /// Resolves the value addressed by `path` (empty path → this object).
    func value(at path: TMPath) throws -> TMValue {
        try Self.resolving(path.steps[...], in: .object(self))
    }

    /// Resolves the object addressed by `path` (empty path → `self`).
    func object(at path: TMPath) throws -> TMObject {
        guard let object = try value(at: path).objectValue else {
            throw TMPathError.notAnObject(path.steps.last)
        }
        return object
    }
}

// MARK: - Recursive resolution / replacement

private extension TMObject {
    static func resolving(_ steps: ArraySlice<TMPath.Step>, in container: TMValue) throws -> TMValue {
        guard let step = steps.first else { return container }
        let rest = steps.dropFirst()
        switch step {
        case let .member(key):
            guard let object = container.objectValue else { throw TMPathError.notAnObject(step) }
            guard let next = object[key] else { throw TMPathError.missingMember(key) }
            return try resolving(rest, in: next)
        case let .index(i):
            guard let array = container.arrayValue else { throw TMPathError.notAnArray(step) }
            guard array.indices.contains(i) else { throw TMPathError.indexOutOfBounds(i) }
            return try resolving(rest, in: array[i])
        }
    }

    /// Returns `container` with the value at `steps` replaced by `newValue`.
    /// The final step writes through; intermediate steps descend and rebuild.
    static func replacing(at steps: ArraySlice<TMPath.Step>, in container: TMValue, with newValue: TMValue) throws -> TMValue {
        guard let step = steps.first else { return newValue }
        let rest = steps.dropFirst()
        switch step {
        case let .member(key):
            guard var object = container.objectValue else { throw TMPathError.notAnObject(step) }
            if rest.isEmpty {
                object.set(newValue, forKey: key)
            } else {
                guard let child = object[key] else { throw TMPathError.missingMember(key) }
                object.set(try replacing(at: rest, in: child, with: newValue), forKey: key)
            }
            return .object(object)
        case let .index(i):
            guard var array = container.arrayValue else { throw TMPathError.notAnArray(step) }
            guard array.indices.contains(i) else { throw TMPathError.indexOutOfBounds(i) }
            array[i] = try replacing(at: rest, in: array[i], with: newValue)
            return .array(array)
        }
    }
}

// MARK: - Path

/// A route to a nested member or array element within a `TMObject`.
///
/// Steps resolve left-to-right. A `.member(key)` selects an object member by key;
/// an `.index(i)` selects an array element by position. Construct directly, or via
/// the dotted/bracketed string form (`children[0].name`).
public struct TMPath: Equatable, Sendable {
    public enum Step: Equatable, Sendable, CustomStringConvertible {
        case member(String)
        case index(Int)

        public var description: String {
            switch self {
            case let .member(key): ".\(key)"
            case let .index(i): "[\(i)]"
            }
        }
    }

    public var steps: [Step]

    public init(_ steps: [Step]) { self.steps = steps }

    /// Parse a path like `children[0].name` or `components[1].local_scale`.
    public init(_ string: String) {
        var steps: [Step] = []
        var token = ""
        func flushMember() {
            if !token.isEmpty { steps.append(.member(token)); token = "" }
        }
        var i = string.startIndex
        while i < string.endIndex {
            let c = string[i]
            switch c {
            case ".":
                flushMember()
                i = string.index(after: i)
            case "[":
                flushMember()
                i = string.index(after: i)
                var digits = ""
                while i < string.endIndex, string[i] != "]" {
                    digits.append(string[i])
                    i = string.index(after: i)
                }
                if i < string.endIndex { i = string.index(after: i) } // consume ']'
                if let n = Int(digits) { steps.append(.index(n)) }
            default:
                token.append(c)
                i = string.index(after: i)
            }
        }
        flushMember()
        self.steps = steps
    }
}

extension TMPath: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self.init(value) }
}

/// A failure resolving or applying a `TMPath`.
public enum TMPathError: Error, Equatable, Sendable, CustomStringConvertible {
    case emptyPath
    case expectedMemberStep(TMPath.Step?)
    case missingMember(String)
    case indexOutOfBounds(Int)
    case notAnObject(TMPath.Step?)
    case notAnArray(TMPath.Step)

    public var description: String {
        switch self {
        case .emptyPath: "TM path error: empty path"
        case let .expectedMemberStep(step): "TM path error: final step must be a member, got \(step.map(String.init(describing:)) ?? "nil")"
        case let .missingMember(key): "TM path error: no member '\(key)'"
        case let .indexOutOfBounds(i): "TM path error: index \(i) out of bounds"
        case let .notAnObject(step): "TM path error: \(step.map(String.init(describing:)) ?? "root") is not an object"
        case let .notAnArray(step): "TM path error: \(step) is not an array"
        }
    }
}
