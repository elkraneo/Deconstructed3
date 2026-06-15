import Testing
import Foundation
import TMFormat
import RCP3Document
import RCP3Runtime

/// The canonical compiler emits the **public RealityKit Script Graph runtime**
/// surface (the `ScriptingComponent(source:)` form), distinct from the in-house
/// preview dialect of `ScriptGraphCompiler`.
///
/// These exercise the generalized data-flow traversal: event roots → handlers,
/// action nodes → statements, and the recursive data-input → expression evaluator
/// (constants, math, vector constructors, undocumented-op + unknown-node fallbacks).
@Suite struct CanonicalScriptGraphCompilerTests {
    /// The canonical gesture→set-translation graph (drag exec→set, drag data→
    /// set.`translation`), built in-memory — the `Random` capture's shape.
    static func dragToSetTranslationGraph() -> RCP3ScriptGraph {
        let drag = RCP3ScriptGraph.Node(id: "n1", type: "tm_gesture_event_drag")
        let set = RCP3ScriptGraph.Node(id: "n2", type: "tm_set_component", label: "Set Transform")
        let exec = RCP3ScriptGraph.Wire(id: "c1", from: "n1", to: "n2")
        let data = RCP3ScriptGraph.Wire(
            id: "c2",
            from: "n1",
            to: "n2",
            fromPin: 0x4f980d170a59f903,
            toPin: TMHash.murmur64a("translation")
        )
        return RCP3ScriptGraph(nodes: [drag, set], wires: [exec, data], data: [])
    }

    @Test func compilesDragToCanonicalDidAddHandler() {
        let js = CanonicalScriptGraphCompiler().compile(Self.dragToSetTranslationGraph())

        // Built-in modules must be require()'d before use, else the runtime throws
        // "Can't find variable: RealityKit".
        #expect(js.contains("const RealityKit = require(\"RealityKit\")"))
        #expect(js.contains("const Math3D = require(\"Math3D\")"))
        // The public-package surface: lifecycle assigned on `this`, gesture against
        // RealityKit.DragGestureEvent.name, entity.position moved via Math3D.
        #expect(js.contains("this.didAdd = function()"))
        #expect(js.contains("this.entity.on(RealityKit.DragGestureEvent.name"))
        #expect(js.contains("Math3D.add(dragStart, event.sceneTranslation)"))
        #expect(js.contains("event.entity.position"))
        // And it does NOT fall back to our in-house preview dialect.
        #expect(!js.contains("entity.transform.translation"))
        #expect(!js.contains("e.delta"))
        #expect(!js.contains("unsupported node"))
    }

    @Test func unrecognizedNodeEmitsHonestNoOp() {
        let mystery = RCP3ScriptGraph.Node(id: "x1", type: "tm_some_future_node")
        let graph = RCP3ScriptGraph(nodes: [mystery], wires: [], data: [])

        let js = CanonicalScriptGraphCompiler().compile(graph)

        #expect(js.contains("// unsupported node: tm_some_future_node"))
        #expect(!js.contains("this.didAdd"))
    }

    @Test func dragEventAlwaysEmitsItsGestureHandler() {
        // A drag node exec→set with NO translation data wire is still a gesture EVENT
        // root, so the generalized compiler emits its `didAdd` drag subscription (the
        // input-target + collision setup is part of the public gesture contract). The
        // set node with no transform input becomes an honest no-op inside the body —
        // not the disappearance of the whole handler.
        let drag = RCP3ScriptGraph.Node(id: "n1", type: "tm_gesture_event_drag")
        let set = RCP3ScriptGraph.Node(id: "n2", type: "tm_set_component")
        let exec = RCP3ScriptGraph.Wire(id: "c1", from: "n1", to: "n2")
        let graph = RCP3ScriptGraph(nodes: [drag, set], wires: [exec], data: [])

        let js = CanonicalScriptGraphCompiler().compile(graph)

        #expect(js.contains("this.didAdd = function()"))
        #expect(js.contains("this.entity.on(RealityKit.DragGestureEvent.name"))
        // No transform was wired, so the body honestly reports it rather than inventing
        // a move.
        #expect(js.contains("no transform input wired"))
        #expect(!js.contains("entity.transform.translation"))
    }

    @Test func constantFeedingSetTranslationCompilesToMathConstant() {
        // On Update → Set Transform.translation = π (a constant node feeding the pin).
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component", label: "Set Transform")
        let pi = RCP3ScriptGraph.Node(id: "p", type: "tm_constant_pi")
        let exec = RCP3ScriptGraph.Wire(id: "e1", from: "u", to: "s")
        let dataWire = RCP3ScriptGraph.Wire(
            id: "d1", from: "p", to: "s",
            fromPin: TMHash.murmur64a("PI"),
            toPin: TMHash.murmur64a("translation")
        )
        let graph = RCP3ScriptGraph(nodes: [update, set, pi], wires: [exec, dataWire], data: [])

        let js = CanonicalScriptGraphCompiler().compile(graph)

        // The event root becomes a `this.update(deltaTime)` hook.
        #expect(js.contains("this.update = function(deltaTime)"))
        // The constant resolves to the plain-JS Math constant, written to `.position`.
        #expect(js.contains("this.entity.position = Math.PI;"))
        // Math constants are plain JS — no Math3D require needed for this graph.
        #expect(!js.contains("const Math3D = require"))
        #expect(!js.contains("unsupported"))
    }

    @Test func mathAddOfTwoConstantsCompilesToInfixExpression() {
        // On Added → Set Transform.translation = (π + e), where the add node's two
        // inputs are themselves constant nodes — exercising the recursive evaluator.
        let added = RCP3ScriptGraph.Node(id: "a", type: "tm_did_add")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component")
        let mathAdd = RCP3ScriptGraph.Node(id: "m", type: "tm_math_add")
        let pi = RCP3ScriptGraph.Node(id: "p", type: "tm_constant_pi")
        let e = RCP3ScriptGraph.Node(id: "e", type: "tm_constant_e")
        let exec = RCP3ScriptGraph.Wire(id: "e1", from: "a", to: "s")
        let wPi = RCP3ScriptGraph.Wire(
            id: "w1", from: "p", to: "m",
            fromPin: TMHash.murmur64a("PI"), toPin: TMHash.murmur64a("a")
        )
        let wE = RCP3ScriptGraph.Wire(
            id: "w2", from: "e", to: "m",
            fromPin: TMHash.murmur64a("E"), toPin: TMHash.murmur64a("b")
        )
        let wOut = RCP3ScriptGraph.Wire(
            id: "w3", from: "m", to: "s",
            fromPin: TMHash.murmur64a("result"), toPin: TMHash.murmur64a("translation")
        )
        let graph = RCP3ScriptGraph(
            nodes: [added, set, mathAdd, pi, e],
            wires: [exec, wPi, wE, wOut], data: []
        )

        let js = CanonicalScriptGraphCompiler().compile(graph)

        // The lifecycle root becomes a `this.didAdd` hook.
        #expect(js.contains("this.didAdd = function()"))
        // The add node recursively resolves both constant inputs into a plain-JS infix
        // expression assigned to the transform.
        #expect(js.contains("this.entity.position = (Math.PI + Math.E);"))
        #expect(!js.contains("unsupported"))
    }

    @Test func unaryMathAndVectorConstructorCompile() {
        // On Update → Set.translation = Vector3(sin(π), 0, 0): unary Math.* feeding a
        // Math3D.Vector3 constructor (the one publicly-documented Math3D constructor).
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component")
        let vec = RCP3ScriptGraph.Node(id: "v", type: "tm_make_vector3")
        let sin = RCP3ScriptGraph.Node(id: "n", type: "tm_math_sin")
        let pi = RCP3ScriptGraph.Node(id: "p", type: "tm_constant_pi")
        let exec = RCP3ScriptGraph.Wire(id: "e1", from: "u", to: "s")
        let wSin = RCP3ScriptGraph.Wire(
            id: "w0", from: "p", to: "n",
            fromPin: TMHash.murmur64a("PI"), toPin: TMHash.murmur64a("a")
        )
        let wX = RCP3ScriptGraph.Wire(
            id: "w1", from: "n", to: "v",
            fromPin: TMHash.murmur64a("result"), toPin: TMHash.murmur64a("x")
        )
        let wOut = RCP3ScriptGraph.Wire(
            id: "w3", from: "v", to: "s",
            fromPin: TMHash.murmur64a("vec3"), toPin: TMHash.murmur64a("translation")
        )
        let graph = RCP3ScriptGraph(
            nodes: [update, set, vec, sin, pi],
            wires: [exec, wSin, wX, wOut], data: []
        )

        let js = CanonicalScriptGraphCompiler().compile(graph)

        // Vector constructor uses the publicly-documented Math3D constructor, so the
        // header must bind Math3D.
        #expect(js.contains("const Math3D = require(\"Math3D\")"))
        // sin(π) is plain JS; the unwired y/z fall back to 0.
        #expect(js.contains("new Math3D.Vector3(Math.sin(Math.PI), 0"))
        #expect(js.contains("this.entity.position = new Math3D.Vector3("))
        #expect(!js.contains("unsupported"))
    }

    @Test func unknownDataNodeFallsBackWithoutCrashing() {
        // An unknown node feeding the transform pin must NOT fabricate behavior: it
        // emits a safe fallback expression with an inline `unsupported:` note, and the
        // compiler does not crash.
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component")
        let mystery = RCP3ScriptGraph.Node(id: "x", type: "tm_future_widget")
        let exec = RCP3ScriptGraph.Wire(id: "e1", from: "u", to: "s")
        let wOut = RCP3ScriptGraph.Wire(
            id: "w3", from: "x", to: "s",
            fromPin: TMHash.murmur64a("out"), toPin: TMHash.murmur64a("translation")
        )
        let graph = RCP3ScriptGraph(nodes: [update, set, mystery], wires: [exec, wOut], data: [])

        let js = CanonicalScriptGraphCompiler().compile(graph)

        #expect(js.contains("this.update = function(deltaTime)"))
        #expect(js.contains("/* unsupported: tm_future_widget */"))
        // A safe fallback value (0), wrapped by the assignment — no fabricated call.
        #expect(js.contains("this.entity.position = 0"))
    }

    @Test func undocumentedVectorOpStaysCleanRoom() {
        // A dot-product node has no PUBLICLY-documented Math3D name, so the compiler must
        // NOT emit `Math3D.dot(...)` — it emits a plain-JS fallback with an honest note.
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component")
        let dot = RCP3ScriptGraph.Node(id: "d", type: "tm_math_dot")
        let exec = RCP3ScriptGraph.Wire(id: "e1", from: "u", to: "s")
        let wOut = RCP3ScriptGraph.Wire(
            id: "w3", from: "d", to: "s",
            fromPin: TMHash.murmur64a("result"), toPin: TMHash.murmur64a("translation")
        )
        let graph = RCP3ScriptGraph(nodes: [update, set, dot], wires: [exec, wOut], data: [])

        let js = CanonicalScriptGraphCompiler().compile(graph)

        #expect(js.contains("/* unsupported: tm_math_dot (Math3D op name not public) */"))
        #expect(!js.contains("Math3D.dot"))
    }
}
