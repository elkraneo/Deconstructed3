import Foundation
import TMFormat

/// A mutable editing session over an RCP 3 bundle's root entity — the open → edit
/// → save loop in one value.
///
/// `RCP3Editor` opens a bundle, exposes its `root` as a mutable `TMObject`, and
/// writes back through `save()`. It is a value type (struct), so an editing UI
/// can hold it in observable state, mutate `root` (or use the `TMObject` /
/// `TMPath` mutation helpers and `apply(_:)`), and persist with `save()`. A
/// `hasUnsavedChanges` flag tracks divergence from the last on-disk write.
///
/// Sibling files (type index, settings, `core.lib`, binary buffers) are never
/// touched — only the root entity file is rewritten.
public struct RCP3Editor: Sendable, Equatable {
    /// The mutable root scene entity. Edit this, then `save()`.
    public var root: TMObject

    /// The bundle backing this session (URLs + immutable metadata).
    public let bundle: RCP3Bundle

    /// The root as last written to (or read from) disk, for change tracking.
    private var savedRoot: TMObject

    /// `true` once `root` has diverged from what is on disk.
    public var hasUnsavedChanges: Bool { root != savedRoot }

    /// A display projection of the current (possibly unsaved) root tree.
    public var entity: RCP3Entity { RCP3Entity(root) }

    /// A render-oriented projection of the current (possibly unsaved) root tree,
    /// resolved against this bundle's built-in geometry library. Reflects in-memory
    /// edits (e.g. a rename) immediately, before `save()`.
    public var sceneGraph: RCP3SceneNode { bundle.sceneGraph(for: root) }

    /// The script graph attached to the entity with this display id in the current
    /// (possibly unsaved) root tree, or `nil` when that entity has no
    /// `re_scripting_component`. The graph asset is resolved from this bundle's
    /// `*.tm_script_graph` files.
    public func scriptGraph(forEntityID id: RCP3Entity.ID) -> RCP3ScriptGraph? {
        guard let object = RCP3Bundle.findEntity(id: id, in: root) else { return nil }
        return bundle.scriptGraph(forEntity: object)
    }

    /// Every `*.tm_script_graph` asset in the backing bundle, as browsable assets
    /// sorted by name — the script graphs the user can open directly, independent of
    /// which entity references them.
    public func scriptGraphAssets() -> [RCP3ScriptGraphAsset] {
        bundle.scriptGraphAssets()
    }

    /// Creates a new empty `*.tm_script_graph` asset in the backing bundle (the RCP
    /// "+ → Script Graph" action) and returns it. Writes directly to disk.
    public func createScriptGraphAsset(
        named base: String = "Script Graph",
        makeUUID: () -> String = { UUID().uuidString.lowercased() }
    ) throws -> RCP3ScriptGraphAsset {
        try bundle.createScriptGraphAsset(named: base, makeUUID: makeUUID)
    }

    /// Loads and parses the bundle's `*.tm_script_graph` asset with this id (the
    /// asset's root `__uuid`).
    public func scriptGraph(assetID: String) -> RCP3ScriptGraph? {
        bundle.scriptGraph(assetID: assetID)
    }

    private init(bundle: RCP3Bundle) {
        self.bundle = bundle
        self.root = bundle.root
        self.savedRoot = bundle.root
    }

    /// Opens `url` for editing.
    public static func open(_ url: URL) throws -> RCP3Editor {
        RCP3Editor(bundle: try RCP3Bundle.open(url))
    }

    /// Applies an in-place transform to `root` and returns whether it changed.
    @discardableResult
    public mutating func apply(_ transform: (inout TMObject) -> Void) -> Bool {
        let before = root
        transform(&root)
        return root != before
    }

    /// Writes the current `root` back to the bundle's root entity file, clearing
    /// `hasUnsavedChanges`. No-op-safe to call when there are no changes.
    public mutating func save() throws {
        try bundle.save(root)
        savedRoot = root
    }

    /// Discards unsaved edits, restoring `root` to the last-saved state.
    public mutating func revert() {
        root = savedRoot
    }
}
