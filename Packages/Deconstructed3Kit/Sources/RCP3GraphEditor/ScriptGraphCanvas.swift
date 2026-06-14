import SwiftUI
import SwiftFlow
import RCP3Document

/// A visual, pannable/zoomable node-graph view of an `RCP3ScriptGraph`, rendered
/// on a SwiftFlow canvas with RCP-styled nodes and exec/data wires.
///
/// This is the read-first MVP of the script-graph editor: it bridges the decoded
/// graph into a `FlowStore` (`ScriptGraphFlowBridge`) and draws each node with
/// `ScriptGraphNodeView`. Editing (moving nodes, connecting pins, a node palette)
/// builds on top of this — SwiftFlow already supports node dragging, pan/zoom, and
/// selection out of the box.
public struct ScriptGraphCanvas: View {
    @State private var store: FlowStore<ScriptGraphNodePayload>

    /// Builds the canvas for `graph`. `@MainActor` because `FlowStore` (and the
    /// bridge's `store(for:)`) are main-actor isolated; SwiftUI constructs views on
    /// the main actor, so callers already satisfy this.
    @MainActor
    public init(graph: RCP3ScriptGraph) {
        _store = State(initialValue: ScriptGraphFlowBridge.store(for: graph))
    }

    public var body: some View {
        FlowCanvas(store: store) { node, context in
            ScriptGraphNodeView(node: node, context: context)
        }
    }
}
