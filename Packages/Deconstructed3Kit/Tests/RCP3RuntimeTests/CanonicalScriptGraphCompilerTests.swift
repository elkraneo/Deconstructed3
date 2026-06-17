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
        // expression assigned to the transform. Two SCALAR constants → the `+` operator
        // is CORRECT and must NOT change to Math3D.add (the regression guard that scalar
        // add was untouched by the vector-typing fix).
        #expect(js.contains("this.entity.position = (Math.PI + Math.E);"))
        #expect(!js.contains("Math3D.add"))
        #expect(!js.contains("unsupported"))
    }

    @Test func mathAddOfTwoVectorsCompilesToMath3DAdd() {
        // On Added → Set Transform.translation = (v1 + v2), where both inputs to the add
        // are `tm_make_vector3` constructors. JS `+` is NOT vector addition (it coerces to
        // a string / NaN, so the entity never moves), so the add must lower to the
        // PUBLICLY-documented `Math3D.add(a, b)` — the type inference's whole point.
        let added = RCP3ScriptGraph.Node(id: "a", type: "tm_did_add")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component")
        let mathAdd = RCP3ScriptGraph.Node(id: "m", type: "tm_math_add")
        let v1 = RCP3ScriptGraph.Node(id: "v1", type: "tm_make_vector3")
        let v2 = RCP3ScriptGraph.Node(id: "v2", type: "tm_make_vector3")
        let exec = RCP3ScriptGraph.Wire(id: "e1", from: "a", to: "s")
        let wV1 = RCP3ScriptGraph.Wire(
            id: "w1", from: "v1", to: "m",
            fromPin: TMHash.murmur64a("vec3"), toPin: TMHash.murmur64a("a")
        )
        let wV2 = RCP3ScriptGraph.Wire(
            id: "w2", from: "v2", to: "m",
            fromPin: TMHash.murmur64a("vec3"), toPin: TMHash.murmur64a("b")
        )
        let wOut = RCP3ScriptGraph.Wire(
            id: "w3", from: "m", to: "s",
            fromPin: TMHash.murmur64a("result"), toPin: TMHash.murmur64a("translation")
        )
        let graph = RCP3ScriptGraph(
            nodes: [added, set, mathAdd, v1, v2],
            wires: [exec, wV1, wV2, wOut], data: []
        )

        let js = CanonicalScriptGraphCompiler().compile(graph)

        // Vector add → Math3D.add, with Math3D bound (a vector add emits Math3D).
        #expect(js.contains("const Math3D = require(\"Math3D\")"))
        #expect(js.contains("this.entity.position = Math3D.add(new Math3D.Vector3("))
        // It must NOT keep the broken scalar `+` between the two vectors.
        #expect(!js.contains(") + new Math3D.Vector3("))
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

    @Test func authoredScalarLiteralsCompileIntoVectorConstructor() {
        // The end of the authoring loop: a `make_vector3` feeds a Set Transform, and
        // its x/z components carry AUTHORED scalar `data[]` literals (the editor wrote
        // them; the parser reads them back into `DataLiteral.scalarValue`). The unwired
        // y stays 0. The compiler must emit those literal values verbatim in the
        // constructor — proving an edited pin value is reflected in Play.
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component")
        let vec = RCP3ScriptGraph.Node(id: "v", type: "tm_make_vector3")
        let exec = RCP3ScriptGraph.Wire(id: "e1", from: "u", to: "s")
        let wOut = RCP3ScriptGraph.Wire(
            id: "w3", from: "v", to: "s",
            fromPin: TMHash.murmur64a("vec3"), toPin: TMHash.murmur64a("translation")
        )
        // Authored literals on x (= 2.5) and z (= -4); y unwired → 0.
        let xLiteral = RCP3ScriptGraph.DataLiteral(
            id: "lx", toNode: "v", toPin: TMHash.murmur64a("x"), scalarValue: 2.5
        )
        let zLiteral = RCP3ScriptGraph.DataLiteral(
            id: "lz", toNode: "v", toPin: TMHash.murmur64a("z"), scalarValue: -4
        )
        let graph = RCP3ScriptGraph(
            nodes: [update, set, vec],
            wires: [exec, wOut],
            data: [xLiteral, zLiteral]
        )

        let js = CanonicalScriptGraphCompiler().compile(graph)

        // The authored x/z literals appear verbatim in the constructor (x first, z
        // last); the unwired y falls back to 0. Proves an edited pin value is reflected
        // in the compiled (Play) output.
        #expect(js.contains("new Math3D.Vector3(2.5, 0 /* y unwired */, -4)"))
        #expect(js.contains("this.entity.position = new Math3D.Vector3("))
        // The authored pins are NOT reported as unwired (they carry a literal).
        #expect(!js.contains("x unwired"))
        #expect(!js.contains("z unwired"))
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

    @Test func getComponentReadsEntityTransformProperty() {
        // On Update → Set Transform.scale = Get Transform.scale: a Get Component feeding
        // the same property it reads. The Get node lowers to the entity's transform
        // property (the inverse of Set's mapping), so the wired path has no `unsupported`.
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let get = RCP3ScriptGraph.Node(id: "g", type: "tm_get_component", label: "Get Transform")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component", label: "Set Transform")
        let exec = RCP3ScriptGraph.Wire(id: "e1", from: "u", to: "s")
        let dataWire = RCP3ScriptGraph.Wire(
            id: "d1", from: "g", to: "s",
            fromPin: TMHash.murmur64a("scale"),
            toPin: TMHash.murmur64a("scale")
        )
        let graph = RCP3ScriptGraph(nodes: [update, get, set], wires: [exec, dataWire], data: [])

        let js = CanonicalScriptGraphCompiler().compile(graph)

        #expect(js.contains("this.update = function(deltaTime)"))
        // Get Transform.scale → the entity's scale; written straight back to scale.
        #expect(js.contains("this.entity.scale = this.entity.scale;"))
        #expect(!js.contains("unsupported"))
    }

    @Test func getComponentInsideGestureReadsViaEventEntity() {
        // Inside a gesture handler, a Get Component reads `event.entity.position` (the
        // dragged entity), matching the Set side's `event.entity.*` target rule.
        let tap = RCP3ScriptGraph.Node(id: "t", type: "tm_gesture_event_tap")
        let get = RCP3ScriptGraph.Node(id: "g", type: "tm_get_component")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component")
        let exec = RCP3ScriptGraph.Wire(id: "e1", from: "t", to: "s")
        let dataWire = RCP3ScriptGraph.Wire(
            id: "d1", from: "g", to: "s",
            fromPin: TMHash.murmur64a("translation"),
            toPin: TMHash.murmur64a("translation")
        )
        let graph = RCP3ScriptGraph(nodes: [tap, get, set], wires: [exec, dataWire], data: [])

        let js = CanonicalScriptGraphCompiler().compile(graph)

        #expect(js.contains("this.entity.on(RealityKit.TapGestureEvent.name"))
        #expect(js.contains("event.entity.position = event.entity.position;"))
        #expect(!js.contains("unsupported"))
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
