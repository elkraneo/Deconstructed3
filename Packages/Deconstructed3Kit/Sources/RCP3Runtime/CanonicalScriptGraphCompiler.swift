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
///    `scale` → `.scale`) from the *evaluated* expression feeding its pin, or attaches
///    a known default component when only a `component_type` selector is present. A
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
/// Emitted JS is grounded in the observed RealityKit Script Graph runtime surface
/// (the `RealityKit` / `Math3D` modules + the lifecycle/gesture shapes) and in plain
/// ECMAScript (`Math.*`, operators). Vector-math nodes lower to their observed
/// `Math3D.<function>(args)` form: `dot`/`cross`/`reflect`/`length`/`normal` (the
/// last being the *normalize* node, whose function is literally `normal`), and the
/// multiply-by-scalar/quaternion/matrix family, which all emit `Math3D.multiply(a, b)`.
/// Scalar arithmetic (`add`/`subtract`/`multiply`/`divide`) stays as bare JS operators.
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
    static let componentTypePin = TMHash.murmur64a("component_type")
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
        /// Set when a value constructor references the `Foundation` runtime module.
        var usesFoundation = false
        /// Set when a value constructor references the `CoreGraphics` runtime module.
        var usesCoreGraphics = false
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
            if usesFoundation { lines.append("const Foundation = require(\"Foundation\");") }
            if usesCoreGraphics { lines.append("const CoreGraphics = require(\"CoreGraphics\");") }
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
            /// A `this.<name> = function(event){…}` runtime event hook.
            case runtime(String)
            case custom(targeted: Bool)
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
            case "tm_collision_event_began": return .runtime("collisionBegan")
            case "tm_collision_event_updated": return .runtime("collisionUpdated")
            case "tm_collision_event_ended": return .runtime("collisionEnded")
            case "tm_physics_event_will_simulate": return .runtime("physicsWillSimulate")
            case "tm_physics_event_did_simulate": return .runtime("physicsDidSimulate")
            case "tm_animation_event_playback_started": return .runtime("animationPlaybackStarted")
            case "tm_animation_event_playback_completed": return .runtime("animationPlaybackCompleted")
            case "tm_animation_event_playback_looped": return .runtime("animationPlaybackLooped")
            case "tm_animation_event_playback_terminated": return .runtime("animationPlaybackTerminated")
            case "tm_audio_event_playback_completed": return .runtime("audioPlaybackCompleted")
            case "tm_custom_event", "tm_on_scene_event": return .custom(targeted: false)
            case "tm_on_entity_event": return .custom(targeted: true)
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
            case .runtime(let name):
                let body = emitActionBody(after: node, context: .event)
                return emitFunctionHandler(name: name, params: "event", body: body, logEvent: name)
            case .custom(let targeted):
                var seen: Set<String> = []
                let eventName = inputExpression(
                    into: node, pinName: "eventName", context: .lifecycle, seen: &seen,
                    defaultValue: Expr("\"\"")
                ).code
                let body = emitActionBody(after: node, context: .event)
                let receiver = targeted ? "this.entity" : "this"
                var lines = ["\(receiver).on(\(eventName), (event) => {"]
                for statement in body { lines.append("    " + statement) }
                lines.append("});")
                return lines.joined(separator: "\n")
            }
        }

        /// `this.<name> = function(<params>) { <body> };`, with a ONE-TIME `console.log`
        /// at the body entry so the in-app console (Apple's RealityKitScripting log
        /// stream) shows the handler fired without flooding — critical for `update`,
        /// which runs every frame, so the log is guarded by a per-handler instance flag.
        func emitFunctionHandler(name: String, params: String, body: [String], logEvent: String) -> String {
            let async = body.contains { $0.contains("await ") } ? "async " : ""
            var lines = ["this.\(name) = \(async)function(\(params)) {"]
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
            case "tm_variable_add", "tm_variable_subtract", "tm_variable_multiply",
                 "tm_variable_divide", "tm_variable_multiply_by_scalar",
                 "tm_variable_multiply_by_quaternion", "tm_variable_multiply_by_matrix":
                return emitVariableMutation(node, context: context)
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
            case "tm_entity_set_relative_transform":
                return emitSetRelativeTransform(node, context: context)
            case "tm_entity_look_at":
                return emitEntityLookAt(node, context: context)
            case "tm_set_entity_enable":
                return emitSetEntityEnable(node, context: context)
            case "tm_entity_set_world_transform":
                return emitSetWorldTransform(node, context: context)
            case "tm_set_parent":
                return emitSetParent(node, context: context)
            case "tm_add_child":
                return emitAddChild(node, context: context)
            case "tm_remove_child":
                return emitRemoveChild(node, context: context)
            case "tm_remove_from_parent":
                return emitRemoveFromParent(node, context: context)
            case "tm_spawn_entity":
                return emitSpawnEntity(node, context: context)
            case "tm_clone":
                return emitClone(node, context: context)
            case "tm_remove_component":
                return emitRemoveComponent(node, context: context)
            case "tm_array_set":
                return emitArraySet(node, context: context)
            case "tm_array_add":
                return emitArrayAdd(node, context: context)
            case "tm_array_remove":
                return emitArrayRemove(node, context: context)
            case "tm_array_for_each":
                return emitArrayForEach(node, context: context)
            case "tm_array_find":
                return emitArrayFind(node, context: context)
            case "tm_physics_clear_forces_and_torques":
                return emitEntityBooleanMethod(node, method: "clearForcesAndTorques", context: context)
            case "tm_physics_reset_transform":
                return emitEntityBooleanMethod(node, method: "resetPhysicsTransform", context: context)
            case "tm_physics_add_force":
                return emitPhysicsVectorAction(node, valuePin: "force", method: "addForce", hasPosition: true, context: context)
            case "tm_physics_add_torque":
                return emitPhysicsVectorAction(node, valuePin: "torque", method: "addTorque", hasPosition: false, context: context)
            case "tm_physics_apply_linear_impulse":
                return emitPhysicsVectorAction(node, valuePin: "impulse", method: "applyLinearImpulse", hasPosition: false, context: context)
            case "tm_physics_apply_angular_impulse":
                return emitPhysicsVectorAction(node, valuePin: "impulse", method: "applyAngularImpulse", hasPosition: false, context: context)
            case "tm_physics_apply_impulse":
                return emitPhysicsVectorAction(node, valuePin: "impulse", method: "applyLinearImpulse", hasPosition: true, context: context)
            case "tm_audio_mix_groups_component_add_group":
                return emitAudioMixGroupMutation(node, operation: "set", valuePin: "mixGroup", createIfMissing: true, context: context)
            case "tm_audio_mix_groups_component_remove_group":
                return emitAudioMixGroupMutation(node, operation: "remove", valuePin: "name", createIfMissing: false, context: context)
            case "tm_pause_audio":
                return emitAudioControllerAction(node, method: "pause", argumentPins: [], context: context)
            case "tm_seek_audio", "tm_seek_audio_group":
                return emitAudioControllerAction(node, method: "seek", argumentPins: ["time"], context: context)
            case "tm_fade_audio", "tm_fade_audio_group":
                return emitAudioControllerAction(node, method: "fade", argumentPins: ["gain", "duration"], context: context)
            case "tm_pause_audio_group":
                return emitAudioGroupPause(node, context: context)
            case "tm_stop_all_audio":
                return emitReceiverAction(node, receiverPin: "source", method: "stopAllAudio", argumentPins: [], receiverDefault: "this.entity", context: context)
            case "tm_stop_audio", "tm_stop_audio_group":
                return emitReceiverAction(node, receiverPin: "source", method: "stop", argumentPins: [], receiverDefault: "undefined", context: context)
            case "tm_play_audio_at_time", "tm_play_audio_group_at_time":
                return emitReceiverAction(node, receiverPin: "source", method: "play", argumentPins: ["time"], receiverDefault: "undefined", context: context)
            case "tm_fade_audio_mix_group":
                return emitAudioControllerAction(node, method: "fade", argumentPins: ["gain", "duration"], context: context)
            case "tm_play_audio_by_name":
                return emitPlayAudioByName(node, grouped: false, context: context)
            case "tm_play_audio_group_by_name":
                return emitPlayAudioByName(node, grouped: true, context: context)
            case "tm_set_material_parameter_v2":
                return emitSetMaterialParameter(node, context: context)
            case "tm_set_entity_parameter":
                return emitSetEntityParameter(node, context: context)
            case "tm_modify_any_material":
                return emitModifyAnyMaterial(node, context: context)
            case "tm_trigger_event", "tm_send_scene_event":
                return emitCustomEventSend(node, targeted: false, context: context)
            case "tm_send_entity_event":
                return emitCustomEventSend(node, targeted: true, context: context)
            case "tm_stop_all_animations":
                return emitReceiverAction(node, receiverPin: "entity", method: "stopAllAnimations", argumentPins: ["recursive"], receiverDefault: "this.entity", context: context)
            case "tm_stop_animation":
                return emitReceiverAction(node, receiverPin: "playbackController", method: "stop", argumentPins: ["blendOutDuration"], receiverDefault: "undefined", context: context)
            case "tm_pause_animation":
                return emitAnimationPause(node, context: context)
            case "tm_play_animation_by_name", "tm_play_animation_by_index":
                return emitPlayAnimationByName(node, context: context)
            case "tm_entity_teleport_character":
                return emitTeleportCharacter(node, context: context)
            case "tm_entity_move":
                return emitEntityMove(node, context: context)
            case "tm_entity_move_character":
                return emitMoveCharacter(node, context: context)
            case "tm_is_valid_branch":
                return emitIsValidBranch(node, context: context)
            case "tm_scene_raycast_v2":
                return emitSceneCast(node, convex: false, context: context)
            case "tm_scene_convex_cast":
                return emitSceneCast(node, convex: true, context: context)
            default:
                return ["// unsupported node: \(node.type)"]
            }
        }

        static func handlesOwnControlFlow(_ type: String) -> Bool {
            switch type {
            case "tm_sequence", "tm_if", "tm_switch", "tm_loop", "tm_delay", "tm_do_once", "tm_array_for_each", "tm_array_find", "tm_entity_move_character", "tm_is_valid_branch", "tm_scene_raycast_v2", "tm_scene_convex_cast":
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
            case "tm_array_for_each":
                return [CanonicalScriptGraphCompiler.stepPin, CanonicalScriptGraphCompiler.endPin].contains(wire.fromPin)
            case "tm_array_find":
                return [TMHash.murmur64a("found"), TMHash.murmur64a("not found")].contains(wire.fromPin)
            case "tm_entity_move_character":
                return [CanonicalScriptGraphCompiler.unnamedExecPin, TMHash.murmur64a("collision")].contains(wire.fromPin)
            case "tm_is_valid_branch":
                return [TMHash.murmur64a("valid"), TMHash.murmur64a("invalid")].contains(wire.fromPin)
            case "tm_scene_raycast_v2", "tm_scene_convex_cast":
                return [TMHash.murmur64a("hit"), TMHash.murmur64a("miss")].contains(wire.fromPin)
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

        mutating func emitIsValidBranch(
            _ node: RCP3ScriptGraph.Node,
            context: ExprContext
        ) -> [String] {
            var seen: Set<String> = []
            let input = node.dynamicConnectorSettings?.inputs.first?.name ?? "source"
            let source = inputExpression(
                into: node, pinName: input, context: context, seen: &seen,
                defaultValue: Expr("undefined")
            ).code
            let validBody = emitActionBody(
                after: node, context: context, outputPin: TMHash.murmur64a("valid")
            )
            let invalidBody = emitActionBody(
                after: node, context: context, outputPin: TMHash.murmur64a("invalid")
            )
            return ["if (" + source + " !== undefined && " + source + " !== null) {"]
                + Self.indent(validBody.isEmpty ? ["// no-op"] : validBody)
                + ["} else {"]
                + Self.indent(invalidBody.isEmpty ? ["// no-op"] : invalidBody)
                + ["}"]
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

        mutating func emitSetRelativeTransform(
            _ node: RCP3ScriptGraph.Node,
            context: ExprContext
        ) -> [String] {
            var seen: Set<String> = []
            let entity = inputExpression(into: node, pinName: "entity", context: context, seen: &seen, defaultValue: Expr("this.entity")).code
            let relativeTo = inputExpression(into: node, pinName: "relativeTo", context: context, seen: &seen, defaultValue: Expr("null")).code
            let scale = inputExpression(into: node, pinName: "scale", context: context, seen: &seen, defaultValue: Expr("null")).code
            let orientation = inputExpression(into: node, pinName: "orientation", context: context, seen: &seen, defaultValue: Expr("null")).code
            let position = inputExpression(into: node, pinName: "position", context: context, seen: &seen, defaultValue: Expr("null")).code
            let matrix = inputExpression(into: node, pinName: "matrix", context: context, seen: &seen, defaultValue: Expr("null")).code
            return [
                "if (\(scale) != null) \(entity).setRelativeScale(\(scale), \(relativeTo));",
                "if (\(orientation) != null) \(entity).setRelativeOrientation(\(orientation), \(relativeTo));",
                "if (\(position) != null) \(entity).setRelativePosition(\(position), \(relativeTo));",
                "if (\(matrix) != null) \(entity).setRelativeTransformMatrix(\(matrix), \(relativeTo));",
            ]
        }

        mutating func emitEntityLookAt(
            _ node: RCP3ScriptGraph.Node,
            context: ExprContext
        ) -> [String] {
            var seen: Set<String> = []
            let entity = inputExpression(into: node, pinName: "entity", context: context, seen: &seen, defaultValue: Expr("this.entity")).code
            let at = inputExpression(into: node, pinName: "at", context: context, seen: &seen).code
            let from = inputExpression(into: node, pinName: "from", context: context, seen: &seen).code
            let upVector = inputExpression(into: node, pinName: "upVector", context: context, seen: &seen).code
            let relativeTo = inputExpression(into: node, pinName: "relativeTo", context: context, seen: &seen, defaultValue: Expr("null")).code
            let positiveZForward = inputExpression(into: node, pinName: "positiveZForward", context: context, seen: &seen).code
            return ["\(entity).look(\(at), \(from), \(upVector), \(relativeTo), \(positiveZForward));"]
        }

        mutating func emitSetEntityEnable(_ node: RCP3ScriptGraph.Node, context: ExprContext) -> [String] {
            var seen: Set<String> = []
            let entity = inputExpression(into: node, pinName: "entity", context: context, seen: &seen, defaultValue: Expr("this.entity")).code
            let isEnabled = inputExpression(into: node, pinName: "isEnabled", context: context, seen: &seen).code
            return ["\(entity).isEnabled = \(isEnabled);"]
        }

        mutating func emitSetWorldTransform(_ node: RCP3ScriptGraph.Node, context: ExprContext) -> [String] {
            var seen: Set<String> = []
            let entity = inputExpression(into: node, pinName: "entity", context: context, seen: &seen, defaultValue: Expr("this.entity")).code
            let assignments = [
                ("scale", "worldScale"),
                ("orientation", "worldOrientation"),
                ("position", "worldPosition"),
                ("matrix", "worldTransformMatrix"),
            ]
            return assignments.compactMap { pinName, property in
                guard hasDataInput(into: node, pinName: pinName) else { return nil }
                let value = inputExpression(into: node, pinName: pinName, context: context, seen: &seen).code
                return "\(entity).\(property) = \(value);"
            }
        }

        mutating func emitSetParent(_ node: RCP3ScriptGraph.Node, context: ExprContext) -> [String] {
            var seen: Set<String> = []
            let entity = inputExpression(into: node, pinName: "entity", context: context, seen: &seen, defaultValue: Expr("this.entity")).code
            let parent = inputExpression(into: node, pinName: "parent", context: context, seen: &seen).code
            let preserving = inputExpression(into: node, pinName: "preservingWorldTransform", context: context, seen: &seen).code
            return ["\(entity).setParent(\(parent), \(preserving));"]
        }

        mutating func emitAddChild(_ node: RCP3ScriptGraph.Node, context: ExprContext) -> [String] {
            var seen: Set<String> = []
            let entity = inputExpression(into: node, pinName: "entity", context: context, seen: &seen, defaultValue: Expr("this.entity")).code
            let child = inputExpression(into: node, pinName: "child", context: context, seen: &seen).code
            let preserving = inputExpression(into: node, pinName: "preservingWorldTransform", context: context, seen: &seen).code
            return ["\(entity).addChild(\(child), \(preserving));"]
        }

        mutating func emitRemoveChild(_ node: RCP3ScriptGraph.Node, context: ExprContext) -> [String] {
            var seen: Set<String> = []
            let entity = inputExpression(into: node, pinName: "entity", context: context, seen: &seen, defaultValue: Expr("this.entity")).code
            let child = inputExpression(into: node, pinName: "child", context: context, seen: &seen).code
            let preserving = inputExpression(into: node, pinName: "preservingWorldTransform", context: context, seen: &seen).code
            return ["\(entity).removeChild(\(child), \(preserving));"]
        }

        mutating func emitRemoveFromParent(_ node: RCP3ScriptGraph.Node, context: ExprContext) -> [String] {
            var seen: Set<String> = []
            let entity = inputExpression(into: node, pinName: "entity", context: context, seen: &seen, defaultValue: Expr("this.entity")).code
            let preserving = inputExpression(into: node, pinName: "preservingWorldTransform", context: context, seen: &seen).code
            return [
                "\(entity).isEnabled = false;",
                "\(entity).removeFromParent(\(preserving));",
            ]
        }

        /// Loads the selected entity asset from the app bundle and optionally
        /// attaches it to the supplied parent. The shipped emitter performs the
        /// load asynchronously and always disables world-transform preservation.
        mutating func emitSpawnEntity(_ node: RCP3ScriptGraph.Node, context: ExprContext) -> [String] {
            usesRealityKit = true
            usesFoundation = true
            var seen: Set<String> = []
            let asset = inputExpression(
                into: node, pinName: "entity", context: context, seen: &seen,
                defaultValue: Expr("undefined")
            ).code
            let spawned = Self.spawnedEntityName(for: node)
            var statements = [
                "let \(spawned) = await RealityKit.Entity.load(\(asset), Foundation.Bundle.main);"
            ]
            if hasDataInput(into: node, pinName: "parent") {
                let parent = inputExpression(
                    into: node, pinName: "parent", context: context, seen: &seen
                ).code
                statements.append("if (\(parent) !== undefined) \(parent).addChild(\(spawned), false);")
            }
            return statements
        }

        /// Clone is an action node with a data result. Materialize the result once so
        /// downstream data wires observe the same entity created by the exec step.
        mutating func emitClone(_ node: RCP3ScriptGraph.Node, context: ExprContext) -> [String] {
            var seen: Set<String> = []
            let source = inputExpression(
                into: node, pinName: "source", context: context, seen: &seen,
                defaultValue: Expr("this.entity")
            ).code
            let invocation: String
            if hasDataInput(into: node, pinName: "recursive") {
                let recursive = inputExpression(
                    into: node, pinName: "recursive", context: context, seen: &seen
                ).code
                invocation = "\(source).clone(\(recursive))"
            } else {
                invocation = "\(source).clone()"
            }
            return ["let \(Self.clonedEntityName(for: node)) = \(invocation);"]
        }

        mutating func emitEntityBooleanMethod(
            _ node: RCP3ScriptGraph.Node,
            method: String,
            context: ExprContext
        ) -> [String] {
            var seen: Set<String> = []
            let entity = inputExpression(
                into: node, pinName: "entity", context: context, seen: &seen,
                defaultValue: Expr("this.entity")
            ).code
            let recursive = inputExpression(
                into: node, pinName: "recursive", context: context, seen: &seen,
                defaultValue: Expr("false")
            ).code
            return ["\(entity).\(method)(\(recursive));"]
        }

        mutating func emitPhysicsVectorAction(
            _ node: RCP3ScriptGraph.Node,
            valuePin: String,
            method: String,
            hasPosition: Bool,
            context: ExprContext
        ) -> [String] {
            var seen: Set<String> = []
            let entity = inputExpression(
                into: node, pinName: "entity", context: context, seen: &seen,
                defaultValue: Expr("this.entity")
            ).code
            let value = inputExpression(
                into: node, pinName: valuePin, context: context, seen: &seen
            ).code
            let relativeTo = inputExpression(
                into: node, pinName: "relativeTo", context: context, seen: &seen,
                defaultValue: Expr("null")
            ).code
            if hasPosition {
                let at = inputExpression(
                    into: node, pinName: "at", context: context, seen: &seen,
                    defaultValue: Expr("null")
                ).code
                return ["\(entity).\(method)(\(value), \(at), \(relativeTo));"]
            }
            return ["\(entity).\(method)(\(value), \(relativeTo));"]
        }

        mutating func emitAudioMixGroupMutation(
            _ node: RCP3ScriptGraph.Node,
            operation: String,
            valuePin: String,
            createIfMissing: Bool,
            context: ExprContext
        ) -> [String] {
            usesRealityKit = true
            var seen: Set<String> = []
            let entity = inputExpression(
                into: node, pinName: "source", context: context, seen: &seen,
                defaultValue: Expr("this.entity")
            ).code
            let value = inputExpression(
                into: node, pinName: valuePin, context: context, seen: &seen
            ).code
            let component = "__d3_audio_mix_groups_\(Self.sanitize(node.id))"
            if createIfMissing {
                return [
                    "let \(component) = \(entity).getComponent(RealityKit.AudioMixGroupsComponent.Type) ?? new RealityKit.AudioMixGroupsComponent();",
                    "\(component).\(operation)(\(value));",
                    "\(entity).setComponent(\(component));",
                ]
            }
            return [
                "let \(component) = \(entity).getComponent(RealityKit.AudioMixGroupsComponent.Type);",
                "if (\(component) != null) {",
                "    \(component).\(operation)(\(value));",
                "    \(entity).setComponent(\(component));",
                "}",
            ]
        }

        mutating func emitRemoveComponent(
            _ node: RCP3ScriptGraph.Node,
            context: ExprContext
        ) -> [String] {
            var seen: Set<String> = []
            let source = inputExpression(
                into: node, pinName: "source", context: context, seen: &seen,
                defaultValue: Expr("this.entity")
            ).code
            let componentType = inputExpression(
                into: node, pinName: "component_type", context: context, seen: &seen
            ).code
            return [
                "if (\(source).hasComponent(\(componentType))) {",
                "    \(source).removeComponent(\(componentType));",
                "}",
            ]
        }

        mutating func emitCustomEventSend(
            _ node: RCP3ScriptGraph.Node,
            targeted: Bool,
            context: ExprContext
        ) -> [String] {
            var seen: Set<String> = []
            let eventName = inputExpression(
                into: node, pinName: "eventName", context: context, seen: &seen,
                defaultValue: Expr("\"\"")
            ).code
            let receiver = targeted
                ? inputExpression(
                    into: node, pinName: "receiver", context: context, seen: &seen,
                    defaultValue: Expr("this.entity")
                ).code
                : "this"
            let fixed = Set(["eventName", "receiver"])
            let connectors = (node.dynamicConnectorSettings?.inputs ?? [])
                .filter { !fixed.contains($0.name) }
                .sorted { $0.order < $1.order }
            let properties = connectors.map { connector -> String in
                let value = inputExpression(
                    into: node, pinName: connector.name, context: context, seen: &seen
                ).code
                return "\(Self.renderJSString(connector.name)): \(value)"
            }
            return ["\(receiver).send(\(eventName), { \(properties.joined(separator: ", ")) });"]
        }

        mutating func emitReceiverAction(
            _ node: RCP3ScriptGraph.Node,
            receiverPin: String,
            method: String,
            argumentPins: [String],
            receiverDefault: String,
            context: ExprContext
        ) -> [String] {
            var seen: Set<String> = []
            let receiver = inputExpression(
                into: node, pinName: receiverPin, context: context, seen: &seen,
                defaultValue: Expr(receiverDefault)
            ).code
            let arguments = argumentPins.map {
                inputExpression(into: node, pinName: $0, context: context, seen: &seen).code
            }
            return ["\(receiver).\(method)(\(arguments.joined(separator: ", ")));"]
        }

        mutating func emitAnimationPause(
            _ node: RCP3ScriptGraph.Node,
            context: ExprContext
        ) -> [String] {
            var seen: Set<String> = []
            let controller = inputExpression(
                into: node, pinName: "playbackController", context: context, seen: &seen,
                defaultValue: Expr("undefined")
            ).code
            let pause = inputExpression(
                into: node, pinName: "pause", context: context, seen: &seen,
                defaultValue: Expr("false")
            ).code
            return ["if (\(pause)) { \(controller).pause(); } else { \(controller).resume(); }"]
        }

        mutating func emitSceneCast(
            _ node: RCP3ScriptGraph.Node,
            convex: Bool,
            context: ExprContext
        ) -> [String] {
            usesRealityKit = true
            var seen: Set<String> = []
            let mask = inputExpression(
                into: node, pinName: "mask", context: context, seen: &seen,
                defaultValue: Expr("RealityKit.CollisionGroup.all")
            ).code
            let relativeTo = inputExpression(
                into: node, pinName: "relativeTo", context: context, seen: &seen,
                defaultValue: Expr("null")
            ).code
            let hits = "__d3_cast_hits_\(Self.sanitize(node.id))"
            let hit = Self.sceneCastHitName(for: node)
            let call: String
            if convex {
                let shape = inputExpression(into: node, pinName: "shape", context: context, seen: &seen).code
                let from = inputExpression(into: node, pinName: "from", context: context, seen: &seen).code
                let to = inputExpression(into: node, pinName: "to", context: context, seen: &seen).code
                call = "this.entity.scene.convexCast({ shape: \(shape), fromPosition: \(from), toPosition: \(to), mask: \(mask), query: RealityKit.CollisionCastQueryType.nearest, entity: \(relativeTo) })"
            } else {
                let from = inputExpression(into: node, pinName: "from", context: context, seen: &seen).code
                let direction = inputExpression(into: node, pinName: "direction", context: context, seen: &seen).code
                let length = inputExpression(into: node, pinName: "length", context: context, seen: &seen).code
                call = "this.entity.scene.raycast(\(from), \(direction), \(length), RealityKit.CollisionCastQueryType.nearest, \(mask), \(relativeTo))"
            }
            let hitBody = emitActionBody(after: node, context: context, outputPin: TMHash.murmur64a("hit"))
            let missBody = emitActionBody(after: node, context: context, outputPin: TMHash.murmur64a("miss"))
            return ["let \(hits) = \(call);", "if (\(hits).length > 0) {", "    let \(hit) = \(hits)[0];"]
                + Self.indent(hitBody, by: "    ")
                + ["} else {"] + Self.indent(missBody) + ["}"]
        }

        mutating func emitPlayAnimationByName(
            _ node: RCP3ScriptGraph.Node,
            context: ExprContext
        ) -> [String] {
            var seen: Set<String> = []
            let entity = inputExpression(into: node, pinName: "entity", context: context, seen: &seen, defaultValue: Expr("this.entity")).code
            let selectorPin = node.type == "tm_play_animation_by_index" ? "index" : "name"
            let selector = inputExpression(into: node, pinName: selectorPin, context: context, seen: &seen).code
            let shouldRepeat = inputExpression(into: node, pinName: "repeat", context: context, seen: &seen, defaultValue: Expr("false")).code
            let transition = inputExpression(into: node, pinName: "transitionDuration", context: context, seen: &seen, defaultValue: Expr("0")).code
            let startsPaused = inputExpression(into: node, pinName: "startsPaused", context: context, seen: &seen, defaultValue: Expr("false")).code
            let animation = "__d3_animation_\(Self.sanitize(node.id))"
            let controller = Self.animationControllerName(for: node)
            return [
                node.type == "tm_play_animation_by_index"
                    ? "let \(animation) = \(entity).availableAnimations[\(selector)];"
                    : "let \(animation) = \(entity).availableAnimations.find(animation => animation.name == \(selector));",
                "let \(controller) = undefined;",
                "if (\(animation) == undefined) {",
                "    console.error(\"Could not find animation to play!\");",
                "} else {",
                "    \(controller) = \(entity).playAnimation(\(shouldRepeat) ? \(animation).repeat() : \(animation), \(transition), \(startsPaused));",
                "}",
            ]
        }

        mutating func emitPlayAudioByName(
            _ node: RCP3ScriptGraph.Node,
            grouped: Bool,
            context: ExprContext
        ) -> [String] {
            usesRealityKit = true
            var seen: Set<String> = []
            let sourcePin = grouped ? "source" : "entity"
            let libraryEntity = inputExpression(
                into: node, pinName: sourcePin, context: context, seen: &seen,
                defaultValue: Expr("this.entity")
            ).code
            let prepare = inputExpression(
                into: node, pinName: "prepareOnly", context: context, seen: &seen,
                defaultValue: Expr("false")
            ).code
            let library = "__d3_audio_library_\(Self.sanitize(node.id))"
            let controller = Self.namedAudioControllerName(for: node)
            var lines = [
                "let \(library) = \(libraryEntity).getComponent(RealityKit.AudioLibraryComponent.Type);",
                "let \(controller) = undefined;",
            ]
            if grouped {
                let entities = inputExpression(into: node, pinName: "entities", context: context, seen: &seen).code
                let names = inputExpression(into: node, pinName: "names", context: context, seen: &seen).code
                let pairs = "__d3_audio_pairs_\(Self.sanitize(node.id))"
                lines += [
                    "if (\(library) == null) { console.error(\"Could not find AudioLibraryComponent\"); } else {",
                    "    let \(pairs) = \(names).map((name, index) => [\(library).resources[name], \(entities)[index]]);",
                    "    \(controller) = \(prepare) ? RealityKit.Audio.prepareAudio(\(pairs)) : RealityKit.Audio.playAudio(\(pairs));",
                    "}",
                ]
            } else {
                let name = inputExpression(into: node, pinName: "name", context: context, seen: &seen).code
                let target = inputExpression(into: node, pinName: "target", context: context, seen: &seen, defaultValue: Expr("this.entity")).code
                let resource = "__d3_audio_resource_\(Self.sanitize(node.id))"
                lines += [
                    "let \(resource) = \(library)?.resources[\(name)];",
                    "if (\(resource) == undefined) { console.error(\"Could not find audio resource\"); } else {",
                    "    \(controller) = \(prepare) ? \(target).prepareAudio(\(resource)) : \(target).playAudio(\(resource));",
                    "}",
                ]
            }
            return lines
        }

        mutating func emitAudioControllerAction(
            _ node: RCP3ScriptGraph.Node,
            method: String,
            argumentPins: [String],
            context: ExprContext
        ) -> [String] {
            var seen: Set<String> = []
            let source = inputExpression(
                into: node, pinName: "source", context: context, seen: &seen,
                defaultValue: Expr("undefined")
            ).code
            let arguments = argumentPins.map { pin in
                inputExpression(
                    into: node, pinName: pin, context: context, seen: &seen,
                    defaultValue: Expr("0")
                ).code
            }
            return ["\(source).\(method)(\(arguments.joined(separator: ", ")));"]
        }

        mutating func emitAudioGroupPause(
            _ node: RCP3ScriptGraph.Node,
            context: ExprContext
        ) -> [String] {
            var seen: Set<String> = []
            let source = inputExpression(
                into: node, pinName: "source", context: context, seen: &seen,
                defaultValue: Expr("undefined")
            ).code
            let pause = inputExpression(
                into: node, pinName: "pause", context: context, seen: &seen,
                defaultValue: Expr("false")
            ).code
            return ["if (\(pause)) { \(source).pause(); } else { \(source).play(); }"]
        }

        mutating func emitTeleportCharacter(
            _ node: RCP3ScriptGraph.Node,
            context: ExprContext
        ) -> [String] {
            var seen: Set<String> = []
            let entity = inputExpression(
                into: node, pinName: "entity", context: context, seen: &seen,
                defaultValue: Expr("this.entity")
            ).code
            let to = inputExpression(into: node, pinName: "to", context: context, seen: &seen).code
            let relativeTo = inputExpression(
                into: node, pinName: "relativeTo", context: context, seen: &seen,
                defaultValue: Expr("null")
            ).code
            return ["\(entity).teleportCharacter(\(to), \(relativeTo));"]
        }

        mutating func emitEntityMove(
            _ node: RCP3ScriptGraph.Node,
            context: ExprContext
        ) -> [String] {
            usesRealityKit = true
            var seen: Set<String> = []
            let entity = inputExpression(
                into: node, pinName: "entity", context: context, seen: &seen,
                defaultValue: Expr("this.entity")
            ).code
            let relativeTo = inputExpression(
                into: node, pinName: "relativeTo", context: context, seen: &seen,
                defaultValue: Expr("null")
            ).code
            let scale = inputExpression(
                into: node, pinName: "scale", context: context, seen: &seen,
                defaultValue: Expr("\(entity).relativeScale(\(relativeTo))")
            ).code
            let orientation = inputExpression(
                into: node, pinName: "orientation", context: context, seen: &seen,
                defaultValue: Expr("\(entity).relativeOrientation(\(relativeTo))")
            ).code
            let position = inputExpression(
                into: node, pinName: "position", context: context, seen: &seen,
                defaultValue: Expr("\(entity).relativePosition(\(relativeTo))")
            ).code
            let duration = inputExpression(into: node, pinName: "duration", context: context, seen: &seen).code
            let timing = inputExpression(into: node, pinName: "timingFunction", context: context, seen: &seen).code
            return [
                "let \(Self.entityMoveControllerName(for: node)) = \(entity).move(new RealityKit.Transform(\(scale), \(orientation), \(position)), \(relativeTo), \(duration), \(timing));"
            ]
        }

        mutating func emitMoveCharacter(
            _ node: RCP3ScriptGraph.Node,
            context: ExprContext
        ) -> [String] {
            var seen: Set<String> = []
            let entity = inputExpression(
                into: node, pinName: "entity", context: context, seen: &seen,
                defaultValue: Expr("this.entity")
            ).code
            let by = inputExpression(into: node, pinName: "by", context: context, seen: &seen).code
            let deltaTime = inputExpression(into: node, pinName: "deltaTime", context: context, seen: &seen).code
            let relativeTo = inputExpression(
                into: node, pinName: "relativeTo", context: context, seen: &seen,
                defaultValue: Expr("null")
            ).code
            let names = Self.moveCharacterOutputPins.map {
                Self.moveCharacterOutputName(for: node, pin: $0)
            }
            let collisionBody = emitActionBody(
                after: node, context: context, outputPin: TMHash.murmur64a("collision")
            )
            var statements = [
                "\(entity).moveCharacter(\(by), \(deltaTime), \(relativeTo), (\(names.joined(separator: ", "))) => {",
            ]
            statements.append(contentsOf: Self.indent(collisionBody.isEmpty ? ["// no-op"] : collisionBody))
            statements.append("});")
            statements.append(contentsOf: emitActionBody(
                after: node, context: context, outputPin: CanonicalScriptGraphCompiler.unnamedExecPin
            ))
            return statements
        }

        /// Array Set is a contextual action, not a pure subscript expression. The
        /// shipped emitter aliases the input array to its typed output, bounds-checks
        /// `index`, mutates only when `0 <= index < array.length`, then continues exec.
        mutating func emitArraySet(_ node: RCP3ScriptGraph.Node, context: ExprContext) -> [String] {
            var seen: Set<String> = []
            guard let arrayPin = node.dynamicConnectorSettings?.inputs.first?.name else {
                return ["// unsupported node: tm_array_set (typed array connector missing)"]
            }
            let index = inputExpression(
                into: node, pinName: "index", context: context, seen: &seen
            ).code
            let array = inputExpression(
                into: node, pinName: arrayPin, context: context, seen: &seen
            ).code
            let element = inputExpression(
                into: node, pinName: "element", context: context, seen: &seen
            ).code
            let output = Self.arraySetOutputName(for: node)
            return [
                "let \(output) = \(array);",
                "if ((\(index)) >= 0 && (\(index)) < \(output).length) {",
                "    \(output)[\(index)] = \(element);",
                "}",
            ]
        }

        /// Array Add aliases the typed array output and calls `push(element)`.
        mutating func emitArrayAdd(_ node: RCP3ScriptGraph.Node, context: ExprContext) -> [String] {
            var seen: Set<String> = []
            guard let arrayPin = node.dynamicConnectorSettings?.inputs.first?.name else {
                return ["// unsupported node: tm_array_add (typed array connector missing)"]
            }
            let array = inputExpression(
                into: node, pinName: arrayPin, context: context, seen: &seen
            ).code
            let element = inputExpression(
                into: node, pinName: "element", context: context, seen: &seen
            ).code
            let output = Self.arrayMutationOutputName(for: node)
            return ["let \(output) = \(array);", "\(output).push(\(element));"]
        }

        /// Array Remove mirrors Set's bounds guard, then emits `splice(index, 1)`.
        mutating func emitArrayRemove(_ node: RCP3ScriptGraph.Node, context: ExprContext) -> [String] {
            var seen: Set<String> = []
            guard let arrayPin = node.dynamicConnectorSettings?.inputs.first?.name else {
                return ["// unsupported node: tm_array_remove (typed array connector missing)"]
            }
            let index = inputExpression(
                into: node, pinName: "index", context: context, seen: &seen
            ).code
            let array = inputExpression(
                into: node, pinName: arrayPin, context: context, seen: &seen
            ).code
            let output = Self.arrayMutationOutputName(for: node)
            return [
                "let \(output) = \(array);",
                "if ((\(index)) >= 0 && (\(index)) < \(output).length) {",
                "    \(output).splice(\(index), 1);",
                "}",
            ]
        }

        mutating func emitArrayForEach(_ node: RCP3ScriptGraph.Node, context: ExprContext) -> [String] {
            var seen: Set<String> = []
            guard let arrayPin = node.dynamicConnectorSettings?.inputs.first?.name else {
                return ["// unsupported node: tm_array_for_each (typed array connector missing)"]
            }
            let array = inputExpression(
                into: node, pinName: arrayPin, context: context, seen: &seen
            ).code
            let index = Self.arrayForEachIndexName(for: node)
            let stepBody = emitActionBody(
                after: node, context: context, outputPin: CanonicalScriptGraphCompiler.stepPin
            )
            var statements = ["for (let \(index) = 0; \(index) < (\(array)).length; \(index) += 1) {"]
            statements.append(contentsOf: Self.indent(stepBody.isEmpty ? ["// no-op"] : stepBody))
            statements.append("}")
            statements.append(contentsOf: emitActionBody(
                after: node, context: context, outputPin: CanonicalScriptGraphCompiler.endPin
            ))
            return statements
        }

        /// Array Find performs an element-type-aware equality test in Apple's AST:
        /// primitives use `==`, schema objects use `.equals`. The runtime guard below
        /// selects the same operation without needing private TypeManagement metadata.
        mutating func emitArrayFind(_ node: RCP3ScriptGraph.Node, context: ExprContext) -> [String] {
            var seen: Set<String> = []
            guard let arrayPin = node.dynamicConnectorSettings?.inputs.first?.name else {
                return ["// unsupported node: tm_array_find (typed array connector missing)"]
            }
            let array = inputExpression(
                into: node, pinName: arrayPin, context: context, seen: &seen
            ).code
            let search = inputExpression(
                into: node, pinName: "searchValue", context: context, seen: &seen
            ).code
            let index = Self.arrayFindIndexName(for: node)
            let element = Self.arrayFindElementName(for: node)
            let candidate = "__d3_array_candidate_\(Self.sanitize(node.id))"
            let foundBody = emitActionBody(
                after: node, context: context, outputPin: TMHash.murmur64a("found")
            )
            let notFoundBody = emitActionBody(
                after: node, context: context, outputPin: TMHash.murmur64a("not found")
            )
            var statements = [
                "let \(index) = -1;",
                "let \(element);",
                "for (let i = 0; i < (\(array)).length; i += 1) {",
                "    const \(candidate) = (\(array))[i];",
                "    if ((\(candidate) && typeof \(candidate).equals === \"function\") ? \(candidate).equals(\(search)) : \(candidate) == (\(search))) {",
                "        \(index) = i;",
                "        \(element) = \(candidate);",
            ]
            statements.append(contentsOf: Self.indent(foundBody, by: "        "))
            statements.append("        return;")
            statements.append("    }")
            statements.append("}")
            statements.append(contentsOf: notFoundBody)
            return statements
        }

        /// A Set Component action: write a Transform property fed by a data wire —
        /// `translation` → `.position`, `rotation` → `.orientation`, `scale` → `.scale`.
        /// If the node has no property value wire but does carry a known `component_type`
        /// selector, attach that default component via the documented `setComponent`.
        mutating func emitSetComponent(
            _ node: RCP3ScriptGraph.Node,
            context: ExprContext
        ) -> [String] {
            let target = context == .gesture ? "event.entity" : "this.entity"
            var statements: [String] = []

            let selectedCapability = componentRuntimeCapability(for: node)
            let propertyMutations: [ScriptGraphComponentRuntimeCapabilities.PropertyMutation]
            if case let .entityProperties(properties) = selectedCapability?.strategy {
                propertyMutations = properties
            } else if selectedCapability == nil && hasTransformPropertyInput(node) {
                // Legacy/captured graphs may omit the selector while still wiring one
                // of Transform's distinctive property pins. Preserve that established
                // lowering without pretending an arbitrary bare Set has a component.
                propertyMutations = Self.transformPropertyMutations
            } else {
                propertyMutations = []
            }

            for mutation in propertyMutations {
                let pin = TMHash.murmur64a(mutation.connectorName)
                let property = mutation.entityPropertyName
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
                if let selectedCapability,
                   selectedCapability.strategy == .defaultConstructor {
                    usesRealityKit = true
                    statements.append("\(target).setComponent(new RealityKit.\(selectedCapability.componentName)());")
                    return statements
                }
                if let selectedHash = selectedComponentTypeHash(for: node) {
                    statements.append("// unsupported node: tm_set_component (selected component \(TMHash.hex(selectedHash)) has no certified public JS mutation contract)")
                } else {
                    statements.append("// unsupported node: tm_set_component (component type not selected)")
                }
            }
            return statements
        }

        func selectedComponentTypeHash(for node: RCP3ScriptGraph.Node) -> UInt64? {
            graph.data.first(where: {
                $0.toNode == node.id && $0.toPin == CanonicalScriptGraphCompiler.componentTypePin
            })?.valueHash
        }

        func componentRuntimeCapability(for node: RCP3ScriptGraph.Node) -> ScriptGraphComponentRuntimeCapabilities.Capability? {
            selectedComponentTypeHash(for: node).flatMap(
                ScriptGraphComponentRuntimeCapabilities.capability(forTypeHash:)
            )
        }

        func hasTransformPropertyInput(_ node: RCP3ScriptGraph.Node) -> Bool {
            Self.transformPropertyMutations.contains { mutation in
                let pin = TMHash.murmur64a(mutation.connectorName)
                return dataWire(into: node.id, pin: pin) != nil
            }
        }

        /// RCP's material writers do not mutate a detached material and stop there.
        /// They retrieve the entity's ModelComponent and material slot, mutate the
        /// material, put it back in the component, then put the component back on the
        /// entity. This apparently redundant write-back is part of the shipped emitter.
        mutating func emitSetMaterialParameter(
            _ node: RCP3ScriptGraph.Node,
            context: ExprContext
        ) -> [String] {
            var seen: Set<String> = []
            let entity = inputExpression(
                into: node, pinName: "entity", context: context, seen: &seen,
                defaultValue: Expr("this.entity")
            ).code
            let slot = materialSlotExpression(into: node, context: context, seen: &seen)
            let parameter = inputExpression(
                into: node, pinName: "parameter", context: context, seen: &seen,
                defaultValue: Expr("undefined")
            ).code
            let value = inputExpression(
                into: node, pinName: "value", context: context, seen: &seen,
                defaultValue: Expr("undefined")
            ).code
            let suffix = Self.sanitize(node.id)
            let component = "__d3_model_component_\(suffix)"
            let material = "__d3_material_\(suffix)"
            usesRealityKit = true
            return [
                "const \(component) = \(entity).getComponent(RealityKit.ModelComponent.Type);",
                "if (\(component) == null) { console.error(\"Set Material Parameter: ModelComponent not found\"); return; }",
                "const \(material) = \(component).getMaterial(\(slot));",
                "if (\(material) == null) { console.error(\"Set Material Parameter: material not found\"); return; }",
                "if (\(parameter) == null) { console.error(\"Set Material Parameter: parameter not found\"); return; }",
                "\(material).setParameter(\(parameter), \(value));",
                "\(component).setMaterial(\(material), \(slot));",
                "\(entity).setComponent(\(component));",
            ]
        }

        /// Lowers RCP's settings-selected Entity Parameter writer. The shipped
        /// emitter passes one object literal to `Entity.setParameter`; its `type`
        /// member is the lowercase primitive name selected by the node's dedicated
        /// `tm_entity_parameter_node_settings` record.
        mutating func emitSetEntityParameter(
            _ node: RCP3ScriptGraph.Node,
            context: ExprContext
        ) -> [String] {
            guard let type = Self.entityParameterPrimitiveName(for: node) else {
                return ["// unsupported node: tm_set_entity_parameter (unsupported or missing parameter type)"]
            }
            var seen: Set<String> = []
            let entity = inputExpression(
                into: node, pinName: "entity", context: context, seen: &seen,
                defaultValue: Expr("this.entity")
            ).code
            let name = inputExpression(
                into: node, pinName: "name", context: context, seen: &seen,
                defaultValue: Expr("undefined")
            ).code
            let value = inputExpression(
                into: node, pinName: "value", context: context, seen: &seen,
                defaultValue: Expr("undefined")
            ).code
            return ["\(entity).setParameter({ name: \(name), type: \(Self.renderJSString(type)), value: \(value) });"]
        }

        mutating func emitModifyAnyMaterial(
            _ node: RCP3ScriptGraph.Node,
            context: ExprContext
        ) -> [String] {
            guard let settings = node.materialSettings else {
                return ["// unsupported node: tm_modify_any_material (material settings missing)"]
            }
            var seen: Set<String> = []
            let entity = inputExpression(
                into: node, pinName: "entity", context: context, seen: &seen,
                defaultValue: Expr("this.entity")
            ).code
            let slot = materialSlotExpression(into: node, context: context, seen: &seen)
            let suffix = Self.sanitize(node.id)
            let component = "__d3_model_component_\(suffix)"
            let material = Self.modifiedMaterialName(for: node)
            usesRealityKit = true
            var statements = [
                "const \(component) = \(entity).getComponent(RealityKit.ModelComponent.Type);",
                "if (\(component) == null) { console.error(\"Modify Material: ModelComponent not found\"); return; }",
                "const \(material) = \(component).getMaterial(\(slot));",
                "if (\(material) == null) { console.error(\"Modify Material: material not found\"); return; }",
            ]
            for property in settings.inputs {
                // `writeMaterialProperties(... writes_inputs: true)` only records
                // writable Inspectable descriptors; the serialized settings list is
                // therefore the source of truth for this generated assignment set.
                let value = inputExpression(
                    into: node, pinName: property.name, context: context, seen: &seen,
                    defaultValue: Expr("undefined")
                ).code
                if property.isOptional {
                    statements.append("if (\(value) !== undefined) { \(material).\(property.name) = \(value); }")
                } else {
                    statements.append("\(material).\(property.name) = \(value);")
                }
            }
            statements.append("\(component).setMaterial(\(material), \(slot));")
            statements.append("\(entity).setComponent(\(component));")
            return statements
        }

        mutating func materialSlotExpression(
            into node: RCP3ScriptGraph.Node,
            context: ExprContext,
            seen: inout Set<String>
        ) -> String {
            let pin = hasDataInput(into: node, pinName: "slot") ? "slot" : "index"
            return inputExpression(
                into: node, pinName: pin, context: context, seen: &seen,
                defaultValue: Expr("0")
            ).code
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
            } else if let value = graph.literal(node: node.id, pin: valuePin) {
                valueExpr = Self.renderValue(value)
            } else {
                valueExpr = "undefined /* no value wired */"
            }
            // A remote reference is a distinct `tm_graph_remote_variable_ref`, not a
            // local variable name. Apple's emitter resolves its serialized
            // `{ entity, ref, name }` into a runtime `{ entity, variable }`, then uses
            // the three-argument storage-bag ABI
            // `setRemoteValue(target, "data_storage", bag)`. Until that identity
            // conversion is captured, emitting the local-name shortcut here would be
            // fabricated behavior.
            if node.type == "tm_set_remote_variable_node" {
                return ["// unsupported node: tm_set_remote_variable_node (remote-variable identity unresolved)"]
            }
            if let name = node.variableName {
                let slot = CanonicalScriptGraphCompiler.variableSlot(for: name)
                return ["this.\(slot) = \(valueExpr);"]
            }
            return ["// unsupported node: \(node.type) (variable-name reference not resolvable here)"]
        }

        /// A variable-clear action. A LOCAL variable resets its slot to the numeric
        /// default: `this.variable_<slot> = 0;`. Without a name it stays an honest no-op.
        func emitClearVariable(_ node: RCP3ScriptGraph.Node) -> [String] {
            if node.type == "tm_clear_remote_variable_node" {
                return ["// unsupported node: tm_clear_remote_variable_node (remote-variable identity unresolved)"]
            }
            if let name = node.variableName {
                let slot = CanonicalScriptGraphCompiler.variableSlot(for: name)
                return ["this.\(slot) = 0;"]
            }
            return ["// unsupported node: \(node.type) (variable-name reference not resolvable here)"]
        }

        /// Shared lowering for Apple's `registerVariableMathOperations` family.
        /// The shipped emitter resolves one variable reference, evaluates one
        /// operation-specific operand, assigns the result back to that variable,
        /// and exposes the updated value on `result`.
        mutating func emitVariableMutation(
            _ node: RCP3ScriptGraph.Node,
            context: ExprContext
        ) -> [String] {
            guard let name = node.variableName else {
                return ["// unsupported node: \(node.type) (variable-name reference not resolvable here)"]
            }
            let descriptor: (pin: String, operation: String, alwaysMath3D: Bool)
            switch node.type {
            case "tm_variable_add": descriptor = ("value", "add", false)
            case "tm_variable_subtract": descriptor = ("value", "subtract", false)
            case "tm_variable_multiply": descriptor = ("value", "multiply", false)
            case "tm_variable_divide": descriptor = ("value", "divide", false)
            case "tm_variable_multiply_by_scalar": descriptor = ("scalar", "multiply", true)
            case "tm_variable_multiply_by_quaternion": descriptor = ("quaternion", "multiply", true)
            case "tm_variable_multiply_by_matrix": descriptor = ("matrix", "multiply", true)
            default: return ["// unsupported node: \(node.type)"]
            }

            var seen: Set<String> = []
            let operand = inputExpression(
                into: node, pinName: descriptor.pin, context: context, seen: &seen
            )
            let slot = "this.\(CanonicalScriptGraphCompiler.variableSlot(for: name))"
            let current = "(\(slot) ?? 0)"
            let expression: String
            if descriptor.alwaysMath3D || operand.isVector {
                usesMath3D = true
                expression = "Math3D.\(descriptor.operation)(\(current), \(operand.code))"
            } else {
                let symbol: String
                switch descriptor.operation {
                case "add": symbol = "+"
                case "subtract": symbol = "-"
                case "multiply": symbol = "*"
                case "divide": symbol = "/"
                default: symbol = "+"
                }
                expression = "\(current) \(symbol) \(operand.code)"
            }
            return ["\(slot) = \(expression);"]
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
            /// Inside a non-gesture event hook: outputs are `event.<pin>`, but the
            /// default action target remains `this.entity`.
            case event
            /// Inside `this.update(deltaTime)`: `deltaTime` is in scope.
            case update
            /// Inside a plain lifecycle hook: no gesture/update locals in scope.
            case lifecycle
        }

        /// The data wire feeding `pin` of node `nodeID`, if any.
        func dataWire(into nodeID: String, pin: UInt64) -> RCP3ScriptGraph.Wire? {
            graph.wires.first { !$0.isExec && $0.to == nodeID && $0.toPin == pin }
        }

        func hasDataInput(into node: RCP3ScriptGraph.Node, pinName: String) -> Bool {
            let pin = TMHash.murmur64a(pinName)
            return dataWire(into: node.id, pin: pin) != nil || graph.literal(node: node.id, pin: pin) != nil
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

            if node.type == "tm_array_for_each" {
                let index = Self.arrayForEachIndexName(for: node)
                if outputPin == CanonicalScriptGraphCompiler.indexPin { return Expr(index) }
                if outputPin == TMHash.murmur64a("element"),
                   let arrayPin = node.dynamicConnectorSettings?.inputs.first?.name {
                    let array = inputExpression(
                        into: node, pinName: arrayPin, context: context, seen: &seen
                    )
                    return Expr("(\(array.code))[\(index)]")
                }
            }

            if node.type == "tm_array_find" {
                if outputPin == CanonicalScriptGraphCompiler.indexPin {
                    return Expr(Self.arrayFindIndexName(for: node))
                }
                if outputPin == TMHash.murmur64a("element") {
                    return Expr(Self.arrayFindElementName(for: node))
                }
            }

            if node.type == "tm_delay", outputPin == CanonicalScriptGraphCompiler.cancelIDPin {
                return Expr("this.\(Self.delayCancelSlot(for: node))")
            }

            if node.type == "tm_self" {
                return Expr("this.entity")
            }

            if node.type == "tm_scene" {
                return Expr("this.entity.scene")
            }

            if node.type == "tm_math_inverse" {
                usesMath3D = true
                let value = inputExpression(
                    into: node, pinName: "value", context: context, seen: &seen
                )
                return Expr("Math3D.inverse(\(value.code))")
            }

            if node.type == "tm_is_head_tracking_available" {
                return Expr("this.input.worldTrackingDataAvailable")
            }
            if node.type == "tm_is_hand_tracking_available" {
                return Expr("this.input.handTrackingDataAvailable")
            }
            if node.type == "tm_input_get_keyboard" { return Expr("this.input.keyboard") }
            if node.type == "tm_input_get_mouse" { return Expr("this.input.mouse") }
            if node.type == "tm_input_get_gamepad" {
                if hasDataInput(into: node, pinName: "player") {
                    let player = inputExpression(
                        into: node, pinName: "player", context: context, seen: &seen
                    ).code
                    return Expr("this.input.players[\(player)]")
                }
                return Expr("this.input.current")
            }
            if node.type == "tm_input_gamepad_axes" {
                let receiver = inputExpression(
                    into: node, pinName: "gamepad", context: context, seen: &seen,
                    defaultValue: Expr("this.input.controllers.current")
                ).code
                let names = ["leftThumbstickAxes", "rightThumbstickAxes", "leftTriggerPressure", "rightTriggerPressure"]
                let member = names.first { outputPin == TMHash.murmur64a($0) } ?? names[0]
                return Expr("\(receiver).\(member)", isVector: member.hasSuffix("Axes"))
            }
            if node.type == "tm_input_gamepad_button" || node.type == "tm_input_mouse_button" {
                let receiverPin = node.type == "tm_input_gamepad_button" ? "gamepad" : "mouse"
                let fallback = node.type == "tm_input_gamepad_button"
                    ? "this.input.controllers.current" : "this.input.mouse.connected"
                let receiver = inputExpression(
                    into: node, pinName: receiverPin, context: context, seen: &seen,
                    defaultValue: Expr(fallback)
                ).code
                let selector = inputExpression(
                    into: node, pinName: "button", context: context, seen: &seen
                ).code
                let button: String
                if node.type == "tm_input_mouse_button" {
                    // RCP's enum setting uses raw 2 = right, 3 = middle, default = left.
                    button = "(\(selector) == 2 ? \(receiver).rightButton : (\(selector) == 3 ? \(receiver).middleButton : \(receiver).leftButton))"
                } else {
                    // Gamepad settings resolve their UInt64 case hash through RCP's
                    // member-name table; authored connector values carry that member.
                    button = "\(receiver)[\(selector)]"
                }
                let names = ["down", "pressed", "released", "pressCount"]
                let member = names.first { outputPin == TMHash.murmur64a($0) } ?? names[0]
                let defaultValue = member == "pressCount" ? "0" : "false"
                return Expr("(\(button)?.\(member) ?? \(defaultValue))")
            }
            if node.type == "tm_input_keyboard_key" {
                let keyboard = inputExpression(
                    into: node, pinName: "keyboard", context: context, seen: &seen,
                    defaultValue: Expr("this.input.keyboard")
                ).code
                let key = inputExpression(into: node, pinName: "key", context: context, seen: &seen).code
                let names = ["down", "pressed", "released", "pressesCount"]
                let member = names.first { outputPin == TMHash.murmur64a($0) } ?? names[0]
                return Expr("\(keyboard).key(\(key)).\(member)")
            }
            if node.type == "tm_input_mouse_motion" {
                let mouse = inputExpression(
                    into: node, pinName: "mouse", context: context, seen: &seen,
                    defaultValue: Expr("this.input.mouse")
                ).code
                return Expr("\(mouse).delta", isVector: true)
            }
            if node.type == "tm_head_tracking" {
                let member = outputPin == TMHash.murmur64a("orientation")
                    ? "orientation" : "position"
                return Expr("this.input.getDeviceTransform().\(member)", isVector: member == "position")
            }
            if node.type == "tm_hand_joint" {
                let hand = inputExpression(
                    into: node, pinName: "hand", context: context, seen: &seen
                ).code
                let joint = inputExpression(
                    into: node, pinName: "joint", context: context, seen: &seen
                ).code
                let member = outputPin == TMHash.murmur64a("orientation")
                    ? "orientation" : "position"
                return Expr(
                    "this.input.getJointTransform(\(hand), \(joint)).\(member)",
                    isVector: member == "position"
                )
            }
            if node.type == "tm_get_material" {
                let entity = inputExpression(
                    into: node, pinName: "entity", context: context, seen: &seen,
                    defaultValue: Expr("this.entity")
                ).code
                let index = inputExpression(
                    into: node, pinName: "index", context: context, seen: &seen,
                    defaultValue: Expr("0")
                ).code
                return Expr("\(entity).getComponent(\"RealityKit.ModelComponent\").materials[\(index)]")
            }
            if node.type == "tm_get_material_parameter" {
                let entity = inputExpression(
                    into: node, pinName: "entity", context: context, seen: &seen,
                    defaultValue: Expr("this.entity")
                ).code
                let slot = materialSlotExpression(into: node, context: context, seen: &seen)
                let parameter = inputExpression(
                    into: node, pinName: "parameter", context: context, seen: &seen,
                    defaultValue: Expr("undefined")
                ).code
                usesRealityKit = true
                // The guards and undefined result mirror the shipped emitter's three
                // failure paths while keeping this value node usable as an expression.
                return Expr(
                    "(() => { const component = \(entity).getComponent(RealityKit.ModelComponent.Type); "
                    + "if (component == null) { console.error(\"Get Material Parameter: ModelComponent not found\"); return undefined; } "
                    + "const material = component.getMaterial(\(slot)); "
                    + "if (material == null) { console.error(\"Get Material Parameter: material not found\"); return undefined; } "
                    + "if (\(parameter) == null) { console.error(\"Get Material Parameter: parameter not found\"); return undefined; } "
                    + "return material.getParameter(\(parameter)); })()"
                )
            }
            if node.type == "tm_get_entity_parameter" {
                guard let type = Self.entityParameterPrimitiveName(for: node) else {
                    return Expr("undefined /* unsupported or missing Entity Parameter type */")
                }
                let entity = inputExpression(
                    into: node, pinName: "entity", context: context, seen: &seen,
                    defaultValue: Expr("this.entity")
                ).code
                let name = inputExpression(
                    into: node, pinName: "name", context: context, seen: &seen,
                    defaultValue: Expr("undefined")
                ).code
                return Expr("\(entity).getParameter(\(name), \(Self.renderJSString(type)))")
            }
            if node.type == "tm_modify_any_material",
               let property = node.materialSettings?.outputs.first(where: {
                   outputPin == TMHash.murmur64a($0.name)
               }) {
                return Expr("\(Self.modifiedMaterialName(for: node)).\(property.name)")
            }
            if node.type == "tm_scene_raycast_v2" || node.type == "tm_scene_convex_cast" {
                guard let outputPin,
                      let name = ["entity", "position", "normal"].first(where: {
                          TMHash.murmur64a($0) == outputPin
                      }) else { return Expr("undefined") }
                return Expr("\(Self.sceneCastHitName(for: node)).\(name)", isVector: name != "entity")
            }
            if node.type == "tm_play_animation_by_name" || node.type == "tm_play_animation_by_index" {
                return Expr(Self.animationControllerName(for: node))
            }

            if node.type == "tm_make_font" {
                usesFoundation = true
                let size = inputExpression(
                    into: node, pinName: "size", context: context, seen: &seen,
                    defaultValue: Expr("16")
                ).code
                var font: String
                if hasDataInput(into: node, pinName: "name") {
                    let name = inputExpression(
                        into: node, pinName: "name", context: context, seen: &seen
                    ).code
                    font = "new Foundation.Font(\(name), \(size))"
                } else {
                    font = "Foundation.Font.systemFont(\(size))"
                }
                if hasDataInput(into: node, pinName: "weight") {
                    let weight = inputExpression(
                        into: node, pinName: "weight", context: context, seen: &seen
                    ).code
                    font = "\(font).boldFont(\(weight))"
                }
                for (pin, member) in [
                    ("italic", "italicFont"),
                    ("monospaced", "monospacedFont"),
                    ("monospacedDigit", "monospacedDigitFont"),
                ] where hasDataInput(into: node, pinName: pin) {
                    let enabled = inputExpression(
                        into: node, pinName: pin, context: context, seen: &seen
                    ).code
                    font = "(\(enabled) ? \(font).\(member)() : \(font))"
                }
                return Expr(font)
            }

            if node.type == "tm_make_attributed_string" {
                usesFoundation = true
                let text = inputExpression(
                    into: node, pinName: "Text", context: context, seen: &seen,
                    defaultValue: Expr("\"\"")
                ).code
                var statements = ["let value = new Foundation.AttributedString(\(text));"]
                for property in ["font", "alignment", "foregroundColor", "backgroundColor"]
                where hasDataInput(into: node, pinName: property) {
                    let value = inputExpression(
                        into: node, pinName: property, context: context, seen: &seen
                    ).code
                    statements.append("value.\(property) = \(value);")
                }
                statements.append("return value;")
                return Expr("(() => { \(statements.joined(separator: " ")) })()")
            }
            if node.type == "tm_attributed_string_size" {
                usesCoreGraphics = true
                let string = inputExpression(into: node, pinName: "string", context: context, seen: &seen).code
                let base: String
                if hasDataInput(into: node, pinName: "maxWidth") {
                    let width = inputExpression(into: node, pinName: "maxWidth", context: context, seen: &seen).code
                    base = "\(string).size(new CoreGraphics.CGSize(\(width), 0))"
                } else {
                    base = "\(string).size()"
                }
                guard hasDataInput(into: node, pinName: "padding") else { return Expr(base) }
                let padding = inputExpression(into: node, pinName: "padding", context: context, seen: &seen).code
                return Expr("(() => { let size = \(base); size.width += \(padding).width; size.height += \(padding).height; return size; })()")
            }

            if node.type == "tm_play_audio_by_name" ||
                node.type == "tm_play_audio_group_by_name" {
                return Expr(Self.namedAudioControllerName(for: node))
            }

            if node.type == "tm_entity_convert_matrix_to" ||
                node.type == "tm_entity_convert_matrix_from" {
                usesRealityKit = true
                let entity = inputExpression(
                    into: node, pinName: "entity", context: context, seen: &seen,
                    defaultValue: Expr("this.entity")
                )
                let matrix = inputExpression(
                    into: node, pinName: "matrix", context: context, seen: &seen
                )
                if node.type == "tm_entity_convert_matrix_to" {
                    let target = inputExpression(
                        into: node, pinName: "toEntity", context: context, seen: &seen,
                        defaultValue: Expr("null")
                    )
                    return Expr("\(entity.code).convertMatrixTo(\(matrix.code), \(target.code))")
                }
                let source = inputExpression(
                    into: node, pinName: "fromEntity", context: context, seen: &seen,
                    defaultValue: Expr("null")
                )
                return Expr(
                    "\(entity.code).convertTransformFrom(new RealityKit.Transform(\(matrix.code)), \(source.code)).matrix"
                )
            }

            let coordinateConversions: [String: (value: String, peer: String, method: String)] = [
                "tm_entity_convert_direction_to": ("direction", "toEntity", "convertDirectionTo"),
                "tm_entity_convert_direction_from": ("direction", "fromEntity", "convertDirectionFrom"),
                "tm_entity_convert_normal_to": ("normal", "toEntity", "convertNormalTo"),
                "tm_entity_convert_normal_from": ("normal", "fromEntity", "convertNormalFrom"),
                "tm_entity_convert_position_to": ("position", "toEntity", "convertPositionTo"),
                "tm_entity_convert_position_from": ("position", "fromEntity", "convertPositionFrom"),
            ]
            if let conversion = coordinateConversions[node.type] {
                let entity = inputExpression(
                    into: node, pinName: "entity", context: context, seen: &seen,
                    defaultValue: Expr("this.entity")
                )
                let value = inputExpression(
                    into: node, pinName: conversion.value, context: context, seen: &seen
                )
                let peer = inputExpression(
                    into: node, pinName: conversion.peer, context: context, seen: &seen,
                    defaultValue: Expr("null")
                )
                return Expr("\(entity.code).\(conversion.method)(\(value.code), \(peer.code))")
            }

            if node.type == "tm_entity_move" {
                return Expr(Self.entityMoveControllerName(for: node))
            }

            if node.type == "tm_entity_move_character",
               let pin = Self.moveCharacterOutputPins.first(where: {
                   TMHash.murmur64a($0) == outputPin
               }) {
                return Expr(Self.moveCharacterOutputName(for: node, pin: pin))
            }

            if node.type == "tm_is_valid_branch",
               let input = node.dynamicConnectorSettings?.inputs.first?.name,
               outputPin == TMHash.murmur64a(input) {
                return inputExpression(
                    into: node, pinName: input, context: context, seen: &seen
                )
            }

            if node.type == "tm_entity_equals" {
                let a = inputExpression(
                    into: node, pinName: "a", context: context, seen: &seen
                )
                let b = inputExpression(
                    into: node, pinName: "b", context: context, seen: &seen
                )
                // Entity is a schema object. TypeManagement's non-primitive equality
                // branch (also used by Array Find) dispatches through `.equals`.
                return Expr("(\(a.code)).equals(\(b.code))")
            }

            if node.type == "tm_entity_get_relative_transform" {
                let entity = inputExpression(
                    into: node, pinName: "entity", context: context, seen: &seen,
                    defaultValue: Expr("this.entity")
                )
                let relativeTo = inputExpression(
                    into: node, pinName: "relativeTo", context: context, seen: &seen,
                    defaultValue: Expr("null")
                )
                let method: String
                switch outputPin {
                case TMHash.murmur64a("scale"): method = "relativeScale"
                case TMHash.murmur64a("orientation"): method = "relativeOrientation"
                case TMHash.murmur64a("position"): method = "relativePosition"
                default: method = "relativeTransformMatrix"
                }
                return Expr("\(entity.code).\(method)(\(relativeTo.code))", isVector: true)
            }

            if node.type == "tm_entity_get_local_direction_vectors"
                || node.type == "tm_entity_get_world_direction_vectors" {
                let entity = inputExpression(
                    into: node, pinName: "entity", context: context, seen: &seen,
                    defaultValue: Expr("this.entity")
                )
                let axis: String
                switch outputPin {
                case TMHash.murmur64a("up"): axis = "Up"
                case TMHash.murmur64a("right"): axis = "Right"
                default: axis = "Forward"
                }
                let space = node.type.contains("_world_") ? "world" : "local"
                return Expr("\(entity.code).\(space)\(axis)", isVector: true)
            }

            if node.type == "tm_find_entity" {
                let source = inputExpression(into: node, pinName: "entity", context: context, seen: &seen, defaultValue: Expr("this.entity"))
                let name = inputExpression(into: node, pinName: "name", context: context, seen: &seen)
                if hasDataInput(into: node, pinName: "recursive") {
                    let recursive = inputExpression(into: node, pinName: "recursive", context: context, seen: &seen).code
                    return Expr("\(source.code).findEntity(\(name.code), \(recursive))")
                }
                return Expr("\(source.code).findEntity(\(name.code))")
            }

            if node.type == "tm_clone" {
                if graph.wires.contains(where: { $0.to == node.id && $0.isExec }) {
                    return Expr(Self.clonedEntityName(for: node))
                }
                let source = inputExpression(
                    into: node, pinName: "source", context: context, seen: &seen,
                    defaultValue: Expr("this.entity")
                )
                if hasDataInput(into: node, pinName: "recursive") {
                    let recursive = inputExpression(
                        into: node, pinName: "recursive", context: context, seen: &seen
                    )
                    return Expr("\(source.code).clone(\(recursive.code))")
                }
                return Expr("\(source.code).clone()")
            }

            if node.type == "tm_find_parent_entity" {
                let source = inputExpression(into: node, pinName: "entity", context: context, seen: &seen, defaultValue: Expr("this.entity"))
                let name = inputExpression(into: node, pinName: "name", context: context, seen: &seen)
                return Expr("\(source.code).findParent(\(name.code))")
            }

            if node.type == "tm_find_scene_entity" {
                // The shipped contextual emitter treats the
                // `tm_local_entity_asset_reference` connector as an already
                // resolved Entity expression. It forwards connector 0 (`name`)
                // directly to connector 0 (`entity`), declaring the output when
                // no destination variable exists; it does not search by String.
                return inputExpression(
                    into: node,
                    pinName: "name",
                    context: context,
                    seen: &seen,
                    defaultValue: Expr("undefined")
                )
            }

            if node.type == "tm_spawn_entity" {
                return Expr(Self.spawnedEntityName(for: node))
            }

            if node.type == "tm_find_entity_with_component" {
                let source = inputExpression(into: node, pinName: "entity", context: context, seen: &seen, defaultValue: Expr("this.entity"))
                let component = inputExpression(into: node, pinName: "component_type", context: context, seen: &seen)
                return Expr("\(source.code).findEntityWithComponent(\(component.code))")
            }

            if node.type == "tm_has_component" {
                let source = inputExpression(into: node, pinName: "source", context: context, seen: &seen, defaultValue: Expr("this.entity"))
                let component = inputExpression(into: node, pinName: "component_type", context: context, seen: &seen)
                return Expr("\(source.code).hasComponent(\(component.code))")
            }

            if node.type == "tm_get_parent" {
                let source = inputExpression(into: node, pinName: "source", context: context, seen: &seen, defaultValue: Expr("this.entity"))
                return Expr("\(source.code).parent")
            }

            if node.type == "tm_get_children" {
                let source = inputExpression(into: node, pinName: "source", context: context, seen: &seen, defaultValue: Expr("this.entity"))
                return Expr("\(source.code).children")
            }

            if node.type == "tm_entity_get_world_transform" {
                let entity = inputExpression(into: node, pinName: "entity", context: context, seen: &seen, defaultValue: Expr("this.entity"))
                let output = outputPin.flatMap(Self.gestureOutputName(forHash:)) ?? "matrix"
                let property: String
                switch output {
                case "scale": property = "worldScale"
                case "orientation": property = "worldOrientation"
                case "position": property = "worldPosition"
                case "matrix": property = "worldTransformMatrix"
                default: property = "worldTransformMatrix"
                }
                return Expr("\(entity.code).\(property)", isVector: ["scale", "position"].contains(output))
            }

            // Math constants are scalars.
            if let constant = Self.mathConstant(for: node.type) {
                return Expr(constant)
            }

            if node.type == "tm_is_valid" {
                guard let input = node.dynamicConnectorSettings?.inputs.first?.name else {
                    return Expr("false /* typed input missing */")
                }
                let value = inputExpression(
                    into: node, pinName: input, context: context, seen: &seen
                ).code
                return Expr("(" + value + " !== undefined && " + value + " !== null)")
            }

            // `tm_constant` literal: the value is node settings, not a wire — emit 0.
            if node.type == "tm_constant" {
                return Expr("0 /* tm_constant literal (value in node settings) */")
            }

            if node.type == "tm_constant_bitset" {
                // This emitter is intentionally compile-time: Apple's contextual
                // emitter reads each data-only Bool literal and ORs its bit into an
                // Int. Connector 0 is `count`; connector i+1 is bit i.
                let count = Int(graph.literal(
                    node: node.id,
                    pin: TMHash.murmur64a("count")
                )?.number ?? 0)
                let clampedCount = min(max(count, 0), 32)
                let value = (0..<clampedCount).reduce(0) { result, index in
                    guard graph.literal(
                        node: node.id,
                        pin: TMHash.murmur64a(String(index))
                    )?.bool == true else { return result }
                    return result | (1 << index)
                }
                return Expr(String(value))
            }

            if node.type == "tm_bool_to_any" {
                let condition = inputExpression(
                    into: node, pinName: "bool", context: context, seen: &seen
                ).code
                let whenTrue = inputExpression(
                    into: node, pinName: "true", context: context, seen: &seen
                ).code
                let whenFalse = inputExpression(
                    into: node, pinName: "false", context: context, seen: &seen
                ).code
                return Expr("(" + condition + " ? " + whenTrue + " : " + whenFalse + ")")
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
                let operands = mathOperands(of: node, context: context, seen: &seen)
                return operands.dropFirst().reduce(operands[0]) { partial, next in
                    emitBinaryMath(node.type, op: op, a: partial, b: next)
                }
            }

            if node.type == "tm_math_clamp" {
                let a = inputExpression(into: node, pinName: "a", context: context, seen: &seen)
                let lo = inputExpression(into: node, pinName: "min", context: context, seen: &seen)
                let hi = inputExpression(into: node, pinName: "max", context: context, seen: &seen)
                return Expr("Math.min(Math.max(\(a.code), \(lo.code)), \(hi.code))")
            }

            // Interpolation ops → `Math3D.<fn>(a, b, factor)`, the observed emission (same
            // `Math3D.<name>` convention as the dot/cross/normal vector ops above). The
            // factor pin is `t` for lerp/slerp and `x` for smoothstep. Result can be a
            // vector/quaternion, so it propagates as a vector.
            if let interp = Self.interpolationOp(for: node.type) {
                usesMath3D = true
                let a = inputExpression(into: node, pinName: "a", context: context, seen: &seen)
                let b = inputExpression(into: node, pinName: "b", context: context, seen: &seen)
                let factor = inputExpression(into: node, pinName: interp.factorPin, context: context, seen: &seen)
                return Expr("Math3D.\(interp.function)(\(a.code), \(b.code), \(factor.code))", isVector: true)
            }

            // Captured Bool/String literal nodes and the same source-registered
            // Number template: `initial_value` is the editable input and `value` is
            // the data output. Preserve the literal's real JS kind.
            if ["tm_make_bool", "tm_make_number", "tm_make_string"].contains(node.type) {
                let fallback: Expr
                switch node.type {
                case "tm_make_bool": fallback = Expr("false")
                case "tm_make_string": fallback = Expr("\"\"")
                default: fallback = Expr("0")
                }
                return inputExpression(
                    into: node,
                    pinName: "initial_value",
                    context: context,
                    seen: &seen,
                    defaultValue: fallback
                )
            }

            if let hostProperty = Self.hostProperty(for: node.type) {
                return Expr("this.\(hostProperty)")
            }

            if node.type == "tm_make_audio_mix_group" {
                usesRealityKit = true
                let name = inputExpression(into: node, pinName: "name", context: context, seen: &seen)
                return Expr("new RealityKit.AudioMixGroup(\(name.code))")
            }
            if node.type == "tm_make_collision_group_number" {
                usesRealityKit = true
                let value = inputExpression(into: node, pinName: "value", context: context, seen: &seen)
                return Expr("new RealityKit.CollisionGroup(\(value.code))")
            }
            if node.type == "tm_make_collision_filter_number" {
                usesRealityKit = true
                let group = inputExpression(into: node, pinName: "group", context: context, seen: &seen)
                let mask = inputExpression(into: node, pinName: "mask", context: context, seen: &seen)
                return Expr(
                    "new RealityKit.CollisionFilter(new RealityKit.CollisionGroup(\(group.code)), new RealityKit.CollisionGroup(\(mask.code)))"
                )
            }
            if node.type == "tm_make_collision_filter" {
                usesRealityKit = true
                let group = inputExpression(into: node, pinName: "group", context: context, seen: &seen)
                let mask = inputExpression(into: node, pinName: "mask", context: context, seen: &seen)
                return Expr("new RealityKit.CollisionFilter(\(group.code), \(mask.code))")
            }
            if node.type == "tm_make_sphere_shape" {
                usesRealityKit = true
                let radius = inputExpression(
                    into: node, pinName: "radius", context: context, seen: &seen
                )
                return Expr("RealityKit.ShapeResource.generateSphere(\(radius.code))")
            }
            if node.type == "tm_make_capsule_shape" {
                usesRealityKit = true
                let height = inputExpression(
                    into: node, pinName: "height", context: context, seen: &seen
                )
                let radius = inputExpression(
                    into: node, pinName: "radius", context: context, seen: &seen
                )
                return Expr("RealityKit.ShapeResource.generateCapsule(\(height.code), \(radius.code))")
            }
            if node.type == "tm_make_box_shape" {
                usesRealityKit = true
                let extents = inputExpression(
                    into: node, pinName: "extents", context: context, seen: &seen
                )
                return Expr("RealityKit.ShapeResource.generateBox(\(extents.code))")
            }

            // The shipped generic Make emitter looks up the schema module/type,
            // requires that module, and returns `new Module.Type(inputs...)` in
            // connector order. These remaining fixed Make registrations use that
            // path; their exact connector order comes from the shipped node tests.
            if let constructor = Self.sourceMakeConstructor(for: node.type) {
                usesRealityKit = true
                let arguments = constructor.inputPins.map {
                    inputExpression(into: node, pinName: $0, context: context, seen: &seen).code
                }
                return Expr("new RealityKit.\(constructor.runtimeType)(\(arguments.joined(separator: ", ")))" )
            }

            // Generic enum Make family. The harvested emitter requires the schema
            // module and emits the selected case member, called with associated values
            // in descriptor order when that case carries a payload.
            if let schema = ScriptGraphValueSchema.enumMakeNodes[node.type],
               let selected = node.enumSelection.flatMap({ selection in
                   schema.cases.first { $0.name == selection.caseName }
               }) ?? schema.cases.first {
                requireSchemaModule(schema.module)
                let member = "\(schema.module).\(schema.typeName).\(selected.name)"
                guard !selected.associatedValues.isEmpty else { return Expr(member) }
                let arguments = selected.associatedValues.map {
                    inputExpression(
                        into: node, pinName: $0.name, context: context, seen: &seen
                    ).code
                }
                return Expr("\(member)(\(arguments.joined(separator: ", ")))")
            }

            // Generic enum Break family. Hopper shows one output property per
            // associated descriptor, whose expression is `source[index]`.
            if let schema = ScriptGraphValueSchema.enumBreakNodes[node.type],
               let selected = node.enumSelection.flatMap({ selection in
                   schema.cases.first { $0.name == selection.caseName }
               }) ?? schema.cases.first,
               let outputPin,
               let index = selected.associatedValues.firstIndex(where: {
                   TMHash.murmur64a($0.name) == outputPin
               }) {
                requireSchemaModule(schema.module)
                let source = inputExpression(
                    into: node, pinName: "source", context: context, seen: &seen
                )
                return Expr("(\(source.code))[\(index)]")
            }

            // Break (destructure) family. A break node has a single input `source` and one
            // output per property of the value type; reading an output emits a member access
            // on the source, `(<source>).<property>`. Component properties are scalars.
            if Self.breakOutputNames(for: node.type) != nil {
                // Inspectable-backed material breaks name their single serialized
                // dynamic input after the selected canonical type. Fixed-schema
                // breaks use the conventional `source` connector.
                let sourcePin = node.dynamicConnectorSettings?.inputs.first?.name ?? "source"
                let source = inputExpression(
                    into: node,
                    pinName: sourcePin,
                    context: context,
                    seen: &seen
                )
                let property = outputPin.flatMap { Self.breakPropertyName(forHash: $0) }
                    ?? outputPin.map { TMHash.hex($0) } ?? "value"
                return Expr("(\(source.code)).\(property)")
            }

            // Write family. Apple's generic emitter takes `source`, conditionally
            // assigns each connected writable schema property, and returns `source`.
            // Omitting an unwired property is important: assigning our normal scalar
            // fallback (`0`) would overwrite a field the graph did not author.
            if let schema = ScriptGraphValueSchema.writeNodes[node.type] {
                let source = inputExpression(into: node, pinName: "source", context: context, seen: &seen)
                let assignments = schema.properties.compactMap { property -> String? in
                    guard let value = optionalInputExpression(
                        into: node,
                        pinName: property.name,
                        context: context,
                        seen: &seen
                    ) else { return nil }
                    return "source.\(property.name) = \(value.code);"
                }
                return Expr(
                    "(() => { const source = \(source.code); \(assignments.joined(separator: " ")) return source; })()"
                )
            }

            // Multiply family (vector/quaternion/matrix * operand). All three emit the
            // SAME `Math3D.multiply(a, b)` call — the runtime's vector-math `multiply`
            // dispatches on the operand types. Operands are the two pins `a`/`b`; the
            // result is a vector/quaternion (so it propagates as a vector).
            if Self.isVectorMultiplyOp(node.type) {
                usesMath3D = true
                let a = inputExpression(into: node, pinName: "a", context: context, seen: &seen)
                let b = inputExpression(into: node, pinName: "b", context: context, seen: &seen)
                return Expr("Math3D.multiply(\(a.code), \(b.code))", isVector: true)
            }

            // Comparison nodes (scalar → bool). The library names the operands `a`/`b`
            // and the output `result`; we lower to the obvious infix comparison. Result
            // is a scalar (boolean).
            if let cmp = Self.comparisonOperator(for: node.type) {
                let a = inputExpression(into: node, pinName: "a", context: context, seen: &seen)
                let b = inputExpression(into: node, pinName: "b", context: context, seen: &seen)
                return Expr("(\(a.code) \(cmp) \(b.code))")
            }

            // Equality nodes (→ bool). The observed emission uses LOOSE equality
            // (`==`/`!=`), NOT strict (`===`/`!==`). Operands are `a`/`b`. Result scalar.
            // NOTE: for a `tm_string`-typed operand the observed form is the method call
            // `(a.equals(b) == true)`; since the graph carries no static operand type we
            // can resolve here, we emit the primitive loose form — the string-method
            // special-case is a follow-up once operand types are available.
            if let eq = Self.equalityOperator(for: node.type) {
                let a = inputExpression(into: node, pinName: "a", context: context, seen: &seen)
                let b = inputExpression(into: node, pinName: "b", context: context, seen: &seen)
                return Expr("(\(a.code) \(eq) \(b.code))")
            }

            // Logical NOT (→ bool). The observed emission negates by inequality to the
            // literal `true` — `(a != true)`, NOT `(!a)` — over the single operand `a`.
            if node.type == "tm_not" {
                let a = inputExpression(into: node, pinName: "a", context: context, seen: &seen)
                return Expr("(\(a.code) != true)")
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
                let operands = variadicOperands(of: node, context: context, seen: &seen).map(\.code)
                return Expr(operands.dropFirst().reduce(operands[0]) { "(\($0) \(bit) \($1))" })
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

            if node.type == "tm_make_look_at_rotation" {
                usesMath3D = true
                let at = inputExpression(into: node, pinName: "at", context: context, seen: &seen)
                let from = inputExpression(into: node, pinName: "from", context: context, seen: &seen)
                let upVector = inputExpression(
                    into: node,
                    pinName: "upVector",
                    context: context,
                    seen: &seen
                )
                return Expr(
                    "new Math3D.Quaternion(\(at.code), \(from.code), \(upVector.code))",
                    isVector: true
                )
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

            // Typed Array operators use graph-authored connector names from their
            // dynamic settings. Hopper confirms Count → `.length`, Get → `array[index]`,
            // and Set's data output → the alias declared by its contextual action.
            if let arrayExpr = emitArrayExpression(node, context: context, seen: &seen) {
                return arrayExpr
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
            if node.type == "tm_make_vector4_with_vector3" {
                usesMath3D = true
                let xyz = inputExpression(
                    into: node,
                    pinName: "xyz",
                    context: context,
                    seen: &seen,
                    defaultValue: Expr("new Math3D.Vector3(0, 0, 0)", isVector: true)
                )
                let w = inputExpression(into: node, pinName: "w", context: context, seen: &seen)
                return Expr(
                    "(() => { const xyz = \(xyz.code); return new Math3D.Vector4(xyz.x, xyz.y, xyz.z, \(w.code)); })()",
                    isVector: true
                )
            }

            if node.type == "tm_make_color" {
                usesFoundation = true
                let red = inputExpression(into: node, pinName: "red", context: context, seen: &seen)
                let green = inputExpression(into: node, pinName: "green", context: context, seen: &seen)
                let blue = inputExpression(into: node, pinName: "blue", context: context, seen: &seen)
                let alpha = inputExpression(into: node, pinName: "alpha", context: context, seen: &seen)
                return Expr(
                    "new Foundation.Color(\(red.code), \(green.code), \(blue.code), \(alpha.code))"
                )
            }

            if node.type == "tm_cgcolor_to_color" {
                usesFoundation = true
                let source = inputExpression(into: node, pinName: "source", context: context, seen: &seen)
                return Expr("new Foundation.Color(\(source.code))")
            }

            if node.type == "tm_color_to_cgcolor" {
                let source = inputExpression(into: node, pinName: "source", context: context, seen: &seen)
                return Expr("\(source.code).cgColor")
            }

            if node.type == "tm_make_cgsize" {
                usesCoreGraphics = true
                let width = inputExpression(into: node, pinName: "width", context: context, seen: &seen)
                let height = inputExpression(into: node, pinName: "height", context: context, seen: &seen)
                return Expr("new CoreGraphics.CGSize(\(width.code), \(height.code))")
            }

            if node.type == "tm_make_cgcolor" {
                usesCoreGraphics = true
                let red = inputExpression(into: node, pinName: "red", context: context, seen: &seen)
                let green = inputExpression(into: node, pinName: "green", context: context, seen: &seen)
                let blue = inputExpression(into: node, pinName: "blue", context: context, seen: &seen)
                let alpha = inputExpression(into: node, pinName: "alpha", context: context, seen: &seen)
                return Expr(
                    "new CoreGraphics.CGColor(\(red.code), \(green.code), \(blue.code), \(alpha.code))"
                )
            }

            if node.type == "tm_make_edge_insets" {
                usesFoundation = true
                let top = inputExpression(into: node, pinName: "top", context: context, seen: &seen)
                let left = inputExpression(into: node, pinName: "left", context: context, seen: &seen)
                let bottom = inputExpression(into: node, pinName: "bottom", context: context, seen: &seen)
                let right = inputExpression(into: node, pinName: "right", context: context, seen: &seen)
                return Expr(
                    "new Foundation.EdgeInsets(\(top.code), \(left.code), \(bottom.code), \(right.code))"
                )
            }

            if ["tm_make_matrix2x2", "tm_make_matrix3x3", "tm_make_matrix4x4"].contains(node.type) {
                usesMath3D = true
                let dimension = Int(node.type.dropFirst("tm_make_matrix".count).prefix(1)) ?? 2
                let columns = (0..<dimension).map { column in
                    inputExpression(
                        into: node,
                        pinName: "col\(column)",
                        context: context,
                        seen: &seen
                    ).code
                }
                return Expr(
                    "new Math3D.Matrix\(dimension)x\(dimension)(\(columns.joined(separator: ", ")))",
                    isVector: true
                )
            }

            // Vector-math ops emitted as `Math3D.<fn>(args)` (the observed emission for
            // these node types). `dot`/`length` return a scalar; `cross`/`normal`/`reflect`
            // return a vector. `length`/`normal` are single-operand (`a`); the rest take
            // `a`/`b`. (`tm_math_normal` is the NORMALIZE node — its function is `normal`.)
            if let vectorOp = Self.vectorMathOp(for: node.type) {
                usesMath3D = true
                let a = inputExpression(into: node, pinName: "a", context: context, seen: &seen)
                if vectorOp.unary {
                    return Expr("Math3D.\(vectorOp.function)(\(a.code))", isVector: vectorOp.resultIsVector)
                }
                let b = inputExpression(into: node, pinName: "b", context: context, seen: &seen)
                return Expr("Math3D.\(vectorOp.function)(\(a.code), \(b.code))", isVector: vectorOp.resultIsVector)
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
                if node.type == "tm_get_remote_variable_node" {
                    return Expr("undefined /* unsupported: tm_get_remote_variable_node (remote-variable identity unresolved) */")
                }
                if let name = node.variableName {
                    let slot = CanonicalScriptGraphCompiler.variableSlot(for: name)
                    return Expr("(this.\(slot) ?? 0)")
                }
                return Expr("undefined /* tm_get_variable_node name unresolved */")
            }

            if node.type.hasPrefix("tm_variable_"), let name = node.variableName {
                let slot = CanonicalScriptGraphCompiler.variableSlot(for: name)
                return Expr("(this.\(slot) ?? 0)")
            }

            // Unknown / unmapped node → a safe fallback, never fabricated behavior.
            return Expr("0 /* unsupported: \(node.type) */")
        }

        mutating func requireSchemaModule(_ module: String) {
            switch module {
            case "RealityKit": usesRealityKit = true
            case "Math3D": usesMath3D = true
            case "Foundation": usesFoundation = true
            case "CoreGraphics": usesCoreGraphics = true
            default: break
            }
        }

        /// Lowers a binary math node from its already-evaluated operands. The result type
        /// is VECTOR iff either operand is a vector (else scalar). For an `add` over
        /// vectors we emit the publicly-documented `Math3D.add(a, b)` (JS `+` is not vector
        /// addition); subtract/multiply stay as the same bare JS operators for scalar and
        /// vector operands. Scalar ops are unchanged.
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
            if let kind = Self.eventKind(for: node.type), case .custom = kind,
               let connector = node.dynamicConnectorSettings?.outputs.first(where: {
                   TMHash.murmur64a($0.name) == pin
               }) {
                return Expr("event.eventData[\(Self.renderJSString(connector.name))]")
            }
            // Resolve the output pin hash back to a readable gesture-output name.
            let name = Self.gestureOutputName(forHash: pin) ?? TMHash.hex(pin)
            let isVector = Self.vectorGestureOutputNames.contains(name)
            switch context {
            case .gesture, .event:
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
                // No wire feeding the pin: a bound literal (a graph `data` constant —
                // number / bool / string) supplies it, else the safe `0`.
                if let value = graph.literal(node: node.id, pin: pin) {
                    return Expr(Self.renderValue(value))
                }
                if let defaultValue { return defaultValue }
                return Expr("0 /* \(pinName) unwired */")
            }
            return emitExpression(from: wire, context: context, seen: &seen)
        }

        /// Resolves a property-style optional input, returning `nil` when the pin is
        /// genuinely absent rather than manufacturing the scalar fallback used by
        /// arithmetic nodes.
        mutating func optionalInputExpression(
            into node: RCP3ScriptGraph.Node,
            pinName: String,
            context: ExprContext,
            seen: inout Set<String>
        ) -> Expr? {
            let pin = TMHash.murmur64a(pinName)
            if let wire = dataWire(into: node.id, pin: pin) {
                return emitExpression(from: wire, context: context, seen: &seen)
            }
            return graph.literal(node: node.id, pin: pin).map { Expr(Self.renderValue($0)) }
        }

        /// Renders a scalar literal as a clean JS number (integers without a
        /// trailing `.0`).
        static func renderScalar(_ value: Double) -> String {
            if value == value.rounded() && abs(value) < 1e15 {
                return String(Int(value))
            }
            return String(value)
        }

        /// Renders a pin literal value as a JS expression: a number, a `true`/`false`
        /// boolean, or a quoted/escaped string. (Variable refs are emitted elsewhere.)
        static func renderValue(_ value: TMGraphValue) -> String {
            switch value {
            case let .number(number): return renderScalar(number)
            case let .bool(flag): return flag ? "true" : "false"
            case let .string(text): return renderJSString(text)
            case .variableRef: return "undefined"
            }
        }

        /// A JS double-quoted string literal with the essential escapes.
        static func renderJSString(_ text: String) -> String {
            var out = "\""
            for character in text {
                switch character {
                case "\\": out += "\\\\"
                case "\"": out += "\\\""
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default: out.append(character)
                }
            }
            out += "\""
            return out
        }

        // MARK: Static maps

        /// Exact primitive-name switch recovered from
        /// `primitiveTypeName(for:)` in `registerEntityParameterNodes`.
        static func entityParameterPrimitiveName(for node: RCP3ScriptGraph.Node) -> String? {
            guard let hash = node.entityParameterSettings?.typeHash else { return nil }
            switch hash {
            case TMHash.murmur64a("tm_bool"): return "bool"
            case TMHash.murmur64a("tm_int32_t"): return "int"
            case TMHash.murmur64a("tm_string"): return "string"
            case TMHash.murmur64a("tm_double"): return "double"
            case TMHash.murmur64a("tm_float"): return "float"
            default: return nil
            }
        }

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

        static func hostProperty(for type: String) -> String? {
            switch type {
            case "tm_in_editor": return "inEditor"
            case "tm_host_is_macos": return "isMacOS"
            case "tm_host_is_visionos": return "isVisionOS"
            case "tm_host_is_ios": return "isIOS"
            case "tm_host_is_tvos": return "isTVOS"
            case "tm_host_is_simulator": return "isSimulator"
            case "tm_host_time": return "hostTime"
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

        /// Equality nodes → the infix JS LOOSE-equality operator (→ boolean). The
        /// observed emission is loose `==`/`!=`, not strict `===`/`!==`. `nil` otherwise.
        static func equalityOperator(for type: String) -> String? {
            switch type {
            case "tm_equals": return "=="
            case "tm_not_equals": return "!="
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

        static let transformPropertyMutations: [ScriptGraphComponentRuntimeCapabilities.PropertyMutation] = {
            guard let capability = ScriptGraphComponentRuntimeCapabilities.capability(
                forTypeHash: TMHash.murmur64a("Transform")
            ), case let .entityProperties(properties) = capability.strategy else { return [] }
            return properties
        }()

        /// The operand expressions of a variadic logic node (`tm_and` / `tm_or`). The
        /// library seeds the `a`/`b` pins; on disk a node may carry more (`c`, `d`, …).
        /// We always emit `a`/`b`, then fold any further single-letter operand pin that
        /// actually carries a wire or a baked scalar literal, in alphabetical order.
        mutating func logicOperands(
            of node: RCP3ScriptGraph.Node,
            context: ExprContext,
            seen: inout Set<String>
        ) -> [String] {
            variadicOperands(of: node, context: context, seen: &seen).map(\.code)
        }

        /// The operand expressions of a variadic arithmetic or bitwise node. Most math
        /// nodes use `a`/`b` plus optional `c`, `d`, ... pins; `pow` is the exception and
        /// names its second input `exponent`.
        mutating func mathOperands(
            of node: RCP3ScriptGraph.Node,
            context: ExprContext,
            seen: inout Set<String>
        ) -> [Expr] {
            if node.type == "tm_math_pow" {
                return [
                    inputExpression(into: node, pinName: "a", context: context, seen: &seen),
                    inputExpression(into: node, pinName: "exponent", context: context, seen: &seen),
                ]
            }
            return variadicOperands(of: node, context: context, seen: &seen)
        }

        mutating func variadicOperands(
            of node: RCP3ScriptGraph.Node,
            context: ExprContext,
            seen: inout Set<String>
        ) -> [Expr] {
            var operands: [Expr] = [
                inputExpression(into: node, pinName: "a", context: context, seen: &seen),
                inputExpression(into: node, pinName: "b", context: context, seen: &seen),
            ]
            for letter in "cdefghijklmnopqrstuvwxyz" {
                let name = String(letter)
                let pin = TMHash.murmur64a(name)
                let hasWire = dataWire(into: node.id, pin: pin) != nil
                let hasLiteral = graph.literal(node: node.id, pin: pin) != nil
                guard hasWire || hasLiteral else { continue }
                operands.append(inputExpression(into: node, pinName: name, context: context, seen: &seen))
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
            case "tm_to_string":
                guard let input = node.dynamicConnectorSettings?.inputs.first?.name else {
                    return Expr("\"\" /* typed input missing */")
                }
                // Apple's AST is a template literal around connector 0. `String(...)`
                // is the equivalent expression without having to escape nested JS code.
                return Expr("String(\(arg(input)))")
            case "tm_string_merge":
                let values = node.dynamicConnectorSettings?.inputs.map { arg($0.name) } ?? []
                guard values.count >= 2 else {
                    return Expr("\"\" /* string merge requires two values */")
                }
                // The source emitter flattens when any value connector is an Array;
                // unconditional `flat()` has the same scalar/array result in plain JS.
                return Expr("[\(values.joined(separator: ", "))].flat().join(\(arg("separator")))")
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

        mutating func emitArrayExpression(
            _ node: RCP3ScriptGraph.Node,
            context: ExprContext,
            seen: inout Set<String>
        ) -> Expr? {
            guard node.type.hasPrefix("tm_array_") else { return nil }
            func arg(_ pinName: String) -> String {
                inputExpression(into: node, pinName: pinName, context: context, seen: &seen).code
            }
            switch node.type {
            case "tm_array_create":
                let elements = node.dynamicConnectorSettings?.inputs.map { arg($0.name) } ?? []
                return Expr("[\(elements.joined(separator: ", "))]")
            case "tm_array_count":
                guard let array = node.dynamicConnectorSettings?.inputs.first?.name else {
                    return Expr("0 /* typed array connector missing */")
                }
                return Expr("(\(arg(array))).length")
            case "tm_array_get":
                guard let array = node.dynamicConnectorSettings?.inputs.first?.name else {
                    return Expr("undefined /* typed array connector missing */")
                }
                return Expr("(\(arg(array)))[\(arg("index"))]")
            case "tm_array_set", "tm_array_add", "tm_array_remove":
                return Expr(Self.arrayMutationOutputName(for: node))
            default:
                return nil
            }
        }

        static func arraySetOutputName(for node: RCP3ScriptGraph.Node) -> String {
            arrayMutationOutputName(for: node)
        }

        static func arrayMutationOutputName(for node: RCP3ScriptGraph.Node) -> String {
            "__d3_\(sanitize(node.type))_\(sanitize(node.id))"
        }

        static func arrayForEachIndexName(for node: RCP3ScriptGraph.Node) -> String {
            "__d3_array_index_\(sanitize(node.id))"
        }

        static func arrayFindIndexName(for node: RCP3ScriptGraph.Node) -> String {
            "__d3_array_find_index_\(sanitize(node.id))"
        }

        static func arrayFindElementName(for node: RCP3ScriptGraph.Node) -> String {
            "__d3_array_find_element_\(sanitize(node.id))"
        }

        static func entityMoveControllerName(for node: RCP3ScriptGraph.Node) -> String {
            "__d3_move_controller_\(sanitize(node.id))"
        }

        static func sceneCastHitName(for node: RCP3ScriptGraph.Node) -> String {
            "__d3_cast_hit_\(sanitize(node.id))"
        }

        static func animationControllerName(for node: RCP3ScriptGraph.Node) -> String {
            "__d3_animation_controller_\(sanitize(node.id))"
        }

        static func namedAudioControllerName(for node: RCP3ScriptGraph.Node) -> String {
            "__d3_named_audio_controller_\(sanitize(node.id))"
        }

        static func modifiedMaterialName(for node: RCP3ScriptGraph.Node) -> String {
            "__d3_modified_material_\(sanitize(node.id))"
        }

        static func spawnedEntityName(for node: RCP3ScriptGraph.Node) -> String {
            "__d3_spawned_entity_\(sanitize(node.id))"
        }

        static func clonedEntityName(for node: RCP3ScriptGraph.Node) -> String {
            "__d3_cloned_entity_\(sanitize(node.id))"
        }

        static let moveCharacterOutputPins = [
            "hitEntity", "hitPosition", "hitNormal", "moveDirection", "moveDistance",
        ]

        static func moveCharacterOutputName(
            for node: RCP3ScriptGraph.Node,
            pin: String
        ) -> String {
            "__d3_move_character_\(sanitize(node.id))_\(pin)"
        }

        /// A vector-math op that lowers to a `Math3D.<function>(args)` call: the JS
        /// function name, whether it is single-operand, and whether the result is a
        /// vector (vs a scalar).
        struct VectorMathOp {
            var function: String
            var unary: Bool
            var resultIsVector: Bool
        }

        /// The `Math3D` vector-math op for a node type, or `nil` if it is not one.
        /// `dot`/`length` yield a scalar; `cross`/`normal`/`reflect` yield a vector.
        /// `length`/`normal` take a single operand; `dot`/`cross`/`reflect` take two.
        static func vectorMathOp(for type: String) -> VectorMathOp? {
            switch type {
            case "tm_math_dot":     return VectorMathOp(function: "dot", unary: false, resultIsVector: false)
            case "tm_math_cross":   return VectorMathOp(function: "cross", unary: false, resultIsVector: true)
            case "tm_math_reflect": return VectorMathOp(function: "reflect", unary: false, resultIsVector: true)
            case "tm_math_length":  return VectorMathOp(function: "length", unary: true, resultIsVector: false)
            case "tm_math_normal":  return VectorMathOp(function: "normal", unary: true, resultIsVector: true)
            default:                return nil
            }
        }

        /// An interpolation op that lowers to `Math3D.<function>(a, b, factor)`. The
        /// factor pin is `t` for lerp/slerp and `x` for smoothstep.
        struct InterpolationOp {
            var function: String
            var factorPin: String
        }

        struct SourceMakeConstructor {
            var runtimeType: String
            var inputPins: [String]
        }

        static func sourceMakeConstructor(for type: String) -> SourceMakeConstructor? {
            switch type {
            case "tm_make_material_parameter_types_texture_coordinate_transform":
                return SourceMakeConstructor(
                    runtimeType: "MaterialParameterTypes.TextureCoordinateTransform",
                    inputPins: ["offset", "scale", "rotation"]
                )
            case "tm_make_physically_based_material_anisotropy_angle":
                return SourceMakeConstructor(
                    runtimeType: "PhysicallyBasedMaterial.AnisotropyAngle",
                    inputPins: ["angle"]
                )
            case "tm_make_physically_based_material_anisotropy_level":
                return SourceMakeConstructor(
                    runtimeType: "PhysicallyBasedMaterial.AnisotropyLevel",
                    inputPins: ["level"]
                )
            case "tm_make_physically_based_material_base_color":
                return SourceMakeConstructor(
                    runtimeType: "PhysicallyBasedMaterial.BaseColor",
                    inputPins: ["red", "green", "blue", "alpha"]
                )
            case "tm_make_physically_based_material_clearcoat":
                return SourceMakeConstructor(
                    runtimeType: "PhysicallyBasedMaterial.Clearcoat",
                    inputPins: ["clearcoat"]
                )
            case "tm_make_physically_based_material_clearcoat_roughness":
                return SourceMakeConstructor(
                    runtimeType: "PhysicallyBasedMaterial.ClearcoatRoughness",
                    inputPins: ["roughness"]
                )
            case "tm_make_physically_based_material_emissive_color":
                return SourceMakeConstructor(
                    runtimeType: "PhysicallyBasedMaterial.EmissiveColor",
                    inputPins: ["red", "green", "blue", "alpha"]
                )
            case "tm_make_physically_based_material_metallic":
                return SourceMakeConstructor(
                    runtimeType: "PhysicallyBasedMaterial.Metallic",
                    inputPins: ["metallic"]
                )
            case "tm_make_physically_based_material_roughness":
                return SourceMakeConstructor(
                    runtimeType: "PhysicallyBasedMaterial.Roughness",
                    inputPins: ["roughness"]
                )
            case "tm_make_physically_based_material_sheen_color":
                return SourceMakeConstructor(
                    runtimeType: "PhysicallyBasedMaterial.SheenColor",
                    inputPins: ["red", "green", "blue", "alpha"]
                )
            case "tm_make_physics_mass_properties":
                return SourceMakeConstructor(
                    runtimeType: "PhysicsMassProperties",
                    inputPins: ["mass", "inertia", "position", "orientation"]
                )
            case "tm_make_physics_material_resource":
                return SourceMakeConstructor(
                    runtimeType: "PhysicsMaterialResource",
                    inputPins: ["staticFriction", "dynamicFriction", "restitution"]
                )
            default:
                return nil
            }
        }

        /// The `Math3D` interpolation op for a node type, or `nil` if it is not one.
        static func interpolationOp(for type: String) -> InterpolationOp? {
            switch type {
            case "tm_math_lerp":       return InterpolationOp(function: "lerp", factorPin: "t")
            case "tm_math_slerp":      return InterpolationOp(function: "slerp", factorPin: "t")
            case "tm_math_smoothstep": return InterpolationOp(function: "smoothstep", factorPin: "x")
            default:                   return nil
            }
        }

        /// The Break (destructure) node types we lower, mapped to their value type's
        /// property (= output pin) names. A break node reads its single `source` input and
        /// exposes one output per property; the emission is `(<source>).<property>`. Only
        /// the value types whose schema properties are the canonical component names (and
        /// match the corresponding Make constructor inputs) are listed — quaternion, matrix,
        /// entity, and the component/material breaks are deferred until their exact property
        /// names are confirmed.
        static func breakOutputNames(for type: String) -> [String]? {
            if let schema = ScriptGraphValueSchema.breakNodes[type] {
                return schema.properties.map(\.name)
            }
            switch type {
            case "tm_break_material":
                return physicallyBasedMaterialBreakProperties
            case "tm_break_physically_based_material_types":
                return ["scale"]
            case "tm_break_vector2": return ["x", "y"]
            case "tm_break_vector3": return ["x", "y", "z"]
            case "tm_break_vector4": return ["x", "y", "z", "w"]
            case "tm_break_cgpoint": return ["x", "y"]
            case "tm_break_cgsize":  return ["width", "height"]
            case "tm_break_color", "tm_break_cgcolor": return ["red", "green", "blue", "alpha"]
            default: return nil
            }
        }

        /// Reverse map from an output-pin hash to a break property name, for the union of
        /// all `breakOutputNames`.
        static func breakPropertyName(forHash hash: UInt64) -> String? {
            breakPropertyNamesByHash[hash]
        }

        static let breakPropertyNamesByHash: [UInt64: String] = {
            let schemaNames = ScriptGraphValueSchema.breakNodes.values
                .flatMap { $0.properties.map(\.name) }
            let names = schemaNames + physicallyBasedMaterialBreakProperties
                + ["scale", "x", "y", "z", "w", "width", "height", "red", "green", "blue", "alpha"]
            var map: [UInt64: String] = [:]
            for name in names { map[TMHash.murmur64a(name)] = name }
            return map
        }()

        static let physicallyBasedMaterialBreakProperties = [
            "anisotropyAngle", "anisotropyLevel", "baseColor", "blending", "clearcoat",
            "clearcoatRoughness", "emissiveColor", "emissiveIntensity", "faceCulling",
            "metallic", "readsDepth", "roughness", "secondaryTextureCoordinateTransform",
            "sheen", "textureCoordinateTransform", "triangleFillMode", "writesDepth",
        ]

        /// The multiply family (`multiply_by_scalar`/`_by_quaternion`/`_by_matrix`), all
        /// of which lower to `Math3D.multiply(a, b)`.
        static func isVectorMultiplyOp(_ type: String) -> Bool {
            switch type {
            case "tm_math_multiply_by_scalar",
                 "tm_math_multiply_by_quaternion",
                 "tm_math_multiply_by_matrix":
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
            "otherEntity", "position", "impulse", "impulseDirection",
            "penetrationDistance", "contacts", "simulationRootEntity",
            "playbackController",
            "scale", "orientation", "matrix",
        ]

        /// Gesture output pins whose value is a `Math3D.Vector3` (a 2D/3D point or
        /// translation). These feed vector math, so a downstream `tm_math_add` must lower
        /// to `Math3D.add` rather than the scalar `+`. (`deltaTime`/`didEnd`/`entity`/
        /// `scene` are NOT vectors.)
        static let vectorGestureOutputNames: Set<String> = [
            "location", "startLocation", "translation",
            "sceneLocation", "sceneStartLocation", "sceneTranslation",
            "position", "impulseDirection",
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
