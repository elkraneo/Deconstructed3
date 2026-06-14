import Foundation
import RCP3Document
import TMFormat

/// Compiles a parsed `RCP3ScriptGraph` into JavaScript for the **canonical
/// RealityKit Script Graph runtime** (the public `apple/RealityKitScripting`
/// package), i.e. the `String` you hand to `ScriptingComponent(source:)`.
///
/// This is the faithful counterpart to ``ScriptGraphCompiler`` (which targets our
/// own in-house JavaScriptCore preview host). Where that emits a private
/// `entity.on("drag", …)` dialect, this emits the **public package surface**: a
/// script whose lifecycle methods are assigned on `this`, whose entity is the
/// RealityKit `Entity` (`this.entity.position`, a `Math3D` vector), and whose
/// gesture handlers register against `RealityKit.DragGestureEvent.name`. That is
/// the form documented for the package and the shape the runtime executes.
///
/// ## Recognized pattern (the `Random` capture)
///
/// A drag gesture node (`tm_gesture_event_drag`) exec-wired to a
/// `tm_set_component` node, with a data wire into the set node's pin that resolves
/// to `translation`, means *"while dragging, set the entity's transform
/// translation to the world-space drag translation."* On the public surface, an
/// entity's transform translation **is** `entity.position`, so it emits:
///
/// ```js
/// const RealityKit = require("RealityKit");
/// const Math3D = require("Math3D");
/// this.didAdd = function() {
///   this.entity.setComponent(new RealityKit.InputTargetComponent());
///   this.entity.generateCollisionShapes(true);
///   let dragStart;
///   this.entity.on(RealityKit.DragGestureEvent.name, (e) => {
///     const event = e.event;
///     dragStart ??= event.entity.position.clone();
///     event.entity.position = Math3D.add(dragStart, event.sceneTranslation);
///     if (event.phase.equals(RealityKit.DragGestureEvent.Phase.ended)) dragStart = undefined;
///   });
/// };
/// ```
///
/// Node types it does not yet emit faithfully become `// unsupported node: <type>`
/// — an honest no-op rather than a fabricated behavior (the canonical surface for
/// those nodes is not yet pinned down here).
public struct CanonicalScriptGraphCompiler {
    public init() {}

    /// Pin hash for the `tm_set_component` `translation` input.
    static let translationPin = TMHash.murmur64a("translation")

    /// Emits the canonical-runtime JavaScript source for `graph`. The result is a
    /// complete script body suitable for `ScriptingComponent(source:)`.
    public func compile(_ graph: RCP3ScriptGraph) -> String {
        var lines: [String] = []
        lines.append("// Compiled from an RCP 3 script graph (\(graph.nodes.count) nodes)")
        lines.append("// for the RealityKit Script Graph runtime (ScriptingComponent source).")

        var handlerLines: [String] = []
        var handledNodeIDs: Set<String> = []

        // A drag gesture wired to a Set Transform translation = "drag the entity."
        for node in graph.nodes where node.type == "tm_gesture_event_drag" {
            guard Self.dragMovesTranslation(from: node, in: graph) else { continue }
            handledNodeIDs.insert(node.id)
            for wire in graph.wires where wire.isExec && wire.from == node.id {
                if let target = graph.node(id: wire.to), target.type == "tm_set_component" {
                    handledNodeIDs.insert(target.id)
                }
            }
            handlerLines.append(Self.dragToPositionHandler)
        }

        if !handlerLines.isEmpty {
            // The runtime exposes built-in modules through `require`; bind the ones our
            // handlers use BEFORE referencing them (the script has no `RealityKit` /
            // `Math3D` globals — referencing them unbound throws "Can't find variable").
            lines.append("const RealityKit = require(\"RealityKit\");")
            lines.append("const Math3D = require(\"Math3D\");")
            lines.append(contentsOf: handlerLines)
        }

        // Any node we didn't fold into a handler: honest no-op.
        for node in graph.nodes where !handledNodeIDs.contains(node.id) {
            lines.append("// unsupported node: \(node.type)")
        }

        if handlerLines.isEmpty {
            lines.append("// No canonical behavior emitted for this graph yet.")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Pattern recognition

    /// Whether `dragNode` exec-reaches a `tm_set_component` node that takes a data
    /// wire from the drag node into its `translation` pin — the "drag moves the
    /// transform translation" wiring.
    static func dragMovesTranslation(
        from dragNode: RCP3ScriptGraph.Node,
        in graph: RCP3ScriptGraph
    ) -> Bool {
        let setTargets = graph.wires
            .filter { $0.isExec && $0.from == dragNode.id }
            .compactMap { graph.node(id: $0.to) }
            .filter { $0.type == "tm_set_component" }

        return setTargets.contains { setNode in
            graph.wires.contains { wire in
                !wire.isExec
                    && wire.from == dragNode.id
                    && wire.to == setNode.id
                    && wire.toPin == translationPin
            }
        }
    }

    // MARK: Emission

    /// The canonical "drag the entity by the scene-space drag translation" handler,
    /// assigned on `this` as the package's lifecycle surface expects. The entity's
    /// transform translation is `entity.position` on this surface.
    static let dragToPositionHandler = """
    this.didAdd = function() {
        this.entity.setComponent(new RealityKit.InputTargetComponent());
        this.entity.generateCollisionShapes(true);
        let dragStart;
        this.entity.on(RealityKit.DragGestureEvent.name, (e) => {
            const event = e.event;
            dragStart ??= event.entity.position.clone();
            event.entity.position = Math3D.add(dragStart, event.sceneTranslation);
            if (event.phase.equals(RealityKit.DragGestureEvent.Phase.ended)) dragStart = undefined;
        });
    };
    """
}
