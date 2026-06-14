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
    @State private var model: ScriptGraphEditorModel

    /// Builds the editor for `graph`. `@MainActor` because `ScriptGraphEditorModel`
    /// is main-actor isolated; SwiftUI constructs views on the main actor, so
    /// callers already satisfy this.
    @MainActor
    public init(graph: RCP3ScriptGraph) {
        _model = State(initialValue: ScriptGraphEditorModel(graph: graph))
    }

    public var body: some View {
        ScriptGraphCanvasView(model: model)
    }
}
