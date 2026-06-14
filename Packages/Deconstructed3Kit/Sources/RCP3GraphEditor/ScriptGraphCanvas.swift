import SwiftUI
import RCP3Document

/// A visual, interactive node-graph editor for an `RCP3ScriptGraph`.
///
/// This is the public entry the app hosts (`DocumentView`). It builds the
/// renderer-agnostic `ScriptGraphEditorModel` from the decoded graph and renders it
/// with the interactive SwiftUI **Canvas** editor (`ScriptGraphCanvasView`): drag
/// nodes, drag-to-connect ports, pan/zoom, select, and delete — with per-port
/// wiring that matches `ScriptGraphLayout` exactly. (This replaces the earlier
/// SwiftFlow-backed canvas, which could not give us per-port connection points.)
///
/// The public API is unchanged — `ScriptGraphCanvas(graph:)` — so callers don't
/// move.
public struct ScriptGraphCanvas: View {
    /// A model passed in by a host (`init(model:)`), which the host also keeps so it
    /// can read the live edits — e.g. to write them back on Save. `nil` for the
    /// self-owning `init(graph:)` path, where the model lives in `ownedModel` below.
    private let hostModel: ScriptGraphEditorModel?
    /// The self-owned model for `init(graph:)`. Held in `@State` so SwiftUI keeps the
    /// *same* instance across re-renders of a given view identity (edits persist);
    /// unused on the host-owned path.
    @State private var ownedModel: ScriptGraphEditorModel?

    /// The model this canvas renders: the host's when provided, else the self-owned
    /// one retained in `@State`.
    private var model: ScriptGraphEditorModel? { hostModel ?? ownedModel }

    /// Builds the editor for `graph`, owning the model internally. `@MainActor`
    /// because `ScriptGraphEditorModel` is main-actor isolated; SwiftUI constructs
    /// views on the main actor, so callers already satisfy this.
    @MainActor
    public init(graph: RCP3ScriptGraph) {
        self.hostModel = nil
        _ownedModel = State(initialValue: ScriptGraphEditorModel(graph: graph))
    }

    /// Builds the editor over a model the *host* owns, so the host can read the live
    /// edits (the write-back path: `ScriptGraphWriteBack.write(model:…)` on Save).
    /// The host is responsible for the model's lifetime (re-creating it when the open
    /// graph changes).
    @MainActor
    public init(model: ScriptGraphEditorModel) {
        self.hostModel = model
    }

    public var body: some View {
        if let model {
            ScriptGraphCanvasView(model: model)
        }
    }
}
