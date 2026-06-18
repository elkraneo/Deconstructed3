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
/// ## Architecture: a data-flow node → JS traversal
///
/// Rather than recognizing a single hard-coded wiring, this walks the graph as a
/// data-flow program:
///
/// 1. **Event handlers (exec roots).** Each gesture / lifecycle / update event node
///    becomes a `this.*` handler (`didAdd`, `update`, a `DragGestureEvent`
///    subscription, …). The compiler then follows the **exec** wires out of the
///    event node, in order, to its action nodes.
/// 2. **Action nodes → statements.** A `tm_set_component` writes the entity's
///    transform property (`translation` → `.position`, `rotation` → `.orientation`,
///    `scale` → `.scale`) from the *evaluated* expression feeding its pin. A
///    variable-set node becomes `this.setRemoteValue(...)`.
/// 3. **Data inputs → expressions.** The core is a recursive `emitExpression`: given
///    a data wire into a pin, it finds the source node + output pin and emits a JS
///    expression, recursively resolving *that* node's own data inputs. Gesture
///    outputs become `event.<pin>`; math constants become `Math.PI` / `Math.E` / …;
///    unary/binary math become `Math.sin(…)` / `(a + b)`; vector constructors become
///    `new Math3D.Vector3(…)`. A cycle guard and a depth bound keep it total.
///
/// ## Clean-room grounding
///
/// Emitted JS is grounded ONLY in the **public** `apple/realitykitscripting`
/// surface (the documented `RealityKit` / `Math3D` modules + the lifecycle/gesture
/// shapes in its `overview.md`) and in plain ECMAScript (`Math.*`, operators). The
/// only `Math3D` function name the public docs actually show is `Math3D.add` (used
/// by the reference drag handler) and the constructors `new Math3D.Vector3(…)` /
/// `new Math3D.Quaternion(…)`. Vector operations whose `Math3D` names are NOT
/// publicly documented (dot, cross, subtract, length, …) are emitted as plain-JS
/// fallbacks with an inline `/* … */` note rather than a fabricated `Math3D.*` call.
///
/// Node types with no faithful mapping become a `0 /* unsupported: <type> */`
/// expression (data) or a `// unsupported node: <type>` statement (action) — an
/// honest no-op rather than invented behavior.
public struct CanonicalScriptGraphCompiler {
    public init() {}

    /// Pin hash for the `tm_set_component` `translation` input.
    static let translationPin = TMHash.murmur64a("translation")
    static let rotationPin = TMHash.murmur64a("rotation")
    static let scalePin = TMHash.murmur64a("scale")
    static let unnamedExecPin = TMHash.murmur64a("")
    static let alwaysPin = TMHash.murmur64a("always")
    static let truePin = TMHash.murmur64a("true")
    static let falsePin = TMHash.murmur64a("false")
    static let stepPin = TMHash.murmur64a("step")
    static let endPin = TMHash.murmur64a("end")
    static let oncePin = TMHash.murmur64a("once")
    static let indexPin = TMHash.murmur64a("index")
    static let cancelIDPin = TMHash.murmur64a("cancelID")

    /// The stable per-script instance-property slot for a LOCAL variable referenced by
    /// `name`: `variable_<MurmurHash64A(lowercase(name), seed 0)>` with the hash
    /// rendered as a DECIMAL `UInt64`. A Get reads `this.<slot>`, a Set assigns it, so
    /// a Get and a Set of the same name always resolve to the same property.
    static func variableSlot(for name: String) -> String {
        "variable_\(TMHash.murmur64a(name.lowercased()))"
    }

    /// Emits the canonical-runtime JavaScript source for `graph`. The result is a
    /// complete script body suitable for `ScriptingComponent(source:)`.
    public func compile(_ graph: RCP3ScriptGraph) -> String {
        var emitter = Emitter(graph: graph)
        return emitter.compile()
    }

    // MARK: - Emitter

    /// A single compilation pass. Mutable so the recursive expression evaluator can
    /// record which modules it used (`usesMath3D`) and guard against cycles.
    private struct Emitter {
        let graph: RCP3ScriptGraph

        /// Set when an emitted expression referenced the `Math3D` module, so the
        /// header binds it only when needed.
        var usesMath3D = false
        /// Set when an emitted statement/handler referenced the `RealityKit` module.
        var usesRealityKit = false
        /// Nodes folded into a handler/statement, so leftovers become honest no-ops.
        var handledNodeIDs: Set<String> = []

        init(graph: RCP3ScriptGraph) { self.graph = graph }

        mutating func compile() -> String {
            var header: [String] = []
            header.append("// Compiled from an RCP 3 script graph (\(graph.nodes.count) nodes)")
            header.append("// for the RealityKit Script Graph runtime (ScriptingComponent source).")

            // 1. Emit a handler for every event (exec-root) node.
            var handlerBlocks: [String] = []
            for node in graph.nodes where Self.eventKind(for: node.type) != nil {
                guard let block = emitHandler(for: node) else { continue }
                handlerBlocks.append(block)
            }

            // 2. The runtime exposes built-in modules through `require`; bind only the
            //    ones our emitted code actually used, BEFORE referencing them (the
            //    script has no `RealityKit` / `Math3D` globals — an unbound reference
            //    throws "Can't find variable").
            var lines = header
            if usesRealityKit { lines.append("const RealityKit = require(\"RealityKit\");") }
            if usesMath3D { lines.append("const Math3D = require(\"Math3D\");") }
            lines.append(contentsOf: handlerBlocks)

            // 3. Any node we did not fold into a handler: honest no-op.
            var sawUnhandled = false
            for node in graph.nodes where !handledNodeIDs.contains(node.id) {
                lines.append("// unsupported node: \(node.type)")
                sawUnhandled = true
            }

            if handlerBlocks.isEmpty && !sawUnhandled {
                lines.append("// No canonical behavior emitted for this graph yet.")
            }

            return lines.joined(separator: "\n") + "\n"
        }

        // MARK: Event handlers (exec roots)

        /// The kind of lifecycle/event a node type maps to, or `nil` if it is not an
        /// exec-root event node.
        enum EventKind {
            case drag
            case tap
            /// A `this.update = function(deltaTime){…}` per-frame hook.
            case update
            /// A `this.<name> = function(){…}` lifecycle hook (didAdd, …).
            case lifecycle(String)
        }

        static func eventKind(for type: String) -> EventKind? {
            switch type {
            case "tm_gesture_event_drag": return .drag
            case "tm_gesture_event_tap": return .tap
            case "tm_update": return .update
            case "tm_did_add": return .lifecycle("didAdd")
            case "tm_did_activate": return .lifecycle("didActivate")
            case "tm_will_remove": return .lifecycle("willRemove")
            case "tm_will_deactivate": return .lifecycle("willDeactivate")
            case "tm_script_changed": return .lifecycle("scriptChanged")
            default: return nil
            }
        }

        /// Emits the `this.*` handler for an event node, folding its exec-reachable
        /// action nodes into the body. The expression context (`exprContext`)
        /// determines how gesture-output pins resolve (`event.*` inside a gesture
        /// handler, otherwise unavailable).
        mutating func emitHandler(for node: RCP3ScriptGraph.Node) -> String? {
            guard let kind = Self.eventKind(for: node.type) else { return nil }
            handledNodeIDs.insert(node.id)

            switch kind {
            case .drag:
                return emitDragHandler(for: node)
            case .tap:
                return emitTapHandler(for: node)
            case .update:
                let body = emitActionBody(after: node, context: .update)
                return emitFunctionHandler(name: "update", params: "deltaTime", body: body, logEvent: "update")
            case .lifecycle(let name):
                let body = emitActionBody(after: node, context: .lifecycle)
                return emitFunctionHandler(name: name, params: "", body: body, logEvent: name)
            }
        }

        /// `this.<name> = function(<params>) { <body> };`, with a ONE-TIME `console.log`
        /// at the body entry so the in-app console (Apple's RealityKitScripting log
        /// stream) shows the handler fired without flooding — critical for `update`,
        /// which runs every frame, so the log is guarded by a per-handler instance flag.
        func emitFunctionHandler(name: String, params: String, body: [String], logEvent: String) -> String {
            var lines = ["this.\(name) = function(\(params)) {"]
            for statement in Self.handlerEntryLog(logEvent) { lines.append("    " + statement) }
            for statement in body { lines.append("    " + statement) }
            lines.append("};")
            return lines.joined(separator: "\n")
        }

        /// A ONE-TIME, instance-flag-guarded `console.log` for the entry of an event
        /// handler body. The flag (`this.__d3_log_<event>`) makes each handler log
        /// exactly once even when the handler runs every frame (`update`) — the log is
        /// purely additive (no behavior change). Returns the guard's lines, indented by
        /// the caller.
        static func handlerEntryLog(_ event: String) -> [String] {
            let flag = "__d3_log_\(sanitize(event))"
            return [
                "if (!this.\(flag)) { this.\(flag) = true; console.log(\"[D3] \(event) fired\"); }"
            ]
        }

        /// A JS-identifier-safe rendering of an arbitrary id/name (for an instance-flag
        /// suffix): any non-alphanumeric character becomes `_`, so the resulting flag
        /// `this.__d3_log_<suffix>` is always a valid property name.
        static func sanitize(_ raw: String) -> String {
            String(raw.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        }

        /// The canonical drag handler. Keeps the input-target + collision setup and the
        /// `dragStart` clamp; the body wires the entity transform from the action nodes
        /// the drag node exec-reaches (the recognized `translation` move stays exact).
        mutating func emitDragHandler(for node: RCP3ScriptGraph.Node) -> String {
            usesRealityKit = true
            let body = emitActionBody(after: node, context: .gesture)

            // The recognized "drag moves translation" wiring: the drag node feeds its
            // `sceneTranslation` straight into a Set Transform `translation`. That is the
            // documented reference handler — emit it verbatim so the captured graph keeps
            // producing the exact, working drag.
            if CanonicalScriptGraphCompiler.dragMovesTranslation(from: node, in: graph) {
                usesMath3D = true
                for wire in graph.wires where wire.isExec && wire.from == node.id {
                    if let target = graph.node(id: wire.to), target.type == "tm_set_component" {
                        handledNodeIDs.insert(target.id)
                    }
                }
                return CanonicalScriptGraphCompiler.dragToPositionHandler
            }

            var lines = ["this.didAdd = function() {"]
            lines.append("    this.entity.setComponent(new RealityKit.InputTargetComponent());")
            lines.append("    this.entity.generateCollisionShapes(true);")
            lines.append("    this.entity.on(RealityKit.DragGestureEvent.name, (e) => {")
            lines.append("        const event = e.event;")
            for statement in Self.handlerEntryLog("drag") { lines.append("        " + statement) }
            for statement in body { lines.append("        " + statement) }
            lines.append("    });")
            lines.append("};")
            return lines.joined(separator: "\n")
        }

        /// The canonical tap handler: same input-target + collision setup, subscribing
        /// against `RealityKit.TapGestureEvent.name`.
        mutating func emitTapHandler(for node: RCP3ScriptGraph.Node) -> String {
            usesRealityKit = true
            let body = emitActionBody(after: node, context: .gesture)
            var lines = ["this.didAdd = function() {"]
            lines.append("    this.entity.setComponent(new RealityKit.InputTargetComponent());")
            lines.append("    this.entity.generateCollisionShapes(true);")
            lines.append("    this.entity.on(RealityKit.TapGestureEvent.name, (e) => {")
            lines.append("        const event = e.event;")
            for statement in Self.handlerEntryLog("tap") { lines.append("        " + statement) }
            for statement in body { lines.append("        " + statement) }
            lines.append("    });")
            lines.append("};")
            return lines.joined(separator: "\n")
        }

        // MARK: Action nodes → statements

        /// Walks the exec wires out of `node`, in graph order, emitting one statement
        /// per action node reached.
        mutating func emitActionBody(
            after node: RCP3ScriptGraph.Node,
            context: ExprContext,
            outputPin: UInt64? = nil
        ) -> [String] {
            var statements: [String] = []
            for wire in execWires(from: node, outputPin: outputPin) {
                guard let action = graph.node(id: wire.to) else { continue }
                if handledNodeIDs.contains(action.id) { continue }
                handledNodeIDs.insert(action.id)
                statements.append(contentsOf: emitActionStatements(for: action, context: context))
                // Chain any exec wires out of the action node (a linear action chain).
                if !Self.handlesOwnControlFlow(action.type) {
                    statements.append(contentsOf: emitActionBody(after: action, context: context))
                }
            }
            return statements
        }

        /// JS statements for a single action node.
        mutating func emitActionStatements(
            for node: RCP3ScriptGraph.Node,
            context: ExprContext
        ) -> [String] {
            switch node.type {
            case "tm_set_component":
                return emitSetComponent(node, context: context)
            case "tm_set_variable_node", "tm_set_remote_variable_node":
                return emitSetVariable(node, context: context)
            case "tm_clear_variable_node", "tm_clear_remote_variable_node":
                return emitClearVariable(node)
            case "tm_sequence":
                return emitSequence(node, context: context)
            case "tm_if":
                return emitIf(node, context: context)
            case "tm_switch":
                return emitSwitch(node, context: context)
            case "tm_loop":
                return emitLoop(node, context: context)
            case "tm_delay":
                return emitDelay(node, context: context)
            case "tm_cancel_delay":
                return emitCancelDelay(node, context: context)
            case "tm_do_once":
                return emitDoOnce(node, context: context)
            default:
                return ["// unsupported node: \(node.type)"]
            }
        }

        static func handlesOwnControlFlow(_ type: String) -> Bool {
            switch type {
            case "tm_sequence", "tm_if", "tm_switch", "tm_loop", "tm_delay", "tm_do_once":
                return true
            default:
                return false
            }
        }

        func execWires(from node: RCP3ScriptGraph.Node, outputPin: UInt64? = nil) -> [RCP3ScriptGraph.Wire] {
            graph.wires
                .filter { wire in
                    guard wire.from == node.id, isExecWire(wire, from: node) else { return false }
                    guard let outputPin else { return true }
                    return wire.fromPin == outputPin || (wire.fromPin == nil && outputPin == CanonicalScriptGraphCompiler.unnamedExecPin)
                }
                .sorted { lhs, rhs in
                    let left = lhs.fromPin ?? 0
                    let right = rhs.fromPin ?? 0
                    if left == right { return lhs.id < rhs.id }
                    return left < right
                }
        }

        func isExecWire(_ wire: RCP3ScriptGraph.Wire, from node: RCP3ScriptGraph.Node) -> Bool {
            if wire.isExec { return true }
            switch node.type {
            case "tm_sequence", "tm_switch":
                return wire.fromPin != nil
            case "tm_if":
                return [CanonicalScriptGraphCompiler.alwaysPin, CanonicalScriptGraphCompiler.truePin, CanonicalScriptGraphCompiler.falsePin].contains(wire.fromPin)
            case "tm_loop":
                return [CanonicalScriptGraphCompiler.stepPin, CanonicalScriptGraphCompiler.endPin].contains(wire.fromPin)
            case "tm_delay":
                return [CanonicalScriptGraphCompiler.alwaysPin, CanonicalScriptGraphCompiler.oncePin].contains(wire.fromPin)
            case "tm_do_once":
                return [CanonicalScriptGraphCompiler.alwaysPin, CanonicalScriptGraphCompiler.oncePin].contains(wire.fromPin)
            case "tm_cancel_delay":
                return wire.fromPin == CanonicalScriptGraphCompiler.unnamedExecPin
            default:
                return wire.fromPin == nil
            }
        }

        mutating func emitSequence(_ node: RCP3ScriptGraph.Node, context: ExprContext) -> [String] {
            var statements: [String] = []
            for wire in execWires(from: node) {
                guard let action = graph.node(id: wire.to), !handledNodeIDs.contains(action.id) else { continue }
                handledNodeIDs.insert(action.id)
                statements.append(contentsOf: emitActionStatements(for: action, context: context))
                if !Self.handlesOwnControlFlow(action.type) {
                    statements.append(contentsOf: emitActionBody(after: action, context: context))
                }
            }
            return statements
        }

        mutating func emitIf(_ node: RCP3ScriptGraph.Node, context: ExprContext) -> [String] {
            var seen: Set<String> = []
            let condition = inputExpression(into: node, pinName: "condition", context: context, seen: &seen).code
            var statements = emitActionBody(after: node, context: context, outputPin: CanonicalScriptGraphCompiler.alwaysPin)
            let trueBody = emitActionBody(after: node, context: context, outputPin: CanonicalScriptGraphCompiler.truePin)
            let falseBody = emitActionBody(after: node, context: context, outputPin: CanonicalScriptGraphCompiler.falsePin)
            statements.append("if (\(condition)) {")
            statements.append(contentsOf: Self.indent(trueBody.isEmpty ? ["// no-op"] : trueBody))
            statements.append("} else {")
            statements.append(contentsOf: Self.indent(falseBody.isEmpty ? ["// no-op"] : falseBody))
            statements.append("}")
            return statements
        }

        mutating func emitSwitch(_ node: RCP3ScriptGraph.Node, context: ExprContext) -> [String] {
            var seen: Set<String> = []
            let condition = inputExpression(into: node, pinName: "condition", context: context, seen: &seen).code
            let first = inputExpression(into: node, pinName: "first", context: context, seen: &seen).code
            let outputs = execWires(from: node)
            guard !outputs.isEmpty else { return ["switch (\(condition)) {", "}"] }
            var statements = ["switch (\(condition)) {"]
            for (offset, wire) in outputs.dropLast().enumerated() {
                let body = emitSwitchBody(for: wire, context: context)
                statements.append("case (\(first) + \(offset)):")
                statements.append(contentsOf: Self.indent(body.isEmpty ? ["break;"] : body.map { $0 == "break;" ? $0 : $0 }))
                if body.last != "break;" { statements.append("    break;") }
            }
            if let fallback = outputs.last {
                let body = emitSwitchBody(for: fallback, context: context)
                statements.append("default:")
                statements.append(contentsOf: Self.indent(body.isEmpty ? ["break;"] : body))
                if body.last != "break;" { statements.append("    break;") }
            }
            statements.append("}")
            return statements
        }

        mutating func emitSwitchBody(for wire: RCP3ScriptGraph.Wire, context: ExprContext) -> [String] {
            guard let action = graph.node(id: wire.to), !handledNodeIDs.contains(action.id) else { return [] }
            handledNodeIDs.insert(action.id)
            var body = emitActionStatements(for: action, context: context)
            if !Self.handlesOwnControlFlow(action.type) {
                body.append(contentsOf: emitActionBody(after: action, context: context))
            }
            return body
        }

        mutating func emitLoop(_ node: RCP3ScriptGraph.Node, context: ExprContext) -> [String] {
            var seen: Set<String> = []
            let begin = inputExpression(into: node, pinName: "begin", context: context, seen: &seen).code
            let end = inputExpression(into: node, pinName: "end", context: context, seen: &seen).code
            let step = inputExpression(into: node, pinName: "step", context: context, seen: &seen, defaultValue: Expr("1")).code
            let inclusive = inputExpression(into: node, pinName: "inclusive", context: context, seen: &seen).code
            let index = Self.loopIndexName(for: node)
            let stepBody = emitActionBody(after: node, context: context, outputPin: CanonicalScriptGraphCompiler.stepPin)
            let condition = "((\(step)) >= 0 ? (\(inclusive) ? \(index) <= (\(end)) : \(index) < (\(end))) : (\(inclusive) ? \(index) >= (\(end)) : \(index) > (\(end))))"
            var statements = [
                "for (let \(index) = \(begin); \(condition); \(index) += (\(step))) {"
            ]
            statements.append(contentsOf: Self.indent(stepBody.isEmpty ? ["// no-op"] : stepBody))
            statements.append("}")
            statements.append(contentsOf: emitActionBody(after: node, context: context, outputPin: CanonicalScriptGraphCompiler.endPin))
            return statements
        }

        mutating func emitDelay(_ node: RCP3ScriptGraph.Node, context: ExprContext) -> [String] {
            var seen: Set<String> = []
            let seconds = inputExpression(into: node, pinName: "seconds", context: context, seen: &seen).code
            let unique = inputExpression(into: node, pinName: "is unique", context: context, seen: &seen).code
            let helper = "__d3_delay_\(Self.sanitize(node.id))"
            let slot = Self.delayCancelSlot(for: node)
            let onceBody = emitActionBody(after: node, context: context, outputPin: CanonicalScriptGraphCompiler.oncePin)
            let alwaysBody = emitActionBody(after: node, context: context, outputPin: CanonicalScriptGraphCompiler.alwaysPin)
            var statements = ["const \(helper) = (s, unique) => {"]
            statements.append("    if (unique && this.\(slot)) { this.clearTimeout(this.\(slot)); }")
            statements.append("    this.\(slot) = this.setTimeout(() => {")
            statements.append(contentsOf: Self.indent(onceBody.isEmpty ? ["// no-op"] : onceBody, by: "        "))
            statements.append("    }, s * 1000);")
            statements.append(contentsOf: Self.indent(alwaysBody, by: "    "))
            statements.append("};")
            statements.append("\(helper)(\(seconds), \(unique));")
            return statements
        }

        mutating func emitCancelDelay(_ node: RCP3ScriptGraph.Node, context: ExprContext) -> [String] {
            var seen: Set<String> = []
            let cancelID = inputExpression(into: node, pinName: "cancelID", context: context, seen: &seen).code
            return ["this.clearTimeout(\(cancelID));"]
        }

        mutating func emitDoOnce(_ node: RCP3ScriptGraph.Node, context: ExprContext) -> [String] {
            let slot = "__d3_once_\(Self.sanitize(node.id))"
            var statements = emitActionBody(after: node, context: context, outputPin: CanonicalScriptGraphCompiler.alwaysPin)
            let onceBody = emitActionBody(after: node, context: context, outputPin: CanonicalScriptGraphCompiler.oncePin)
            statements.append("if (!this.\(slot)) {")
            statements.append(contentsOf: Self.indent(onceBody.isEmpty ? ["// no-op"] : onceBody))
            statements.append("    this.\(slot) = true;")
            statements.append("}")
            return statements
        }

        static func indent(_ lines: [String], by prefix: String = "    ") -> [String] {
            lines.map { prefix + $0 }
        }

        static func loopIndexName(for node: RCP3ScriptGraph.Node) -> String {
            "__d3_index_\(sanitize(node.id))"
        }

        static func delayCancelSlot(for node: RCP3ScriptGraph.Node) -> String {
            "__d3_cancel_\(sanitize(node.id))"
        }

        /// A Set Component (Transform) action: write the entity transform property fed
        /// by a data wire — `translation` → `.position`, `rotation` → `.orientation`,
        /// `scale` → `.scale`. The value is the recursively-evaluated source expression.
        mutating func emitSetComponent(
            _ node: RCP3ScriptGraph.Node,
            context: ExprContext
        ) -> [String] {
            let target = context == .gesture ? "event.entity" : "this.entity"
            var statements: [String] = []

            for (pin, property) in [
                (CanonicalScriptGraphCompiler.translationPin, "position"),
                (CanonicalScriptGraphCompiler.rotationPin, "orientation"),
                (CanonicalScriptGraphCompiler.scalePin, "scale"),
            ] {
                guard let wire = dataWire(into: node.id, pin: pin) else { continue }
                var seen: Set<String> = []
                let expr = emitExpression(from: wire, context: context, seen: &seen)
                // A ONE-TIME log of the property + value, guarded by a unique per-set flag
                // so a per-frame `update` set logs exactly once. The flag suffix is the
                // sanitized set-node id + property, so a set that writes more than one
                // property logs each once. The assignment below stays UNGUARDED (it must
                // run every frame); only the log is once-guarded. The value is rendered by
                // string-concatenation (`"" + (expr)`).
                let flag = "__d3_log_set_\(Self.sanitize(node.id))_\(property)"
                statements.append(
                    "if (!this.\(flag)) { this.\(flag) = true; console.log(\"[D3] set \(property) = \" + (\(expr.code))); }"
                )
                statements.append("\(target).\(property) = \(expr.code);")
            }

            if statements.isEmpty {
                statements.append("// unsupported node: tm_set_component (no transform input wired)")
            }
            return statements
        }

        /// A variable-set action. A LOCAL variable (the node carries a `variableName`)
        /// writes the stable per-script instance-property slot:
        /// `this.variable_<slot> = <valueExpr>;`. Without a name (the on-disk reference
        /// isn't resolvable from the wire graph alone) it falls back to the honest
        /// remote-value placeholder. The value expression is faithfully resolved either
        /// way.
        mutating func emitSetVariable(
            _ node: RCP3ScriptGraph.Node,
            context: ExprContext
        ) -> [String] {
            let valuePin = TMHash.murmur64a("value")
            let valueExpr: String
            if let wire = dataWire(into: node.id, pin: valuePin) {
                var seen: Set<String> = []
                valueExpr = emitExpression(from: wire, context: context, seen: &seen).code
            } else if let value = graph.scalarLiteral(node: node.id, pin: valuePin) {
                valueExpr = Self.renderScalar(value)
            } else {
                valueExpr = "undefined /* no value wired */"
            }
            if let name = node.variableName {
                let slot = CanonicalScriptGraphCompiler.variableSlot(for: name)
                return ["this.\(slot) = \(valueExpr);"]
            }
            // No resolvable name → honest remote-value placeholder rather than fabricated.
            return [
                "this.setRemoteValue(/* variable name unresolved */ \"\", \(valueExpr));"
            ]
        }

        /// A variable-clear action. A LOCAL variable resets its slot to the numeric
        /// default: `this.variable_<slot> = 0;`. Without a name it stays an honest no-op.
        func emitClearVariable(_ node: RCP3ScriptGraph.Node) -> [String] {
            if let name = node.variableName {
                let slot = CanonicalScriptGraphCompiler.variableSlot(for: name)
                return ["this.\(slot) = 0;"]
            }
            return ["// unsupported node: \(node.type) (variable-name reference not resolvable here)"]
        }

        // MARK: Data inputs → expressions (the recursive core)

        /// An emitted JS expression plus a lightweight "is this a VECTOR?" bit. The bit
        /// is the minimal type inference needed to keep vector math honest: JS `+` is NOT
        /// `Math3D.Vector3` addition (it coerces to a string / `NaN`), so a `tm_math_add`
        /// over vectors must lower to the documented `Math3D.add(a, b)`, while a scalar add
        /// stays the plain `(a + b)` operator. We infer the bit at the leaves (vector
        /// constructors, gesture translation/location outputs, transform reads) and
        /// propagate it through binary math (vector iff any operand is a vector).
        struct Expr {
            var code: String
            var isVector: Bool

            init(_ code: String, isVector: Bool = false) {
                self.code = code
                self.isVector = isVector
            }
        }

        /// Where an expression is being emitted, which decides how a gesture-output pin
        /// resolves.
        enum ExprContext {
            /// Inside a gesture handler: gesture outputs are `event.<pin>`.
            case gesture
            /// Inside `this.update(deltaTime)`: `deltaTime` is in scope.
            case update
            /// Inside a plain lifecycle hook: no gesture/update locals in scope.
            case lifecycle
        }

        /// The data wire feeding `pin` of node `nodeID`, if any.
        func dataWire(into nodeID: String, pin: UInt64) -> RCP3ScriptGraph.Wire? {
            graph.wires.first { !$0.isExec && $0.to == nodeID && $0.toPin == pin }
        }

        /// Emits a JS expression for the value carried by a data `wire` — i.e. the
        /// output `wire.fromPin` of the source node `wire.from`, recursively resolving
        /// that node's own inputs. `seen` guards against cycles.
        mutating func emitExpression(
            from wire: RCP3ScriptGraph.Wire,
            context: ExprContext,
            seen: inout Set<String>
        ) -> Expr {
            guard let source = graph.node(id: wire.from) else {
                return Expr("undefined /* dangling wire */")
            }
            return emitExpression(
                forNode: source,
                outputPin: wire.fromPin,
                context: context,
                seen: &seen
            )
        }

        /// The expression for a node's output. Recursively resolves the node's data
        /// inputs. `seen` is the cycle guard (a node already on the current resolution
        /// path yields a safe `0`).
        mutating func emitExpression(
            forNode node: RCP3ScriptGraph.Node,
            outputPin: UInt64?,
            context: ExprContext,
            seen: inout Set<String>
        ) -> Expr {
            if seen.contains(node.id) {
                return Expr("0 /* cycle: \(node.type) */")
            }
            seen.insert(node.id)
            defer { seen.remove(node.id) }

            // A data node folded into an expression is "handled" — it should not also
            // surface as a leftover `// unsupported node` no-op. (Event nodes are folded
            // as exec roots elsewhere, so we don't mark them here.)
            handledNodeIDs.insert(node.id)

            // Gesture event outputs read off `event.<pinName>` inside a gesture handler.
            if Self.eventKind(for: node.type) != nil {
                return gestureOutputExpression(node, outputPin: outputPin, context: context)
            }

            if node.type == "tm_loop", outputPin == CanonicalScriptGraphCompiler.indexPin {
                return Expr(Self.loopIndexName(for: node))
            }

            if node.type == "tm_delay", outputPin == CanonicalScriptGraphCompiler.cancelIDPin {
                return Expr("this.\(Self.delayCancelSlot(for: node))")
            }

            // Math constants are scalars.
            if let constant = Self.mathConstant(for: node.type) {
                return Expr(constant)
            }

            // `tm_constant` literal: the value is node settings, not a wire — emit 0.
            if node.type == "tm_constant" {
                return Expr("0 /* tm_constant literal (value in node settings) */")
            }

            // Unary Math.* (plain JS — runs anywhere). Always scalar.
            if let fn = Self.unaryMathFunction(for: node.type) {
                let a = inputExpression(into: node, pinName: "a", context: context, seen: &seen)
                return Expr("\(fn)(\(a.code))")
            }

            // Binary math. Scalar operands keep the plain-JS operator / `Math.*` call. But
            // JS `+`/`-`/`*` are NOT vector operations, so when an operand is a VECTOR we
            // must lower an add to the documented `Math3D.add(a, b)`, and keep the result
            // typed as a vector so it propagates up the expression tree.
            if let op = Self.binaryScalarOperator(for: node.type) {
                let a = inputExpression(into: node, pinName: "a", context: context, seen: &seen)
                let bName = node.type == "tm_math_pow" ? "exponent" : "b"
                let b = inputExpression(into: node, pinName: bName, context: context, seen: &seen)
                return emitBinaryMath(node.type, op: op, a: a, b: b)
            }

            // Comparison nodes (scalar → bool). The library names the operands `a`/`b`
            // and the output `result`; we lower to the obvious infix comparison. Result
            // is a scalar (boolean).
            if let cmp = Self.comparisonOperator(for: node.type) {
                let a = inputExpression(into: node, pinName: "a", context: context, seen: &seen)
                let b = inputExpression(into: node, pinName: "b", context: context, seen: &seen)
                return Expr("(\(a.code) \(cmp) \(b.code))")
            }

            // Within-range (scalar → bool). The library's pins are `val`/`min`/`max`.
            // Implemented as the obvious INCLUSIVE form `(val >= min && val <= max)`
            // (best-effort: the inclusive/exclusive boundary semantics are not pinned
            // down by the library).
            if node.type == "tm_math_within_range" {
                let v = inputExpression(into: node, pinName: "val", context: context, seen: &seen)
                let lo = inputExpression(into: node, pinName: "min", context: context, seen: &seen)
                let hi = inputExpression(into: node, pinName: "max", context: context, seen: &seen)
                return Expr("(\(v.code) >= \(lo.code) && \(v.code) <= \(hi.code))")
            }

            // Random (scalar). The library declares `min`/`max` pins, so we emit the
            // ranged form `min + Math.random() * (max - min)`; when neither is wired the
            // operands fall back to 0, collapsing to the unit `Math.random()` range.
            // (Best-effort: the exact inclusivity / distribution isn't pinned down.)
            if node.type == "tm_math_random" {
                let lo = inputExpression(into: node, pinName: "min", context: context, seen: &seen)
                let hi = inputExpression(into: node, pinName: "max", context: context, seen: &seen)
                return Expr("(\(lo.code) + Math.random() * (\(hi.code) - \(lo.code)))")
            }

            // Logic reducers (→ bool). Variadic (`a`, `b`, `c`, …); fold all wired/seeded
            // operand pins with the same operator. The library seeds `a`/`b`; we also fold
            // any further single-letter operand pins that carry a wire or literal.
            if let logic = Self.logicOperator(for: node.type) {
                let operands = logicOperands(of: node, context: context, seen: &seen)
                return Expr("(\(operands.joined(separator: " \(logic) ")))")
            }

            // Bitwise binary (scalar). Operands `a`/`b`, infix bitwise operator.
            if let bit = Self.bitwiseBinaryOperator(for: node.type) {
                let a = inputExpression(into: node, pinName: "a", context: context, seen: &seen)
                let b = inputExpression(into: node, pinName: "b", context: context, seen: &seen)
                return Expr("(\(a.code) \(bit) \(b.code))")
            }

            // Bitwise NOT (unary, scalar). Operand `a`.
            if node.type == "tm_math_bitwise_not" {
                let a = inputExpression(into: node, pinName: "a", context: context, seen: &seen)
                return Expr("(~\(a.code))")
            }

            // Degree/radian conversion (scalar). The library names the input `degrees`
            // (deg→rad) / `rad` (rad→deg).
            if node.type == "tm_math_deg_to_rad" {
                let x = inputExpression(into: node, pinName: "degrees", context: context, seen: &seen)
                return Expr("((\(x.code)) * Math.PI / 180)")
            }
            if node.type == "tm_math_rad_to_deg" {
                let x = inputExpression(into: node, pinName: "rad", context: context, seen: &seen)
                return Expr("((\(x.code)) * 180 / Math.PI)")
            }

            if node.type == "tm_make_rotation" {
                usesMath3D = true
                let angle = inputExpression(
                    into: node,
                    pinName: "angle",
                    context: context,
                    seen: &seen,
                    defaultValue: Expr("0")
                )
                let axis = inputExpression(
                    into: node,
                    pinName: "axis",
                    context: context,
                    seen: &seen,
                    defaultValue: Expr("new Math3D.Vector3(0, 1, 0)", isVector: true)
                )
                return Expr("new Math3D.Quaternion(\(angle.code), \(axis.code))", isVector: true)
            }

            if node.type == "tm_math_euler_to_quaternion" {
                usesMath3D = true
                let angles = inputExpression(into: node, pinName: "angles", context: context, seen: &seen)
                return Expr("Math3D.eulerAnglesToQuaternion(\(angles.code))", isVector: true)
            }

            if node.type == "tm_math_quaternion_to_euler" {
                usesMath3D = true
                let quaternion = inputExpression(into: node, pinName: "quaternion", context: context, seen: &seen)
                return Expr("Math3D.quaternionToEulerAngles(\(quaternion.code))", isVector: true)
            }

            // String predicates / accessors (→ bool / number / string). The library's
            // first input pin is `string`; the arg pin name varies by node.
            if let stringExpr = emitStringExpression(node, context: context, seen: &seen) {
                return stringExpr
            }

            // Vector constructors are the canonical VECTOR leaf.
            if node.type == "tm_make_vector3" {
                usesMath3D = true
                let x = inputExpression(into: node, pinName: "x", context: context, seen: &seen)
                let y = inputExpression(into: node, pinName: "y", context: context, seen: &seen)
                let z = inputExpression(into: node, pinName: "z", context: context, seen: &seen)
                return Expr("new Math3D.Vector3(\(x.code), \(y.code), \(z.code))", isVector: true)
            }

            // Vector2 / Vector4 constructors mirror Vector3: component pins with a
            // scalar-literal `?? default` fallback for unwired components, typed VECTOR.
            if node.type == "tm_make_vector2" {
                usesMath3D = true
                let x = inputExpression(into: node, pinName: "x", context: context, seen: &seen)
                let y = inputExpression(into: node, pinName: "y", context: context, seen: &seen)
                return Expr("new Math3D.Vector2(\(x.code), \(y.code))", isVector: true)
            }
            if node.type == "tm_make_vector4" {
                usesMath3D = true
                let x = inputExpression(into: node, pinName: "x", context: context, seen: &seen)
                let y = inputExpression(into: node, pinName: "y", context: context, seen: &seen)
                let z = inputExpression(into: node, pinName: "z", context: context, seen: &seen)
                let w = inputExpression(into: node, pinName: "w", context: context, seen: &seen)
                return Expr("new Math3D.Vector4(\(x.code), \(y.code), \(z.code), \(w.code))", isVector: true)
            }

            // Vector ops whose Math3D names are NOT publicly documented: keep clean-room
            // by emitting a plain-JS fallback with an honest note rather than inventing a
            // `Math3D.*` name. The op is over vectors, so the result is typed as a vector.
            if Self.isUndocumentedVectorOp(node.type) {
                let a = inputExpression(into: node, pinName: "a", context: context, seen: &seen)
                let b = inputExpression(into: node, pinName: "b", context: context, seen: &seen)
                _ = b // referenced for completeness; fallback can't compute it portably
                return Expr(
                    "\(a.code) /* unsupported: \(node.type) (Math3D op name not public) */",
                    isVector: true
                )
            }

            // Get Component (Transform): read the entity transform property named by the
            // OUTPUT pin — the exact inverse of the Set Component mapping above
            // (`translation` → `.position`, `rotation` → `.orientation`, `scale` →
            // `.scale`). The entity is `event.entity` inside a gesture handler, else
            // `this.entity` — same target rule as Set. The property pins are the same
            // faithful `translation`/`rotation`/`scale` connectors the library declares.
            if node.type == "tm_get_component" {
                return getComponentExpression(outputPin: outputPin, context: context)
            }

            // Variable get. A LOCAL variable (the node carries a `variableName`) reads the
            // stable per-script slot, guarded with `?? 0` so an uninitialized accumulator's
            // first read is the numeric default rather than `undefined` → NaN. The slot is
            // scalar (our accumulators are scalar), so the result is left scalar-typed.
            // Without a resolvable name it falls back to the honest remote-read placeholder.
            if node.type == "tm_get_variable_node" || node.type == "tm_get_remote_variable_node" {
                if let name = node.variableName {
                    let slot = CanonicalScriptGraphCompiler.variableSlot(for: name)
                    return Expr("(this.\(slot) ?? 0)")
                }
                return Expr("this.getRemoteValue(/* variable name unresolved */ \"\")")
            }

            // Unknown / unmapped node → a safe fallback, never fabricated behavior.
            return Expr("0 /* unsupported: \(node.type) */")
        }

        /// Lowers a binary math node from its already-evaluated operands. The result type
        /// is VECTOR iff either operand is a vector (else scalar). For an `add` over
        /// vectors we emit the publicly-documented `Math3D.add(a, b)` (JS `+` is not vector
        /// addition); for `subtract`/`multiply` over a vector, the `Math3D.*` name is NOT
        /// publicly documented, so we keep clean-room by leaving the operator and appending
        /// an honest TODO rather than fabricating a name. Scalar ops are unchanged.
        mutating func emitBinaryMath(
            _ type: String,
            op: BinaryScalar,
            a: Expr,
            b: Expr
        ) -> Expr {
            let isVector = a.isVector || b.isVector

            if isVector, type == "tm_math_add" {
                usesMath3D = true
                return Expr("Math3D.add(\(a.code), \(b.code))", isVector: true)
            }

            if isVector, type == "tm_math_subtract" || type == "tm_math_multiply" {
                // Math3D.subtract / Math3D.multiply are not in the public docs; don't
                // fabricate them. Keep the operator but flag it honestly. (These appear
                // only in non-running examples today.)
                let code = op.render(a.code, b.code)
                return Expr(
                    "\(code) /* TODO: vector op — Math3D name unverified */",
                    isVector: true
                )
            }

            // Scalar (or a vector op with no vector-specific lowering, e.g. divide/mod/
            // min/max/pow): keep the plain-JS operator / `Math.*` call.
            return Expr(op.render(a.code, b.code), isVector: isVector)
        }

        /// The `event.<pinName>` expression for a gesture/event output pin (inside a
        /// gesture handler). Outside a gesture context the value isn't in scope. The
        /// translation/location gesture outputs are `Math3D.Vector3`s, so they are typed
        /// as vectors (`deltaTime`, `didEnd`, … are scalars).
        func gestureOutputExpression(
            _ node: RCP3ScriptGraph.Node,
            outputPin: UInt64?,
            context: ExprContext
        ) -> Expr {
            guard let pin = outputPin else {
                return Expr("undefined /* exec pin used as value */")
            }
            // Resolve the output pin hash back to a readable gesture-output name.
            let name = Self.gestureOutputName(forHash: pin) ?? TMHash.hex(pin)
            let isVector = Self.vectorGestureOutputNames.contains(name)
            switch context {
            case .gesture:
                return Expr("event.\(name)", isVector: isVector)
            case .update where name == "deltaTime":
                return Expr("deltaTime")
            default:
                return Expr("undefined /* \(name) not in scope here */")
            }
        }

        /// The expression for a `tm_get_component` (Transform) OUTPUT pin: the entity's
        /// transform property the pin names. The mapping is the exact inverse of
        /// `emitSetComponent` (`translation` → `.position`, `rotation` → `.orientation`,
        /// `scale` → `.scale`). The entity target follows the same context rule as Set.
        /// An unrecognized output pin yields a safe `0` with an honest note.
        func getComponentExpression(outputPin: UInt64?, context: ExprContext) -> Expr {
            let target = context == .gesture ? "event.entity" : "this.entity"
            switch outputPin {
            // position/scale are `Math3D.Vector3`, orientation is a `Math3D.Quaternion` —
            // both vector-typed for the purpose of "use Math3D.add, not JS +".
            case CanonicalScriptGraphCompiler.translationPin:
                return Expr("\(target).position", isVector: true)
            case CanonicalScriptGraphCompiler.rotationPin:
                return Expr("\(target).orientation", isVector: true)
            case CanonicalScriptGraphCompiler.scalePin:
                return Expr("\(target).scale", isVector: true)
            default:
                return Expr("0 /* unsupported: tm_get_component output (Transform property not recognized) */")
            }
        }

        /// Resolves the data input feeding `pinName` of `node` to an expression. When no
        /// wire feeds the pin, falls back to `0` (the pin's literal would live in node
        /// settings, not the wire graph).
        mutating func inputExpression(
            into node: RCP3ScriptGraph.Node,
            pinName: String,
            context: ExprContext,
            seen: inout Set<String>,
            defaultValue: Expr? = nil
        ) -> Expr {
            let pin = TMHash.murmur64a(pinName)
            guard let wire = dataWire(into: node.id, pin: pin) else {
                // No wire feeding the pin: a bound scalar literal (a graph `data`
                // constant) supplies it, else the safe `0`.
                if let value = graph.scalarLiteral(node: node.id, pin: pin) {
                    return Expr(Self.renderScalar(value))
                }
                if let defaultValue { return defaultValue }
                return Expr("0 /* \(pinName) unwired */")
            }
            return emitExpression(from: wire, context: context, seen: &seen)
        }

        /// Renders a scalar literal as a clean JS number (integers without a
        /// trailing `.0`).
        static func renderScalar(_ value: Double) -> String {
            if value == value.rounded() && abs(value) < 1e15 {
                return String(Int(value))
            }
            return String(value)
        }

        // MARK: Static maps

        /// Math constant nodes → plain-JS `Math.*` constants (run anywhere).
        static func mathConstant(for type: String) -> String? {
            switch type {
            case "tm_constant_pi": return "Math.PI"
            case "tm_constant_e": return "Math.E"
            case "tm_constant_ln2": return "Math.LN2"
            case "tm_constant_ln10": return "Math.LN10"
            case "tm_constant_log10e": return "Math.LOG10E"
            case "tm_constant_log2e": return "Math.LOG2E"
            case "tm_constant_sqrt2": return "Math.SQRT2"
            case "tm_constant_sqrt1_2": return "Math.SQRT1_2"
            default: return nil
            }
        }

        /// Unary math nodes → `Math.<fn>` (plain JS). `nil` if not a unary math node.
        static func unaryMathFunction(for type: String) -> String? {
            switch type {
            case "tm_math_sin": return "Math.sin"
            case "tm_math_cos": return "Math.cos"
            case "tm_math_tan": return "Math.tan"
            case "tm_math_asin": return "Math.asin"
            case "tm_math_acos": return "Math.acos"
            case "tm_math_atan": return "Math.atan"
            case "tm_math_sqrt": return "Math.sqrt"
            case "tm_math_log": return "Math.log"
            case "tm_math_log2": return "Math.log2"
            case "tm_math_abs": return "Math.abs"
            case "tm_math_ceil": return "Math.ceil"
            case "tm_math_floor": return "Math.floor"
            case "tm_math_round": return "Math.round"
            case "tm_math_trunc": return "Math.trunc"
            default: return nil
            }
        }

        /// How a binary scalar node renders two operand expressions.
        enum BinaryScalar {
            /// An infix operator, e.g. `+` → `(a + b)`.
            case infix(String)
            /// A `Math.<fn>(a, b)` call.
            case mathCall(String)

            func render(_ a: String, _ b: String) -> String {
                switch self {
                case .infix(let op): return "(\(a) \(op) \(b))"
                case .mathCall(let fn): return "\(fn)(\(a), \(b))"
                }
            }
        }

        /// Binary scalar math nodes → operators / `Math.*` (plain JS). `nil` otherwise.
        static func binaryScalarOperator(for type: String) -> BinaryScalar? {
            switch type {
            case "tm_math_add": return .infix("+")
            case "tm_math_subtract": return .infix("-")
            case "tm_math_multiply": return .infix("*")
            case "tm_math_divide": return .infix("/")
            case "tm_math_mod": return .infix("%")
            case "tm_math_min": return .mathCall("Math.min")
            case "tm_math_max": return .mathCall("Math.max")
            case "tm_math_pow": return .mathCall("Math.pow")
            default: return nil
            }
        }

        /// Comparison nodes → the infix JS comparison operator (scalar → boolean).
        /// `nil` if not a comparison node.
        static func comparisonOperator(for type: String) -> String? {
            switch type {
            case "tm_math_greater": return ">"
            case "tm_math_greater_equal": return ">="
            case "tm_math_less": return "<"
            case "tm_math_less_equal": return "<="
            default: return nil
            }
        }

        /// Logic reducer nodes → the infix JS logical operator (→ boolean). `nil`
        /// otherwise.
        static func logicOperator(for type: String) -> String? {
            switch type {
            case "tm_and": return "&&"
            case "tm_or": return "||"
            default: return nil
            }
        }

        /// Bitwise BINARY nodes → the infix JS bitwise operator (scalar). `nil` for the
        /// unary `_not` (handled separately) and non-bitwise nodes.
        static func bitwiseBinaryOperator(for type: String) -> String? {
            switch type {
            case "tm_math_bitwise_and": return "&"
            case "tm_math_bitwise_or": return "|"
            case "tm_math_bitwise_xor": return "^"
            default: return nil
            }
        }

        /// The operand expressions of a variadic logic node (`tm_and` / `tm_or`). The
        /// library seeds the `a`/`b` pins; on disk a node may carry more (`c`, `d`, …).
        /// We always emit `a`/`b`, then fold any further single-letter operand pin that
        /// actually carries a wire or a baked scalar literal, in alphabetical order.
        mutating func logicOperands(
            of node: RCP3ScriptGraph.Node,
            context: ExprContext,
            seen: inout Set<String>
        ) -> [String] {
            var operands: [String] = [
                inputExpression(into: node, pinName: "a", context: context, seen: &seen).code,
                inputExpression(into: node, pinName: "b", context: context, seen: &seen).code,
            ]
            // Fold any additional connected operand pins (c, d, …) present in the graph.
            for letter in "cdefghijklmnopqrstuvwxyz" {
                let name = String(letter)
                let pin = TMHash.murmur64a(name)
                let hasWire = dataWire(into: node.id, pin: pin) != nil
                let hasLiteral = graph.scalarLiteral(node: node.id, pin: pin) != nil
                guard hasWire || hasLiteral else { continue }
                operands.append(inputExpression(into: node, pinName: name, context: context, seen: &seen).code)
            }
            return operands
        }

        /// String predicate / accessor nodes → plain-JS string expressions (scalar:
        /// boolean / number / string). The first input pin is always `string`; the arg
        /// pin name follows the library. Returns `nil` if `node` is not a string node.
        mutating func emitStringExpression(
            _ node: RCP3ScriptGraph.Node,
            context: ExprContext,
            seen: inout Set<String>
        ) -> Expr? {
            func arg(_ pinName: String) -> String {
                inputExpression(into: node, pinName: pinName, context: context, seen: &seen).code
            }
            switch node.type {
            case "tm_string_has_prefix":
                return Expr("(\(arg("string"))).startsWith(\(arg("prefix")))")
            case "tm_string_has_suffix":
                return Expr("(\(arg("string"))).endsWith(\(arg("suffix")))")
            case "tm_string_contains":
                return Expr("(\(arg("string"))).includes(\(arg("substring")))")
            case "tm_string_length":
                return Expr("(\(arg("string"))).length")
            case "tm_string_prefix":
                // The first `length` characters.
                return Expr("(\(arg("string"))).slice(0, \(arg("length")))")
            case "tm_string_suffix":
                // The last `length` characters.
                return Expr("(\(arg("string"))).slice(-(\(arg("length"))))")
            case "tm_string_substring":
                // `length` characters starting at `index`.
                let s = arg("string")
                let index = arg("index")
                let length = arg("length")
                return Expr("(\(s)).substring(\(index), (\(index)) + (\(length)))")
            default:
                return nil
            }
        }

        /// Vector ops whose `Math3D` function name is not in the public docs (so we
        /// must NOT emit a `Math3D.*` call for them — clean-room).
        static func isUndocumentedVectorOp(_ type: String) -> Bool {
            switch type {
            case "tm_math_dot", "tm_math_cross", "tm_math_reflect",
                 "tm_math_length", "tm_math_normal":
                return true
            default:
                return false
            }
        }

        /// The readable name for a gesture-output pin hash (the names from the in-house
        /// node library, hashed to match a wired `from_connector_hash`).
        static func gestureOutputName(forHash hash: UInt64) -> String? {
            gestureOutputNamesByHash[hash]
        }

        static let gestureOutputNames: [String] = [
            "entity", "location", "startLocation", "translation",
            "sceneLocation", "sceneStartLocation", "sceneTranslation",
            "sceneInputDeviceRotation", "didEnd", "deltaTime", "scene",
        ]

        /// Gesture output pins whose value is a `Math3D.Vector3` (a 2D/3D point or
        /// translation). These feed vector math, so a downstream `tm_math_add` must lower
        /// to `Math3D.add` rather than the scalar `+`. (`deltaTime`/`didEnd`/`entity`/
        /// `scene` are NOT vectors.)
        static let vectorGestureOutputNames: Set<String> = [
            "location", "startLocation", "translation",
            "sceneLocation", "sceneStartLocation", "sceneTranslation",
        ]

        static let gestureOutputNamesByHash: [UInt64: String] = {
            var map: [UInt64: String] = [:]
            for name in gestureOutputNames { map[TMHash.murmur64a(name)] = name }
            return map
        }()
    }

    // MARK: Pattern recognition (the documented reference handler)

    /// Whether `dragNode` exec-reaches a `tm_set_component` node that takes a data
    /// wire from the drag node into its `translation` pin — the "drag moves the
    /// transform translation" wiring (the documented reference handler).
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
    /// transform translation is `entity.position` on this surface. Emitted verbatim
    /// for the documented reference wiring (drag `sceneTranslation` → set
    /// `translation`).
    static let dragToPositionHandler = """
    this.didAdd = function() {
        this.entity.setComponent(new RealityKit.InputTargetComponent());
        this.entity.generateCollisionShapes(true);
        let dragStart;
        this.entity.on(RealityKit.DragGestureEvent.name, (e) => {
            const event = e.event;
            if (!this.__d3_log_drag) { this.__d3_log_drag = true; console.log("[D3] drag fired"); }
            dragStart ??= event.entity.position.clone();
            event.entity.position = Math3D.add(dragStart, event.sceneTranslation);
            if (event.phase.equals(RealityKit.DragGestureEvent.Phase.ended)) dragStart = undefined;
        });
    };
    """
}
