/// One running script in a Play/Simulate scene: the entity it's attached to and the
/// resolved graph it runs. Mirrors RCP, where every entity carrying a scripting
/// component runs its own graph (not just the selected one).
public struct EntityScriptBinding: Sendable, Equatable {
    public let entityID: String
    public let graph: RCP3ScriptGraph

    public init(entityID: String, graph: RCP3ScriptGraph) {
        self.entityID = entityID
        self.graph = graph
    }
}

/// The full input to a canonical Play/Simulate run: the scene to reconstruct, the
/// per-entity scripts to run, and a *preview* fallback for the ▶-on-an-open-graph
/// case (a standalone asset or an Examples gallery graph not yet attached to any
/// entity). Computed live from the document so the preview reflects edits.
public struct CanonicalPlayScene: Sendable {
    /// The scene to reconstruct, or `nil` when no project is open (a neutral box stands in).
    public let scene: RCP3SceneNode?
    /// Every entity that carries a scripting component with a resolved graph — each
    /// runs its own script.
    public let scripts: [EntityScriptBinding]
    /// A graph to preview when no entity-attached scripts exist (open asset / example).
    public let previewGraph: RCP3ScriptGraph?
    /// The entity the preview graph attaches to (else the scene root / a neutral box).
    public let previewEntityID: String?

    public init(
        scene: RCP3SceneNode?,
        scripts: [EntityScriptBinding],
        previewGraph: RCP3ScriptGraph?,
        previewEntityID: String?
    ) {
        self.scene = scene
        self.scripts = scripts
        self.previewGraph = previewGraph
        self.previewEntityID = previewEntityID
    }

    /// Whether there's anything to run.
    public var hasRunnable: Bool { !scripts.isEmpty || previewGraph != nil }

    /// A stable identity for the run that changes when the SET of running scripts
    /// changes — the host keys the Play view's `.id` on this so it rebuilds (and picks
    /// up a newly added/assigned graph) without rebuilding on unrelated edits.
    public var signature: String {
        let scriptSig = scripts
            .map { "\($0.entityID):\($0.graph.id ?? "g")" }
            .sorted()
            .joined(separator: "|")
        return "\(scene?.id ?? "none")#\(scriptSig)#\(previewEntityID ?? "")#\(previewGraph?.id ?? "")"
    }
}
