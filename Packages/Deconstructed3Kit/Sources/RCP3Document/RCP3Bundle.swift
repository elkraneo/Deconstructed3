import Foundation
import TMFormat

/// A loaded RCP 3 `<Name>.realitycomposerpro` bundle.
///
/// v1 loads the root scene entity and (if present) the type-index size. The root
/// is `world.tm_entity` for native projects, or `Scene.import/Scene.tm_entity` for
/// projects migrated from a USD import.
public struct RCP3Bundle: Sendable {
    public let url: URL
    /// Absolute URL of the root entity file that `root` was loaded from
    /// (`world.tm_entity` or `Scene.import/Scene.tm_entity`). Save writes here.
    public let rootURL: URL
    /// The root scene entity object.
    public let root: TMObject
    /// Number of type definitions in `__type_index.tm_meta`, if the index is present.
    public let typeCount: Int?

    public enum LoadError: Error, Sendable {
        case notADirectory
        case noRootEntity
    }

    /// A display projection of the root entity tree.
    public var entity: RCP3Entity { RCP3Entity(root) }

    public static func open(_ url: URL) throws -> RCP3Bundle {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LoadError.notADirectory
        }

        let candidates = [
            url.appending(path: "world.tm_entity"),
            url.appending(path: "Scene.import/Scene.tm_entity"),
        ]
        guard let rootURL = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else {
            throw LoadError.noRootEntity
        }

        let rootText = try String(contentsOf: rootURL, encoding: .utf8)
        guard let root = try TM.parse(rootText).objectValue else {
            throw LoadError.noRootEntity
        }

        var typeCount: Int?
        let typeIndexURL = url.appending(path: "__type_index.tm_meta")
        if fm.fileExists(atPath: typeIndexURL.path),
           let text = try? String(contentsOf: typeIndexURL, encoding: .utf8),
           let types = try? TM.parse(text).arrayValue {
            typeCount = types.count
        }

        return RCP3Bundle(url: url, rootURL: rootURL, root: root, typeCount: typeCount)
    }

    /// Writes `newRoot` back to the bundle's root entity file via `tmText()`,
    /// returning a `RCP3Bundle` whose `root` reflects what is now on disk.
    ///
    /// This is the write-back half of open → edit → save: the caller mutates the
    /// `root` object (see `TMObject` mutation API) and persists the result. Only
    /// the root entity file is rewritten; sibling files (type index, settings,
    /// `core.lib`, binary buffers) are untouched.
    @discardableResult
    public func save(_ newRoot: TMObject) throws -> RCP3Bundle {
        try newRoot.tmText().write(to: rootURL, atomically: true, encoding: .utf8)
        return RCP3Bundle(url: url, rootURL: rootURL, root: newRoot, typeCount: typeCount)
    }

    /// Writes the bundle's current `root` back to disk (convenience for callers
    /// holding an already-mutated bundle value).
    public func save() throws {
        try root.tmText().write(to: rootURL, atomically: true, encoding: .utf8)
    }
}
