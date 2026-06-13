import Foundation
import RCP3Document
import TMFormat

/// Compiles a parsed `RCP3ScriptGraph` into JavaScript for `ScriptJSHost`.
///
/// RCP 3 runs its no-code script graphs as JavaScript. This is *our* clean-room JS
/// dialect that replicates the observed gesture→action pattern honestly — it is not
/// (yet) a claim to reproduce RCP's exact emitted source; that awaits a real
/// compiled-JS capture.
///
/// ## Recognized pattern: gesture → set-component
///
/// A `tm_gesture_event_drag` node exec-wired to a `tm_set_component` node, with a
/// data wire from the drag node into the set node's pin that resolves to
/// `translation`, decodes as *"on drag, move the entity by the drag delta."* It
/// emits:
///
/// ```js
/// entity.on("drag", (e) => {
///     const t = entity.transform.translation;
///     entity.transform.translation = [t[0]+e.delta[0], t[1]+e.delta[1], t[2]+e.delta[2]];
/// });
/// ```
///
/// Node types it does not understand emit `// unsupported node: <type>` — an honest
/// no-op rather than a fabricated behavior.
public struct ScriptGraphCompiler {
    public init() {}

    /// Pin hash for the `tm_set_component` `translation` input.
    static let translationPin = TMHash.murmur64a("translation")

    /// Emits JavaScript for `graph`. Unrecognized nodes become comment no-ops.
    public func compile(_ graph: RCP3ScriptGraph) -> String {
        var lines: [String] = []
        lines.append("// Compiled from RCP 3 script graph (\(graph.nodes.count) nodes).")

        var handledNodeIDs: Set<String> = []

        // Walk gesture-event nodes and try to emit a handler for each.
        for node in graph.nodes where Self.gestureEvent(for: node.type) != nil {
            guard let event = Self.gestureEvent(for: node.type) else { continue }
            handledNodeIDs.insert(node.id)

            // Follow exec wires out of the gesture node to action nodes.
            let execTargets = graph.wires
                .filter { $0.isExec && $0.from == node.id }
                .compactMap { wire in graph.node(id: wire.to) }

            var body: [String] = []
            for action in execTargets {
                handledNodeIDs.insert(action.id)
                if let statement = Self.actionStatement(
                    for: action,
                    gestureNode: node,
                    graph: graph
                ) {
                    body.append(statement)
                } else {
                    body.append("// unsupported node: \(action.type)")
                }
            }

            lines.append("entity.on(\(Self.jsString(event)), (e) => {")
            for statement in body {
                lines.append("    " + statement)
            }
            lines.append("});")
        }

        // Any node neither a recognized gesture nor reached as an action: honest no-op.
        for node in graph.nodes where !handledNodeIDs.contains(node.id) {
            lines.append("// unsupported node: \(node.type)")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Pattern recognition

    /// Maps a gesture-event node type to its dispatched event name, or `nil` if the
    /// type is not a recognized gesture event.
    static func gestureEvent(for type: String) -> String? {
        switch type {
        case "tm_gesture_event_drag": return "drag"
        case "tm_gesture_event_tap": return "tap"
        default: return nil
        }
    }

    /// JS for one action node fired by `gestureNode`, or `nil` when unrecognized.
    ///
    /// Recognizes `tm_set_component` with a data wire from the gesture node into the
    /// `translation` pin: move the transform by the gesture delta.
    static func actionStatement(
        for action: RCP3ScriptGraph.Node,
        gestureNode: RCP3ScriptGraph.Node,
        graph: RCP3ScriptGraph
    ) -> String? {
        guard action.type == "tm_set_component" else { return nil }

        // Is there a data wire from the gesture node into this node's `translation`
        // pin? That is the "set translation from the drag delta" wiring.
        let setsTranslation = graph.wires.contains { wire in
            !wire.isExec
                && wire.from == gestureNode.id
                && wire.to == action.id
                && wire.toPin == translationPin
        }
        guard setsTranslation else { return nil }

        // entity.transform.translation += e.delta
        return """
        const t = entity.transform.translation; \
        entity.transform.translation = [t[0]+e.delta[0], t[1]+e.delta[1], t[2]+e.delta[2]];
        """
    }

    // MARK: JS emission helpers

    /// A double-quoted, escaped JS string literal.
    static func jsString(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }
}
