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

    @Test func componentTypeOnlySetAttachesKnownDefaultComponent() {
        for componentName in ["BillboardComponent", "AccessibilityComponent"] {
            let added = RCP3ScriptGraph.Node(id: "a", type: "tm_did_add")
            let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component", label: "Set \(componentName)")
            let exec = RCP3ScriptGraph.Wire(id: "e", from: "a", to: "s")
            let selector = RCP3ScriptGraph.DataLiteral(
                id: "component",
                toNode: "s",
                toPin: TMHash.murmur64a("component_type"),
                valueType: "re_scripting_graph_component_type",
                valueHash: TMHash.murmur64a(componentName)
            )

            let js = CanonicalScriptGraphCompiler().compile(RCP3ScriptGraph(nodes: [added, set], wires: [exec], data: [selector]))

            #expect(js.contains("const RealityKit = require(\"RealityKit\")"))
            #expect(js.contains("this.entity.setComponent(new RealityKit.\(componentName)());"))
            #expect(!js.contains("unsupported"))
        }
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

    @Test func variadicMathFoldsAThirdScalarInput() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_variable_node", variableName: "sum")
        let add = RCP3ScriptGraph.Node(id: "m", type: "tm_math_add")
        let wires = [
            RCP3ScriptGraph.Wire(id: "e", from: "u", to: "s"),
            RCP3ScriptGraph.Wire(
                id: "out", from: "m", to: "s",
                fromPin: TMHash.murmur64a("result"), toPin: TMHash.murmur64a("value")
            ),
        ]
        let data = [
            RCP3ScriptGraph.DataLiteral(id: "a", toNode: "m", toPin: TMHash.murmur64a("a"), scalarValue: 1),
            RCP3ScriptGraph.DataLiteral(id: "b", toNode: "m", toPin: TMHash.murmur64a("b"), scalarValue: 2),
            RCP3ScriptGraph.DataLiteral(id: "c", toNode: "m", toPin: TMHash.murmur64a("c"), scalarValue: 3),
        ]

        let js = CanonicalScriptGraphCompiler().compile(RCP3ScriptGraph(nodes: [update, set, add], wires: wires, data: data))

        #expect(js.contains("this.variable_") && js.contains(" = ((1 + 2) + 3);"))
        #expect(!js.contains("const Math3D = require"))
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

    @Test func variadicVectorAddFoldsAThirdVectorInput() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component")
        let add = RCP3ScriptGraph.Node(id: "m", type: "tm_math_add")
        let v1 = RCP3ScriptGraph.Node(id: "v1", type: "tm_make_vector3")
        let v2 = RCP3ScriptGraph.Node(id: "v2", type: "tm_make_vector3")
        let v3 = RCP3ScriptGraph.Node(id: "v3", type: "tm_make_vector3")
        let wires = [
            RCP3ScriptGraph.Wire(id: "e", from: "u", to: "s"),
            RCP3ScriptGraph.Wire(
                id: "a", from: "v1", to: "m",
                fromPin: TMHash.murmur64a("vec3"), toPin: TMHash.murmur64a("a")
            ),
            RCP3ScriptGraph.Wire(
                id: "b", from: "v2", to: "m",
                fromPin: TMHash.murmur64a("vec3"), toPin: TMHash.murmur64a("b")
            ),
            RCP3ScriptGraph.Wire(
                id: "c", from: "v3", to: "m",
                fromPin: TMHash.murmur64a("vec3"), toPin: TMHash.murmur64a("c")
            ),
            RCP3ScriptGraph.Wire(
                id: "out", from: "m", to: "s",
                fromPin: TMHash.murmur64a("result"), toPin: TMHash.murmur64a("translation")
            ),
        ]
        let data = [
            RCP3ScriptGraph.DataLiteral(id: "x1", toNode: "v1", toPin: TMHash.murmur64a("x"), scalarValue: 1),
            RCP3ScriptGraph.DataLiteral(id: "x2", toNode: "v2", toPin: TMHash.murmur64a("x"), scalarValue: 2),
            RCP3ScriptGraph.DataLiteral(id: "x3", toNode: "v3", toPin: TMHash.murmur64a("x"), scalarValue: 3),
        ]

        let js = CanonicalScriptGraphCompiler().compile(RCP3ScriptGraph(nodes: [update, set, add, v1, v2, v3], wires: wires, data: data))

        #expect(js.contains("const Math3D = require(\"Math3D\")"))
        #expect(js.contains("this.entity.position = Math3D.add(Math3D.add(new Math3D.Vector3(1,"))
        #expect(!js.contains(") + new Math3D.Vector3("))
        #expect(!js.contains("unsupported"))
    }

    @Test func clampCompilesToNestedMathMinMax() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_variable_node", variableName: "clamped")
        let clamp = RCP3ScriptGraph.Node(id: "m", type: "tm_math_clamp")
        let wires = [
            RCP3ScriptGraph.Wire(id: "e", from: "u", to: "s"),
            RCP3ScriptGraph.Wire(
                id: "out", from: "m", to: "s",
                fromPin: TMHash.murmur64a("result"), toPin: TMHash.murmur64a("value")
            ),
        ]
        let data = [
            RCP3ScriptGraph.DataLiteral(id: "a", toNode: "m", toPin: TMHash.murmur64a("a"), scalarValue: 12),
            RCP3ScriptGraph.DataLiteral(id: "min", toNode: "m", toPin: TMHash.murmur64a("min"), scalarValue: 2),
            RCP3ScriptGraph.DataLiteral(id: "max", toNode: "m", toPin: TMHash.murmur64a("max"), scalarValue: 8),
        ]

        let js = CanonicalScriptGraphCompiler().compile(RCP3ScriptGraph(nodes: [update, set, clamp], wires: wires, data: data))

        #expect(js.contains(" = Math.min(Math.max(12, 2), 8);"))
        #expect(!js.contains("const Math3D = require"))
        #expect(!js.contains("unsupported"))
    }

    @Test func multiplyFamilyCompilesToMath3DMultiply() {
        // The three multiply-by-X nodes all lower to the SAME `Math3D.multiply(a, b)`
        // call, reading their two operand pins `a`/`b`. Exercise the by-scalar variant
        // wiring a vector into `a` and a scalar literal into `b`.
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let setVector = RCP3ScriptGraph.Node(id: "setVector", type: "tm_set_component")
        let vectorMultiply = RCP3ScriptGraph.Node(id: "vector", type: "tm_math_multiply_by_scalar")
        let vec = RCP3ScriptGraph.Node(id: "vec", type: "tm_make_vector3")
        let wires = [
            RCP3ScriptGraph.Wire(id: "e2", from: "u", to: "setVector"),
            RCP3ScriptGraph.Wire(
                id: "vecIn", from: "vec", to: "vector",
                fromPin: TMHash.murmur64a("vec3"), toPin: TMHash.murmur64a("a")
            ),
            RCP3ScriptGraph.Wire(
                id: "vectorOut", from: "vector", to: "setVector",
                fromPin: TMHash.murmur64a("result"), toPin: TMHash.murmur64a("translation")
            ),
        ]
        let data = [
            RCP3ScriptGraph.DataLiteral(id: "vx", toNode: "vec", toPin: TMHash.murmur64a("x"), scalarValue: 1),
            RCP3ScriptGraph.DataLiteral(id: "vy", toNode: "vec", toPin: TMHash.murmur64a("y"), scalarValue: 2),
            RCP3ScriptGraph.DataLiteral(id: "vz", toNode: "vec", toPin: TMHash.murmur64a("z"), scalarValue: 3),
            RCP3ScriptGraph.DataLiteral(id: "vb", toNode: "vector", toPin: TMHash.murmur64a("b"), scalarValue: 0.5),
        ]

        let js = CanonicalScriptGraphCompiler().compile(
            RCP3ScriptGraph(nodes: [update, setVector, vectorMultiply, vec], wires: wires, data: data)
        )

        #expect(js.contains("const Math3D = require(\"Math3D\")"))
        #expect(js.contains("this.entity.position = Math3D.multiply(new Math3D.Vector3(1, 2, 3), 0.5);"))
        #expect(!js.contains("multiplyByScalar"))
        #expect(!js.contains("TODO: vector op"))
        #expect(!js.contains("unsupported"))
    }

    @Test func multiplyByQuaternionAndMatrixAlsoEmitMath3DMultiply() {
        // The quaternion/matrix variants share the same `Math3D.multiply(a, b)` emission.
        for type in ["tm_math_multiply_by_quaternion", "tm_math_multiply_by_matrix"] {
            let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
            let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component")
            let mul = RCP3ScriptGraph.Node(id: "m", type: type)
            let a = RCP3ScriptGraph.Node(id: "a", type: "tm_make_vector3")
            let b = RCP3ScriptGraph.Node(id: "b", type: "tm_make_vector3")
            let wires = [
                RCP3ScriptGraph.Wire(id: "e", from: "u", to: "s"),
                RCP3ScriptGraph.Wire(id: "wa", from: "a", to: "m", fromPin: TMHash.murmur64a("vec3"), toPin: TMHash.murmur64a("a")),
                RCP3ScriptGraph.Wire(id: "wb", from: "b", to: "m", fromPin: TMHash.murmur64a("vec3"), toPin: TMHash.murmur64a("b")),
                RCP3ScriptGraph.Wire(id: "out", from: "m", to: "s", fromPin: TMHash.murmur64a("result"), toPin: TMHash.murmur64a("translation")),
            ]
            let js = CanonicalScriptGraphCompiler().compile(RCP3ScriptGraph(nodes: [update, set, mul, a, b], wires: wires, data: []))
            #expect(js.contains("this.entity.position = Math3D.multiply(new Math3D.Vector3("))
            #expect(!js.contains("unsupported"))
        }
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

    @Test func makeRotationCompilesToMath3DQuaternionConstructor() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let rotation = RCP3ScriptGraph.Node(id: "r", type: "tm_make_rotation")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component")
        let exec = RCP3ScriptGraph.Wire(id: "e1", from: "u", to: "s")
        let wRotation = RCP3ScriptGraph.Wire(
            id: "w1", from: "r", to: "s",
            fromPin: TMHash.murmur64a("new"), toPin: TMHash.murmur64a("rotation")
        )
        let angle = RCP3ScriptGraph.DataLiteral(
            id: "angle", toNode: "r", toPin: TMHash.murmur64a("angle"), scalarValue: 1.25
        )
        let graph = RCP3ScriptGraph(nodes: [update, rotation, set], wires: [exec, wRotation], data: [angle])

        let js = CanonicalScriptGraphCompiler().compile(graph)

        #expect(js.contains("const Math3D = require(\"Math3D\")"))
        #expect(js.contains("this.entity.orientation = new Math3D.Quaternion(1.25, new Math3D.Vector3(0, 1, 0));"))
        #expect(!js.contains("unsupported"))
    }

    @Test func eulerToQuaternionCompilesToMath3DHelperCall() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let angles = RCP3ScriptGraph.Node(id: "v", type: "tm_make_vector3")
        let convert = RCP3ScriptGraph.Node(id: "q", type: "tm_math_euler_to_quaternion")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component")
        let graph = RCP3ScriptGraph(
            nodes: [update, angles, convert, set],
            wires: [
                RCP3ScriptGraph.Wire(id: "e1", from: "u", to: "s"),
                RCP3ScriptGraph.Wire(
                    id: "w1", from: "v", to: "q",
                    fromPin: TMHash.murmur64a("vec3"), toPin: TMHash.murmur64a("angles")
                ),
                RCP3ScriptGraph.Wire(
                    id: "w2", from: "q", to: "s",
                    fromPin: TMHash.murmur64a("quaternion"), toPin: TMHash.murmur64a("rotation")
                ),
            ],
            data: [
                RCP3ScriptGraph.DataLiteral(id: "x", toNode: "v", toPin: TMHash.murmur64a("x"), scalarValue: 0.1),
                RCP3ScriptGraph.DataLiteral(id: "y", toNode: "v", toPin: TMHash.murmur64a("y"), scalarValue: 0.2),
                RCP3ScriptGraph.DataLiteral(id: "z", toNode: "v", toPin: TMHash.murmur64a("z"), scalarValue: 0.3),
            ]
        )

        let js = CanonicalScriptGraphCompiler().compile(graph)

        #expect(js.contains("this.entity.orientation = Math3D.eulerAnglesToQuaternion(new Math3D.Vector3(0.1, 0.2, 0.3));"))
        #expect(!js.contains("unsupported"))
    }

    @Test func quaternionToEulerCompilesToMath3DHelperCall() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let rotation = RCP3ScriptGraph.Node(id: "r", type: "tm_make_rotation")
        let convert = RCP3ScriptGraph.Node(id: "e", type: "tm_math_quaternion_to_euler")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component")
        let graph = RCP3ScriptGraph(
            nodes: [update, rotation, convert, set],
            wires: [
                RCP3ScriptGraph.Wire(id: "e1", from: "u", to: "s"),
                RCP3ScriptGraph.Wire(
                    id: "w1", from: "r", to: "e",
                    fromPin: TMHash.murmur64a("new"), toPin: TMHash.murmur64a("quaternion")
                ),
                RCP3ScriptGraph.Wire(
                    id: "w2", from: "e", to: "s",
                    fromPin: TMHash.murmur64a("angles"), toPin: TMHash.murmur64a("translation")
                ),
            ],
            data: [
                RCP3ScriptGraph.DataLiteral(id: "angle", toNode: "r", toPin: TMHash.murmur64a("angle"), scalarValue: 0.75),
            ]
        )

        let js = CanonicalScriptGraphCompiler().compile(graph)

        #expect(js.contains("this.entity.position = Math3D.quaternionToEulerAngles(new Math3D.Quaternion(0.75, new Math3D.Vector3(0, 1, 0)));"))
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

    // MARK: - Local variables

    /// On Update → Set `angle` = (Get `angle` + deltaTime); Set Transform.rotation = Get
    /// `angle`. A LOCAL variable named on the Get/Set nodes must lower to the stable
    /// per-script slot `variable_<MurmurHash64A(lowercase("angle"))>`, with Get and Set
    /// resolving to the SAME slot and Get carrying the `?? 0` accumulator guard.
    @Test func localVariableGetAndSetUseTheSameSlotWithGuard() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let getAngle = RCP3ScriptGraph.Node(id: "g", type: "tm_get_variable_node", variableName: "angle")
        let add = RCP3ScriptGraph.Node(id: "m", type: "tm_math_add")
        let setAngle = RCP3ScriptGraph.Node(id: "sv", type: "tm_set_variable_node", variableName: "angle")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component")
        let e1 = RCP3ScriptGraph.Wire(id: "e1", from: "u", to: "sv")
        let e2 = RCP3ScriptGraph.Wire(id: "e2", from: "sv", to: "s")
        let wGet = RCP3ScriptGraph.Wire(
            id: "w1", from: "g", to: "m",
            fromPin: TMHash.murmur64a("value"), toPin: TMHash.murmur64a("a")
        )
        let wDt = RCP3ScriptGraph.Wire(
            id: "w2", from: "u", to: "m",
            fromPin: TMHash.murmur64a("deltaTime"), toPin: TMHash.murmur64a("b")
        )
        let wAdd = RCP3ScriptGraph.Wire(
            id: "w3", from: "m", to: "sv",
            fromPin: TMHash.murmur64a("result"), toPin: TMHash.murmur64a("value")
        )
        let wRot = RCP3ScriptGraph.Wire(
            id: "w4", from: "g", to: "s",
            fromPin: TMHash.murmur64a("value"), toPin: TMHash.murmur64a("rotation")
        )
        let graph = RCP3ScriptGraph(
            nodes: [update, getAngle, add, setAngle, set],
            wires: [e1, e2, wGet, wDt, wAdd, wRot], data: []
        )

        let js = CanonicalScriptGraphCompiler().compile(graph)

        // The slot is the decimal MurmurHash64A of the lowercased name — recomputed here,
        // never hard-coded.
        let slot = "variable_\(TMHash.murmur64a("angle"))"
        // Get reads `(this.variable_<slot> ?? 0)` (the `?? 0` accumulator guard).
        #expect(js.contains("(this.\(slot) ?? 0)"))
        // Set writes the SAME slot.
        #expect(js.contains("this.\(slot) = "))
        #expect(js.contains("this.update = function(deltaTime)"))
        // The accumulate-and-drive shape, all on the one slot.
        #expect(js.contains("this.\(slot) = ((this.\(slot) ?? 0) + deltaTime);"))
        #expect(js.contains("this.entity.orientation = (this.\(slot) ?? 0);"))
        // A local variable lowers to a slot, not the remote placeholder.
        #expect(!js.contains("RemoteValue"))
        #expect(!js.contains("variable name unresolved"))
        #expect(!js.contains("unsupported"))
    }

    /// A LOCAL clear node resets its slot to the numeric default `0`.
    @Test func localVariableClearResetsSlotToZero() {
        let added = RCP3ScriptGraph.Node(id: "a", type: "tm_did_add")
        let clear = RCP3ScriptGraph.Node(id: "c", type: "tm_clear_variable_node", variableName: "angle")
        let exec = RCP3ScriptGraph.Wire(id: "e1", from: "a", to: "c")
        let graph = RCP3ScriptGraph(nodes: [added, clear], wires: [exec], data: [])

        let js = CanonicalScriptGraphCompiler().compile(graph)

        let slot = "variable_\(TMHash.murmur64a("angle"))"
        #expect(js.contains("this.\(slot) = 0;"))
        #expect(!js.contains("unsupported"))
    }

    /// The READ path feeds emission: a variable node whose `variableName` was parsed
    /// from an on-disk `tm_graph_variable_ref` (here "Name1") compiles to the same
    /// `variable_<MurmurHash64A(lowercase(name))>` slot (lowercased, so "name1").
    @Test func variableNameLoadedFromDiskCompilesToLowercasedSlot() throws {
        // A minimal graph with a Get variable node carrying a `tm_graph_variable_ref`
        // on the murmur64a("name") connector — exactly the on-disk serialization.
        let nameHex = TMHash.hex(TMHash.murmur64a("name"))
        let text = """
        __type: "re_scripting_source_graph"
        __uuid: "root"
        graph: {
        \t__uuid: "g"
        \tnodes: [
        \t\t{ __uuid: "a" type: "tm_did_add" position: { __uuid: "pa" x: 0 y: 0 } }
        \t\t{ __uuid: "set" type: "tm_set_variable_node" position: { __uuid: "ps" x: 100 y: 0 } }
        \t]
        \tconnections: [ { __uuid: "e1" from_node: "a" to_node: "set" } ]
        \tdata: [
        \t\t{
        \t\t\t__uuid: "d1"
        \t\t\tto_node: "set"
        \t\t\tto_connector_hash: "\(nameHex)"
        \t\t\tdata: { __type: "tm_graph_variable_ref" __uuid: "v1" ref: "var-uuid" name: "Name1" }
        \t\t}
        \t]
        \tvariables: [ { __uuid: "var-uuid" name: "Name1" } ]
        }
        """
        let root = try #require(try TM.parse(text).objectValue)
        let tmGraph = try #require(root["graph"]?.objectValue)
        let graph = RCP3ScriptGraph(tmGraph: tmGraph)

        // The read path attached the name to the node (not a leaked data literal).
        #expect(graph.nodes.first { $0.id == "set" }?.variableName == "Name1")

        let js = CanonicalScriptGraphCompiler().compile(graph)

        // The compile slot lowercases the name → MurmurHash64A("name1").
        let slot = "variable_\(TMHash.murmur64a("name1"))"
        #expect(js.contains("this.\(slot) = "))
        #expect(!js.contains("variable name unresolved"))
        #expect(!js.contains("RemoteValue"))
    }

    /// A variable node with NO `variableName` (the on-disk reference isn't resolvable
    /// from the wire graph yet) falls back to the honest placeholder without crashing.
    @Test func variableNodeWithoutNameFallsBackWithoutCrashing() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let setVar = RCP3ScriptGraph.Node(id: "sv", type: "tm_set_variable_node")
        let getVar = RCP3ScriptGraph.Node(id: "g", type: "tm_get_variable_node")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component")
        let e1 = RCP3ScriptGraph.Wire(id: "e1", from: "u", to: "sv")
        let e2 = RCP3ScriptGraph.Wire(id: "e2", from: "sv", to: "s")
        let wVal = RCP3ScriptGraph.Wire(
            id: "w1", from: "g", to: "sv",
            fromPin: TMHash.murmur64a("value"), toPin: TMHash.murmur64a("value")
        )
        let wRot = RCP3ScriptGraph.Wire(
            id: "w2", from: "g", to: "s",
            fromPin: TMHash.murmur64a("value"), toPin: TMHash.murmur64a("rotation")
        )
        let graph = RCP3ScriptGraph(
            nodes: [update, setVar, getVar, set],
            wires: [e1, e2, wVal, wRot], data: []
        )

        let js = CanonicalScriptGraphCompiler().compile(graph)

        // No name → the honest remote placeholder, and it did NOT fabricate a slot.
        #expect(js.contains("variable name unresolved"))
        #expect(js.contains("this.getRemoteValue("))
        #expect(js.contains("this.setRemoteValue("))
        #expect(!js.contains("this.variable_"))
    }

    // MARK: - Console observability (one-time guarded logs)

    /// Each event handler emits a ONE-TIME `console.log` at its body entry, guarded by a
    /// per-handler instance flag — so the in-app console shows the handler fired without
    /// flooding. For `update` (which runs every frame) the guard is CRITICAL: the log
    /// must sit behind the instance flag, not run unguarded each frame.
    @Test func updateHandlerEmitsAOnceGuardedEntryLog() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component", label: "Set Transform")
        let pi = RCP3ScriptGraph.Node(id: "p", type: "tm_constant_pi")
        let exec = RCP3ScriptGraph.Wire(id: "e1", from: "u", to: "s")
        let dataWire = RCP3ScriptGraph.Wire(
            id: "d1", from: "p", to: "s",
            fromPin: TMHash.murmur64a("PI"), toPin: TMHash.murmur64a("translation")
        )
        let graph = RCP3ScriptGraph(nodes: [update, set, pi], wires: [exec, dataWire], data: [])

        let js = CanonicalScriptGraphCompiler().compile(graph)

        #expect(js.contains("this.update = function(deltaTime)"))
        // The entry log is guarded by a per-handler instance flag — set on first call so
        // it can't flood on a per-frame `update`. The exact guard pattern is asserted so
        // an unguarded `console.log("[D3] update fired")` can't slip in.
        #expect(js.contains("if (!this.__d3_log_update) { this.__d3_log_update = true; console.log(\"[D3] update fired\"); }"))
        // The behavior line (the transform assignment) is unchanged and stays unguarded.
        #expect(js.contains("this.entity.position = Math.PI;"))
    }

    /// A lifecycle handler (didAdd) also emits a one-time, instance-flag-guarded entry
    /// log, keyed by the handler name so each lifecycle hook logs exactly once.
    @Test func lifecycleHandlerEmitsAOnceGuardedEntryLog() {
        let added = RCP3ScriptGraph.Node(id: "a", type: "tm_did_add")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component")
        let pi = RCP3ScriptGraph.Node(id: "p", type: "tm_constant_pi")
        let exec = RCP3ScriptGraph.Wire(id: "e1", from: "a", to: "s")
        let dataWire = RCP3ScriptGraph.Wire(
            id: "d1", from: "p", to: "s",
            fromPin: TMHash.murmur64a("PI"), toPin: TMHash.murmur64a("translation")
        )
        let graph = RCP3ScriptGraph(nodes: [added, set, pi], wires: [exec, dataWire], data: [])

        let js = CanonicalScriptGraphCompiler().compile(graph)

        #expect(js.contains("if (!this.__d3_log_didAdd) { this.__d3_log_didAdd = true; console.log(\"[D3] didAdd fired\"); }"))
    }

    /// A gesture (drag) handler emits its one-time entry log inside the subscription
    /// body, guarded by its own instance flag so a held drag logs only once.
    @Test func dragGestureHandlerEmitsAOnceGuardedEntryLog() {
        let js = CanonicalScriptGraphCompiler().compile(Self.dragToSetTranslationGraph())

        #expect(js.contains("this.entity.on(RealityKit.DragGestureEvent.name"))
        #expect(js.contains("if (!this.__d3_log_drag) { this.__d3_log_drag = true; console.log(\"[D3] drag fired\"); }"))
        // The reference drag behavior is unchanged (still drives event.entity.position).
        #expect(js.contains("event.entity.position = Math3D.add(dragStart, event.sceneTranslation)"))
    }

    /// Each `tm_set_component` Set emits a ONE-TIME log of the property + value next to
    /// the assignment, guarded by a unique per-set instance flag — so a per-frame Set
    /// logs its value exactly once, while the assignment itself stays UNGUARDED (runs
    /// every frame as before).
    @Test func setComponentEmitsAOnceGuardedValueLogNextToTheUnguardedAssignment() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component", label: "Set Transform")
        let pi = RCP3ScriptGraph.Node(id: "p", type: "tm_constant_pi")
        let exec = RCP3ScriptGraph.Wire(id: "e1", from: "u", to: "s")
        let dataWire = RCP3ScriptGraph.Wire(
            id: "d1", from: "p", to: "s",
            fromPin: TMHash.murmur64a("PI"), toPin: TMHash.murmur64a("translation")
        )
        let graph = RCP3ScriptGraph(nodes: [update, set, pi], wires: [exec, dataWire], data: [])

        let js = CanonicalScriptGraphCompiler().compile(graph)

        // The Set's value log is guarded by a unique per-set flag (sanitized set-node id
        // + property), logs the property name + the value (string-concatenated), and runs
        // exactly once even inside the per-frame `update`.
        #expect(js.contains("if (!this.__d3_log_set_s_position) { this.__d3_log_set_s_position = true; console.log(\"[D3] set position = \" + (Math.PI)); }"))
        // The assignment itself is NOT guarded — it must run every frame, so it appears
        // as the bare assignment statement (on its own line), not folded into the guard.
        #expect(js.contains("\n    this.entity.position = Math.PI;\n"))
    }

    /// Builds `On Update → Set Transform.translation = <vector-op>(a[, b])`, wiring a
    /// `tm_make_vector3` constructor into the op's `a` pin (and, for binary ops, a second
    /// into `b`) and its `result` into the Set's translation pin. Returns the JS.
    static func vectorOpJS(type: String, binary: Bool) -> String {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component")
        let op = RCP3ScriptGraph.Node(id: "m", type: type)
        let va = RCP3ScriptGraph.Node(id: "va", type: "tm_make_vector3")
        var nodes = [update, set, op, va]
        var wires = [
            RCP3ScriptGraph.Wire(id: "e1", from: "u", to: "s"),
            RCP3ScriptGraph.Wire(id: "wa", from: "va", to: "m", fromPin: TMHash.murmur64a("vec3"), toPin: TMHash.murmur64a("a")),
            RCP3ScriptGraph.Wire(id: "out", from: "m", to: "s", fromPin: TMHash.murmur64a("result"), toPin: TMHash.murmur64a("translation")),
        ]
        if binary {
            let vb = RCP3ScriptGraph.Node(id: "vb", type: "tm_make_vector3")
            nodes.append(vb)
            wires.append(RCP3ScriptGraph.Wire(id: "wb", from: "vb", to: "m", fromPin: TMHash.murmur64a("vec3"), toPin: TMHash.murmur64a("b")))
        }
        return CanonicalScriptGraphCompiler().compile(RCP3ScriptGraph(nodes: nodes, wires: wires, data: []))
    }

    @Test func vectorMathOpsEmitFaithfulMath3DCalls() {
        // dot/cross/reflect take two operands; length/normal take one. The function name
        // is the observed Math3D name (NOTE: normalize's function is `normal`).
        for (type, fn, binary) in [
            ("tm_math_dot", "dot", true),
            ("tm_math_cross", "cross", true),
            ("tm_math_reflect", "reflect", true),
            ("tm_math_length", "length", false),
            ("tm_math_normal", "normal", false),
        ] {
            let js = Self.vectorOpJS(type: type, binary: binary)
            #expect(js.contains("const Math3D = require(\"Math3D\")"))
            #expect(js.contains("Math3D.\(fn)(new Math3D.Vector3("))
            if !binary {
                // Unary: a single operand, no comma-joined second argument.
                #expect(js.contains("Math3D.\(fn)(new Math3D.Vector3(0 /* x unwired */, 0 /* y unwired */, 0 /* z unwired */));"))
            }
            // No fallback note survives on these any more.
            #expect(!js.contains("Math3D op name not public"))
            #expect(!js.contains("unsupported"))
        }
        // `tm_math_normal` is the normalize node — its function is literally `normal`,
        // NOT `normalize`.
        #expect(!Self.vectorOpJS(type: "tm_math_normal", binary: false).contains("normalize"))
    }

    // MARK: - Phase 0: comparisons / logic / bitwise / deg-rad / string / vector2-4

    /// Builds `On Update → Set Transform.translation = <op>(<two constant inputs>)`,
    /// wiring the op node's `a`/`b` operands from a π and an e constant and its
    /// `result` output into the Set's translation pin. Returns the compiled JS so a
    /// family test can assert the emitted operator without re-stating the wiring.
    /// `resultPin` is the op node's output connector name (`result` for most nodes).
    static func opOfTwoConstantsJS(opType: String, resultPin: String = "result") -> String {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component", label: "Set Transform")
        let op = RCP3ScriptGraph.Node(id: "m", type: opType)
        let pi = RCP3ScriptGraph.Node(id: "p", type: "tm_constant_pi")
        let e = RCP3ScriptGraph.Node(id: "e", type: "tm_constant_e")
        let exec = RCP3ScriptGraph.Wire(id: "e1", from: "u", to: "s")
        let wA = RCP3ScriptGraph.Wire(
            id: "w1", from: "p", to: "m",
            fromPin: TMHash.murmur64a("PI"), toPin: TMHash.murmur64a("a")
        )
        let wB = RCP3ScriptGraph.Wire(
            id: "w2", from: "e", to: "m",
            fromPin: TMHash.murmur64a("E"), toPin: TMHash.murmur64a("b")
        )
        let wOut = RCP3ScriptGraph.Wire(
            id: "w3", from: "m", to: "s",
            fromPin: TMHash.murmur64a(resultPin), toPin: TMHash.murmur64a("translation")
        )
        let graph = RCP3ScriptGraph(
            nodes: [update, set, op, pi, e],
            wires: [exec, wA, wB, wOut], data: []
        )
        return CanonicalScriptGraphCompiler().compile(graph)
    }

    @Test func comparisonNodesCompileToInfixComparisons() {
        for (type, op) in [
            ("tm_math_greater", "> "),
            ("tm_math_greater_equal", ">= "),
            ("tm_math_less", "< "),
            ("tm_math_less_equal", "<= "),
        ] {
            let js = Self.opOfTwoConstantsJS(opType: type)
            #expect(js.contains("(Math.PI \(op)Math.E)"))
            #expect(!js.contains("unsupported"))
            #expect(!js.contains("0 /*"))
        }
    }

    @Test func withinRangeCompilesToInclusiveBoundsCheck() {
        // val/min/max pins; val wired from π, min/max fall back to their scalar default.
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component")
        let wr = RCP3ScriptGraph.Node(id: "m", type: "tm_math_within_range")
        let pi = RCP3ScriptGraph.Node(id: "p", type: "tm_constant_pi")
        let exec = RCP3ScriptGraph.Wire(id: "e1", from: "u", to: "s")
        let wVal = RCP3ScriptGraph.Wire(
            id: "w1", from: "p", to: "m",
            fromPin: TMHash.murmur64a("PI"), toPin: TMHash.murmur64a("val")
        )
        let wOut = RCP3ScriptGraph.Wire(
            id: "w3", from: "m", to: "s",
            fromPin: TMHash.murmur64a("result"), toPin: TMHash.murmur64a("translation")
        )
        // min = -1, max = 1 baked as authored literals.
        let lo = RCP3ScriptGraph.DataLiteral(id: "l1", toNode: "m", toPin: TMHash.murmur64a("min"), scalarValue: -1)
        let hi = RCP3ScriptGraph.DataLiteral(id: "l2", toNode: "m", toPin: TMHash.murmur64a("max"), scalarValue: 1)
        let graph = RCP3ScriptGraph(nodes: [update, set, wr, pi], wires: [exec, wVal, wOut], data: [lo, hi])

        let js = CanonicalScriptGraphCompiler().compile(graph)

        #expect(js.contains("(Math.PI >= -1 && Math.PI <= 1)"))
        #expect(!js.contains("unsupported"))
    }

    @Test func randomCompilesToMathRandom() {
        // Random's pins are `min`/`max`; wire them from constants so the ranged form
        // reads them (and exercise the unwired fallback collapsing to the unit range).
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component")
        let rnd = RCP3ScriptGraph.Node(id: "m", type: "tm_math_random")
        let exec = RCP3ScriptGraph.Wire(id: "e1", from: "u", to: "s")
        let wOut = RCP3ScriptGraph.Wire(
            id: "w3", from: "m", to: "s",
            fromPin: TMHash.murmur64a("result"), toPin: TMHash.murmur64a("translation")
        )
        // min = 0, max = 10 baked as authored literals.
        let lo = RCP3ScriptGraph.DataLiteral(id: "l1", toNode: "m", toPin: TMHash.murmur64a("min"), scalarValue: 0)
        let hi = RCP3ScriptGraph.DataLiteral(id: "l2", toNode: "m", toPin: TMHash.murmur64a("max"), scalarValue: 10)
        let graph = RCP3ScriptGraph(nodes: [update, set, rnd], wires: [exec, wOut], data: [lo, hi])

        let js = CanonicalScriptGraphCompiler().compile(graph)

        #expect(js.contains("Math.random()"))
        #expect(js.contains("(0 + Math.random() * (10 - 0))"))
        #expect(!js.contains("unsupported"))
    }

    @Test func logicNodesCompileToShortCircuitOperators() {
        let andJS = Self.opOfTwoConstantsJS(opType: "tm_and")
        #expect(andJS.contains("(Math.PI && Math.E)"))
        #expect(!andJS.contains("unsupported"))

        let orJS = Self.opOfTwoConstantsJS(opType: "tm_or")
        #expect(orJS.contains("(Math.PI || Math.E)"))
        #expect(!orJS.contains("unsupported"))
    }

    @Test func equalityNodesCompileToLooseEquality() {
        // The observed emission is LOOSE `==` / `!=`, not strict `===` / `!==`.
        let equalsJS = Self.opOfTwoConstantsJS(opType: "tm_equals")
        #expect(equalsJS.contains("(Math.PI == Math.E)"))
        #expect(!equalsJS.contains("==="))
        #expect(!equalsJS.contains("unsupported"))

        let notEqualsJS = Self.opOfTwoConstantsJS(opType: "tm_not_equals")
        #expect(notEqualsJS.contains("(Math.PI != Math.E)"))
        #expect(!notEqualsJS.contains("!=="))
        #expect(!notEqualsJS.contains("unsupported"))
    }

    @Test func notNodeCompilesToInequalityWithLiteralTrue() {
        // The observed emission negates via inequality to the literal `true` —
        // `(a != true)` — over the single operand `a`, NOT `(!a)`.
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component")
        let not = RCP3ScriptGraph.Node(id: "m", type: "tm_not")
        let pi = RCP3ScriptGraph.Node(id: "p", type: "tm_constant_pi")
        let exec = RCP3ScriptGraph.Wire(id: "e1", from: "u", to: "s")
        let wA = RCP3ScriptGraph.Wire(id: "w1", from: "p", to: "m", fromPin: TMHash.murmur64a("PI"), toPin: TMHash.murmur64a("a"))
        let wOut = RCP3ScriptGraph.Wire(id: "w3", from: "m", to: "s", fromPin: TMHash.murmur64a("result"), toPin: TMHash.murmur64a("translation"))
        let graph = RCP3ScriptGraph(nodes: [update, set, not, pi], wires: [exec, wA, wOut], data: [])

        let js = CanonicalScriptGraphCompiler().compile(graph)

        #expect(js.contains("(Math.PI != true)"))
        #expect(!js.contains("(!Math.PI)"))
        #expect(!js.contains("unsupported"))
    }

    @Test func variadicLogicFoldsAThirdWiredInput() {
        // `tm_and` with a third operand pin `c` wired (variadic fold).
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component")
        let and = RCP3ScriptGraph.Node(id: "m", type: "tm_and")
        let pi = RCP3ScriptGraph.Node(id: "p", type: "tm_constant_pi")
        let e = RCP3ScriptGraph.Node(id: "e", type: "tm_constant_e")
        let ln2 = RCP3ScriptGraph.Node(id: "l", type: "tm_constant_ln2")
        let exec = RCP3ScriptGraph.Wire(id: "e1", from: "u", to: "s")
        let wA = RCP3ScriptGraph.Wire(id: "w1", from: "p", to: "m", fromPin: TMHash.murmur64a("PI"), toPin: TMHash.murmur64a("a"))
        let wB = RCP3ScriptGraph.Wire(id: "w2", from: "e", to: "m", fromPin: TMHash.murmur64a("E"), toPin: TMHash.murmur64a("b"))
        let wC = RCP3ScriptGraph.Wire(id: "w3", from: "l", to: "m", fromPin: TMHash.murmur64a("LN2"), toPin: TMHash.murmur64a("c"))
        let wOut = RCP3ScriptGraph.Wire(id: "w4", from: "m", to: "s", fromPin: TMHash.murmur64a("result"), toPin: TMHash.murmur64a("translation"))
        let graph = RCP3ScriptGraph(nodes: [update, set, and, pi, e, ln2], wires: [exec, wA, wB, wC, wOut], data: [])

        let js = CanonicalScriptGraphCompiler().compile(graph)

        #expect(js.contains("(Math.PI && Math.E && Math.LN2)"))
        #expect(!js.contains("unsupported"))
    }

    @Test func bitwiseNodesCompileToBitwiseOperators() {
        for (type, op) in [
            ("tm_math_bitwise_and", "&"),
            ("tm_math_bitwise_or", "|"),
            ("tm_math_bitwise_xor", "^"),
        ] {
            let js = Self.opOfTwoConstantsJS(opType: type)
            #expect(js.contains("(Math.PI \(op) Math.E)"))
            #expect(!js.contains("unsupported"))
        }
    }

    @Test func variadicBitwiseFoldsAThirdInput() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_variable_node", variableName: "mask")
        let or = RCP3ScriptGraph.Node(id: "m", type: "tm_math_bitwise_or")
        let wires = [
            RCP3ScriptGraph.Wire(id: "e", from: "u", to: "s"),
            RCP3ScriptGraph.Wire(
                id: "out", from: "m", to: "s",
                fromPin: TMHash.murmur64a("result"), toPin: TMHash.murmur64a("value")
            ),
        ]
        let data = [
            RCP3ScriptGraph.DataLiteral(id: "a", toNode: "m", toPin: TMHash.murmur64a("a"), scalarValue: 1),
            RCP3ScriptGraph.DataLiteral(id: "b", toNode: "m", toPin: TMHash.murmur64a("b"), scalarValue: 2),
            RCP3ScriptGraph.DataLiteral(id: "c", toNode: "m", toPin: TMHash.murmur64a("c"), scalarValue: 4),
        ]

        let js = CanonicalScriptGraphCompiler().compile(RCP3ScriptGraph(nodes: [update, set, or], wires: wires, data: data))

        #expect(js.contains("this.variable_") && js.contains(" = ((1 | 2) | 4);"))
        #expect(!js.contains("unsupported"))
    }

    @Test func bitwiseNotCompilesToTildeUnary() {
        // Unary bitwise NOT over the `a` operand (wired from π).
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component")
        let not = RCP3ScriptGraph.Node(id: "m", type: "tm_math_bitwise_not")
        let pi = RCP3ScriptGraph.Node(id: "p", type: "tm_constant_pi")
        let exec = RCP3ScriptGraph.Wire(id: "e1", from: "u", to: "s")
        let wA = RCP3ScriptGraph.Wire(id: "w1", from: "p", to: "m", fromPin: TMHash.murmur64a("PI"), toPin: TMHash.murmur64a("a"))
        let wOut = RCP3ScriptGraph.Wire(id: "w3", from: "m", to: "s", fromPin: TMHash.murmur64a("result"), toPin: TMHash.murmur64a("translation"))
        let graph = RCP3ScriptGraph(nodes: [update, set, not, pi], wires: [exec, wA, wOut], data: [])

        let js = CanonicalScriptGraphCompiler().compile(graph)

        #expect(js.contains("(~Math.PI)"))
        #expect(!js.contains("unsupported"))
    }

    @Test func degRadConversionsCompileToScaledExpressions() {
        // Degrees → Radians: input pin `degrees`.
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component")
        let d2r = RCP3ScriptGraph.Node(id: "m", type: "tm_math_deg_to_rad")
        let pi = RCP3ScriptGraph.Node(id: "p", type: "tm_constant_pi")
        let exec = RCP3ScriptGraph.Wire(id: "e1", from: "u", to: "s")
        let wIn = RCP3ScriptGraph.Wire(id: "w1", from: "p", to: "m", fromPin: TMHash.murmur64a("PI"), toPin: TMHash.murmur64a("degrees"))
        let wOut = RCP3ScriptGraph.Wire(id: "w3", from: "m", to: "s", fromPin: TMHash.murmur64a("result"), toPin: TMHash.murmur64a("translation"))
        let d2rGraph = RCP3ScriptGraph(nodes: [update, set, d2r, pi], wires: [exec, wIn, wOut], data: [])
        let d2rJS = CanonicalScriptGraphCompiler().compile(d2rGraph)
        #expect(d2rJS.contains("* Math.PI / 180"))
        #expect(!d2rJS.contains("unsupported"))

        // Radians → Degrees: input pin `rad`.
        let r2d = RCP3ScriptGraph.Node(id: "m2", type: "tm_math_rad_to_deg")
        let wIn2 = RCP3ScriptGraph.Wire(id: "w4", from: "p", to: "m2", fromPin: TMHash.murmur64a("PI"), toPin: TMHash.murmur64a("rad"))
        let wOut2 = RCP3ScriptGraph.Wire(id: "w5", from: "m2", to: "s", fromPin: TMHash.murmur64a("result"), toPin: TMHash.murmur64a("translation"))
        let r2dGraph = RCP3ScriptGraph(nodes: [update, set, r2d, pi], wires: [exec, wIn2, wOut2], data: [])
        let r2dJS = CanonicalScriptGraphCompiler().compile(r2dGraph)
        #expect(r2dJS.contains("* 180 / Math.PI"))
        #expect(!r2dJS.contains("unsupported"))
    }

    /// Builds `On Update → Set Transform.translation = <string node>(...)` with the
    /// `string` input wired from a variable Get (so the emitted base is a non-trivial
    /// expression) and returns the compiled JS. The arg pins fall back to their scalar
    /// default (the wired path is what we assert).
    static func stringNodeJS(type: String) -> String {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component")
        let str = RCP3ScriptGraph.Node(id: "m", type: type)
        let getVar = RCP3ScriptGraph.Node(id: "g", type: "tm_get_variable_node", variableName: "label")
        let exec = RCP3ScriptGraph.Wire(id: "e1", from: "u", to: "s")
        let wStr = RCP3ScriptGraph.Wire(
            id: "w1", from: "g", to: "m",
            fromPin: TMHash.murmur64a("value"), toPin: TMHash.murmur64a("string")
        )
        let resultPin = type == "tm_string_length" ? "length" : "result"
        let wOut = RCP3ScriptGraph.Wire(
            id: "w3", from: "m", to: "s",
            fromPin: TMHash.murmur64a(resultPin), toPin: TMHash.murmur64a("translation")
        )
        let graph = RCP3ScriptGraph(nodes: [update, set, str, getVar], wires: [exec, wStr, wOut], data: [])
        return CanonicalScriptGraphCompiler().compile(graph)
    }

    @Test func stringPredicatesAndAccessorsCompileToJSStringOps() {
        #expect(Self.stringNodeJS(type: "tm_string_has_prefix").contains(".startsWith("))
        #expect(Self.stringNodeJS(type: "tm_string_has_suffix").contains(".endsWith("))
        #expect(Self.stringNodeJS(type: "tm_string_contains").contains(".includes("))
        #expect(Self.stringNodeJS(type: "tm_string_length").contains(".length"))
        #expect(Self.stringNodeJS(type: "tm_string_prefix").contains(".slice(0, "))
        #expect(Self.stringNodeJS(type: "tm_string_suffix").contains(".slice(-("))
        #expect(Self.stringNodeJS(type: "tm_string_substring").contains(".substring("))
        // None of these wired-string paths fall through to the unsupported fallback.
        for type in [
            "tm_string_has_prefix", "tm_string_has_suffix", "tm_string_contains",
            "tm_string_length", "tm_string_prefix", "tm_string_suffix", "tm_string_substring",
        ] {
            #expect(!Self.stringNodeJS(type: type).contains("unsupported: \(type)"))
        }
    }

    @Test func makeVector2CompilesToMath3DVector2() {
        // On Update → Set.translation = Vector2(2.5, <unwired y → 0>).
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component")
        let vec = RCP3ScriptGraph.Node(id: "v", type: "tm_make_vector2")
        let exec = RCP3ScriptGraph.Wire(id: "e1", from: "u", to: "s")
        let wOut = RCP3ScriptGraph.Wire(
            id: "w3", from: "v", to: "s",
            fromPin: TMHash.murmur64a("vec2"), toPin: TMHash.murmur64a("translation")
        )
        let xLiteral = RCP3ScriptGraph.DataLiteral(id: "lx", toNode: "v", toPin: TMHash.murmur64a("x"), scalarValue: 2.5)
        let graph = RCP3ScriptGraph(nodes: [update, set, vec], wires: [exec, wOut], data: [xLiteral])

        let js = CanonicalScriptGraphCompiler().compile(graph)

        #expect(js.contains("const Math3D = require(\"Math3D\")"))
        #expect(js.contains("new Math3D.Vector2(2.5, 0 /* y unwired */)"))
        #expect(js.contains("this.entity.position = new Math3D.Vector2("))
        #expect(!js.contains("unsupported"))
    }

    @Test func makeVector4CompilesToMath3DVector4() {
        // On Update → Set.translation = Vector4(1, <y→0>, <z→0>, 4) with x/w authored.
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component")
        let vec = RCP3ScriptGraph.Node(id: "v", type: "tm_make_vector4")
        let exec = RCP3ScriptGraph.Wire(id: "e1", from: "u", to: "s")
        let wOut = RCP3ScriptGraph.Wire(
            id: "w3", from: "v", to: "s",
            fromPin: TMHash.murmur64a("vector"), toPin: TMHash.murmur64a("translation")
        )
        let xLiteral = RCP3ScriptGraph.DataLiteral(id: "lx", toNode: "v", toPin: TMHash.murmur64a("x"), scalarValue: 1)
        let wLiteral = RCP3ScriptGraph.DataLiteral(id: "lw", toNode: "v", toPin: TMHash.murmur64a("w"), scalarValue: 4)
        let graph = RCP3ScriptGraph(nodes: [update, set, vec], wires: [exec, wOut], data: [xLiteral, wLiteral])

        let js = CanonicalScriptGraphCompiler().compile(graph)

        #expect(js.contains("const Math3D = require(\"Math3D\")"))
        #expect(js.contains("new Math3D.Vector4(1, 0 /* y unwired */, 0 /* z unwired */, 4)"))
        #expect(js.contains("this.entity.position = new Math3D.Vector4("))
        #expect(!js.contains("unsupported"))
    }

    @Test func makeVector4WithVector3ReadsXYZComponents() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component")
        let vec3 = RCP3ScriptGraph.Node(id: "v3", type: "tm_make_vector3")
        let vec4 = RCP3ScriptGraph.Node(id: "v4", type: "tm_make_vector4_with_vector3")
        let wires = [
            RCP3ScriptGraph.Wire(id: "e1", from: "u", to: "s"),
            RCP3ScriptGraph.Wire(
                id: "xyz", from: "v3", to: "v4",
                fromPin: TMHash.murmur64a("vec3"), toPin: TMHash.murmur64a("xyz")
            ),
            RCP3ScriptGraph.Wire(
                id: "out", from: "v4", to: "s",
                fromPin: TMHash.murmur64a("vector"), toPin: TMHash.murmur64a("translation")
            ),
        ]
        let data = [
            RCP3ScriptGraph.DataLiteral(id: "x", toNode: "v3", toPin: TMHash.murmur64a("x"), scalarValue: 1),
            RCP3ScriptGraph.DataLiteral(id: "y", toNode: "v3", toPin: TMHash.murmur64a("y"), scalarValue: 2),
            RCP3ScriptGraph.DataLiteral(id: "z", toNode: "v3", toPin: TMHash.murmur64a("z"), scalarValue: 3),
            RCP3ScriptGraph.DataLiteral(id: "w", toNode: "v4", toPin: TMHash.murmur64a("w"), scalarValue: 4),
        ]

        let js = CanonicalScriptGraphCompiler().compile(RCP3ScriptGraph(nodes: [update, set, vec3, vec4], wires: wires, data: data))

        #expect(js.contains("const Math3D = require(\"Math3D\")"))
        #expect(js.contains("const xyz = new Math3D.Vector3(1, 2, 3); return new Math3D.Vector4(xyz.x, xyz.y, xyz.z, 4);"))
        #expect(!js.contains("unsupported"))
    }

    @Test func ifCompilesAlwaysThenTrueFalseBranches() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let branch = RCP3ScriptGraph.Node(id: "if", type: "tm_if")
        let always = RCP3ScriptGraph.Node(id: "a", type: "tm_set_variable_node", variableName: "always")
        let truthy = RCP3ScriptGraph.Node(id: "t", type: "tm_set_variable_node", variableName: "truthy")
        let falsy = RCP3ScriptGraph.Node(id: "f", type: "tm_set_variable_node", variableName: "falsy")
        let wires = [
            RCP3ScriptGraph.Wire(id: "e0", from: "u", to: "if"),
            RCP3ScriptGraph.Wire(id: "ea", from: "if", to: "a", fromPin: TMHash.murmur64a("always"), toPin: TMHash.murmur64a("")),
            RCP3ScriptGraph.Wire(id: "et", from: "if", to: "t", fromPin: TMHash.murmur64a("true"), toPin: TMHash.murmur64a("")),
            RCP3ScriptGraph.Wire(id: "ef", from: "if", to: "f", fromPin: TMHash.murmur64a("false"), toPin: TMHash.murmur64a("")),
        ]
        let data = [
            RCP3ScriptGraph.DataLiteral(id: "c", toNode: "if", toPin: TMHash.murmur64a("condition"), scalarValue: 1),
            RCP3ScriptGraph.DataLiteral(id: "la", toNode: "a", toPin: TMHash.murmur64a("value"), scalarValue: 10),
            RCP3ScriptGraph.DataLiteral(id: "lt", toNode: "t", toPin: TMHash.murmur64a("value"), scalarValue: 20),
            RCP3ScriptGraph.DataLiteral(id: "lf", toNode: "f", toPin: TMHash.murmur64a("value"), scalarValue: 30),
        ]

        let js = CanonicalScriptGraphCompiler().compile(RCP3ScriptGraph(nodes: [update, branch, always, truthy, falsy], wires: wires, data: data))

        #expect(js.contains("this.variable_8744360917969063771 = 10;"))
        #expect(js.contains("if (1) {"))
        #expect(js.contains("this.variable_5875689825633950935 = 20;"))
        #expect(js.contains("} else {"))
        #expect(js.contains("this.variable_10036592113519658831 = 30;"))
        #expect(!js.contains("unsupported"))
    }

    @Test func sequenceCompilesConnectedOutputsInConnectorOrder() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let sequence = RCP3ScriptGraph.Node(id: "seq", type: "tm_sequence")
        let first = RCP3ScriptGraph.Node(id: "first", type: "tm_set_variable_node", variableName: "first")
        let second = RCP3ScriptGraph.Node(id: "second", type: "tm_set_variable_node", variableName: "second")
        let wires = [
            RCP3ScriptGraph.Wire(id: "e0", from: "u", to: "seq"),
            RCP3ScriptGraph.Wire(id: "e2", from: "seq", to: "second", fromPin: 2, toPin: TMHash.murmur64a("")),
            RCP3ScriptGraph.Wire(id: "e1", from: "seq", to: "first", fromPin: 1, toPin: TMHash.murmur64a("")),
        ]
        let data = [
            RCP3ScriptGraph.DataLiteral(id: "l1", toNode: "first", toPin: TMHash.murmur64a("value"), scalarValue: 1),
            RCP3ScriptGraph.DataLiteral(id: "l2", toNode: "second", toPin: TMHash.murmur64a("value"), scalarValue: 2),
        ]

        let js = CanonicalScriptGraphCompiler().compile(RCP3ScriptGraph(nodes: [update, sequence, first, second], wires: wires, data: data))

        let firstWrite = " = 1;"
        let secondWrite = " = 2;"
        #expect(js.range(of: firstWrite) != nil)
        #expect(js.range(of: secondWrite) != nil)
        #expect(js.range(of: firstWrite)!.lowerBound < js.range(of: secondWrite)!.lowerBound)
        #expect(!js.contains("unsupported"))
    }

    @Test func switchCompilesCasesPlusDefaultFromDynamicOutputs() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let switchNode = RCP3ScriptGraph.Node(id: "sw", type: "tm_switch")
        let case0 = RCP3ScriptGraph.Node(id: "c0", type: "tm_set_variable_node", variableName: "case0")
        let case1 = RCP3ScriptGraph.Node(id: "c1", type: "tm_set_variable_node", variableName: "case1")
        let fallback = RCP3ScriptGraph.Node(id: "d", type: "tm_set_variable_node", variableName: "fallback")
        let wires = [
            RCP3ScriptGraph.Wire(id: "e0", from: "u", to: "sw"),
            RCP3ScriptGraph.Wire(id: "o0", from: "sw", to: "c0", fromPin: 1, toPin: TMHash.murmur64a("")),
            RCP3ScriptGraph.Wire(id: "o1", from: "sw", to: "c1", fromPin: 2, toPin: TMHash.murmur64a("")),
            RCP3ScriptGraph.Wire(id: "od", from: "sw", to: "d", fromPin: 3, toPin: TMHash.murmur64a("")),
        ]
        let data = [
            RCP3ScriptGraph.DataLiteral(id: "cond", toNode: "sw", toPin: TMHash.murmur64a("condition"), scalarValue: 6),
            RCP3ScriptGraph.DataLiteral(id: "first", toNode: "sw", toPin: TMHash.murmur64a("first"), scalarValue: 5),
            RCP3ScriptGraph.DataLiteral(id: "v0", toNode: "c0", toPin: TMHash.murmur64a("value"), scalarValue: 10),
            RCP3ScriptGraph.DataLiteral(id: "v1", toNode: "c1", toPin: TMHash.murmur64a("value"), scalarValue: 11),
            RCP3ScriptGraph.DataLiteral(id: "vd", toNode: "d", toPin: TMHash.murmur64a("value"), scalarValue: 12),
        ]

        let js = CanonicalScriptGraphCompiler().compile(RCP3ScriptGraph(nodes: [update, switchNode, case0, case1, fallback], wires: wires, data: data))

        #expect(js.contains("switch (6) {"))
        #expect(js.contains("case (5 + 0):"))
        #expect(js.contains("case (5 + 1):"))
        #expect(js.contains("default:"))
        #expect(!js.contains("unsupported"))
    }

    @Test func loopCompilesDirectionAwareForWithIndexOutput() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let loop = RCP3ScriptGraph.Node(id: "loop", type: "tm_loop")
        let setIndex = RCP3ScriptGraph.Node(id: "set", type: "tm_set_variable_node", variableName: "index")
        let done = RCP3ScriptGraph.Node(id: "done", type: "tm_set_variable_node", variableName: "done")
        let wires = [
            RCP3ScriptGraph.Wire(id: "e0", from: "u", to: "loop"),
            RCP3ScriptGraph.Wire(id: "step", from: "loop", to: "set", fromPin: TMHash.murmur64a("step"), toPin: TMHash.murmur64a("")),
            RCP3ScriptGraph.Wire(id: "end", from: "loop", to: "done", fromPin: TMHash.murmur64a("end"), toPin: TMHash.murmur64a("")),
            RCP3ScriptGraph.Wire(id: "idx", from: "loop", to: "set", fromPin: TMHash.murmur64a("index"), toPin: TMHash.murmur64a("value")),
        ]
        let data = [
            RCP3ScriptGraph.DataLiteral(id: "b", toNode: "loop", toPin: TMHash.murmur64a("begin"), scalarValue: 0),
            RCP3ScriptGraph.DataLiteral(id: "e", toNode: "loop", toPin: TMHash.murmur64a("end"), scalarValue: 3),
            RCP3ScriptGraph.DataLiteral(id: "s", toNode: "loop", toPin: TMHash.murmur64a("step"), scalarValue: 1),
            RCP3ScriptGraph.DataLiteral(id: "i", toNode: "loop", toPin: TMHash.murmur64a("inclusive"), scalarValue: 1),
            RCP3ScriptGraph.DataLiteral(id: "d", toNode: "done", toPin: TMHash.murmur64a("value"), scalarValue: 99),
        ]

        let js = CanonicalScriptGraphCompiler().compile(RCP3ScriptGraph(nodes: [update, loop, setIndex, done], wires: wires, data: data))

        #expect(js.contains("for (let __d3_index_loop = 0;"))
        #expect(js.contains("__d3_index_loop += (1)"))
        #expect(js.contains("this.variable_12698897294825761860 = __d3_index_loop;"))
        #expect(js.contains("this.variable_10296494685231209730 = 99;"))
        #expect(!js.contains("unsupported"))
    }

    @Test func delayCompilesTimeoutAndCancelIDOutput() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let delay = RCP3ScriptGraph.Node(id: "delay", type: "tm_delay")
        let setCancel = RCP3ScriptGraph.Node(id: "set", type: "tm_set_variable_node", variableName: "cancel")
        let wires = [
            RCP3ScriptGraph.Wire(id: "e0", from: "u", to: "delay"),
            RCP3ScriptGraph.Wire(id: "always", from: "delay", to: "set", fromPin: TMHash.murmur64a("always"), toPin: TMHash.murmur64a("")),
            RCP3ScriptGraph.Wire(id: "cancel", from: "delay", to: "set", fromPin: TMHash.murmur64a("cancelID"), toPin: TMHash.murmur64a("value")),
        ]
        let data = [
            RCP3ScriptGraph.DataLiteral(id: "seconds", toNode: "delay", toPin: TMHash.murmur64a("seconds"), scalarValue: 0.25),
            RCP3ScriptGraph.DataLiteral(id: "unique", toNode: "delay", toPin: TMHash.murmur64a("is unique"), scalarValue: 1),
        ]

        let js = CanonicalScriptGraphCompiler().compile(RCP3ScriptGraph(nodes: [update, delay, setCancel], wires: wires, data: data))

        #expect(js.contains("const __d3_delay_delay = (s, unique) => {"))
        #expect(js.contains("this.__d3_cancel_delay = this.setTimeout(() => {"))
        #expect(js.contains("}, s * 1000);"))
        #expect(js.contains("__d3_delay_delay(0.25, 1);"))
        #expect(js.contains("this.variable_16273870164193684844 = this.__d3_cancel_delay;"))
        #expect(!js.contains("unsupported"))
    }

    @Test func cancelDelayCompilesClearTimeout() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let cancel = RCP3ScriptGraph.Node(id: "cancel", type: "tm_cancel_delay")
        let exec = RCP3ScriptGraph.Wire(id: "e", from: "u", to: "cancel")
        let literal = RCP3ScriptGraph.DataLiteral(id: "id", toNode: "cancel", toPin: TMHash.murmur64a("cancelID"), scalarValue: 123)

        let js = CanonicalScriptGraphCompiler().compile(RCP3ScriptGraph(nodes: [update, cancel], wires: [exec], data: [literal]))

        #expect(js.contains("this.clearTimeout(123);"))
        #expect(!js.contains("unsupported"))
    }

    @Test func doOnceCompilesAlwaysThenGuardedOnce() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let once = RCP3ScriptGraph.Node(id: "once", type: "tm_do_once")
        let always = RCP3ScriptGraph.Node(id: "always", type: "tm_set_variable_node", variableName: "alwaysOnce")
        let gated = RCP3ScriptGraph.Node(id: "gated", type: "tm_set_variable_node", variableName: "gatedOnce")
        let wires = [
            RCP3ScriptGraph.Wire(id: "e0", from: "u", to: "once"),
            RCP3ScriptGraph.Wire(id: "always", from: "once", to: "always", fromPin: TMHash.murmur64a("always"), toPin: TMHash.murmur64a("")),
            RCP3ScriptGraph.Wire(id: "once", from: "once", to: "gated", fromPin: TMHash.murmur64a("once"), toPin: TMHash.murmur64a("")),
        ]
        let data = [
            RCP3ScriptGraph.DataLiteral(id: "a", toNode: "always", toPin: TMHash.murmur64a("value"), scalarValue: 1),
            RCP3ScriptGraph.DataLiteral(id: "g", toNode: "gated", toPin: TMHash.murmur64a("value"), scalarValue: 2),
        ]

        let js = CanonicalScriptGraphCompiler().compile(RCP3ScriptGraph(nodes: [update, once, always, gated], wires: wires, data: data))

        #expect(js.contains("this.variable_12640727383939188824 = 1;"))
        #expect(js.contains("if (!this.__d3_once_once) {"))
        #expect(js.contains("this.variable_6127020334959562039 = 2;"))
        #expect(js.contains("this.__d3_once_once = true;"))
        #expect(!js.contains("unsupported"))
    }

    @Test func entitySetRelativeTransformCompilesOptionalRelativeWrites() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let action = RCP3ScriptGraph.Node(id: "rel", type: "tm_entity_set_relative_transform")
        let selfNode = RCP3ScriptGraph.Node(id: "self", type: "tm_self")
        let position = RCP3ScriptGraph.Node(id: "pos", type: "tm_make_vector3")
        let rotation = RCP3ScriptGraph.Node(id: "rot", type: "tm_make_rotation")
        let wires = [
            RCP3ScriptGraph.Wire(id: "e", from: "u", to: "rel"),
            RCP3ScriptGraph.Wire(id: "entity", from: "self", to: "rel", fromPin: TMHash.murmur64a("entity"), toPin: TMHash.murmur64a("entity")),
            RCP3ScriptGraph.Wire(id: "relative", from: "self", to: "rel", fromPin: TMHash.murmur64a("entity"), toPin: TMHash.murmur64a("relativeTo")),
            RCP3ScriptGraph.Wire(id: "position", from: "pos", to: "rel", fromPin: TMHash.murmur64a("vec3"), toPin: TMHash.murmur64a("position")),
            RCP3ScriptGraph.Wire(id: "orientation", from: "rot", to: "rel", fromPin: TMHash.murmur64a("new"), toPin: TMHash.murmur64a("orientation")),
        ]
        let data = [
            RCP3ScriptGraph.DataLiteral(id: "x", toNode: "pos", toPin: TMHash.murmur64a("x"), scalarValue: 1),
            RCP3ScriptGraph.DataLiteral(id: "y", toNode: "pos", toPin: TMHash.murmur64a("y"), scalarValue: 2),
            RCP3ScriptGraph.DataLiteral(id: "z", toNode: "pos", toPin: TMHash.murmur64a("z"), scalarValue: 3),
            RCP3ScriptGraph.DataLiteral(id: "angle", toNode: "rot", toPin: TMHash.murmur64a("angle"), scalarValue: 0.5),
        ]

        let js = CanonicalScriptGraphCompiler().compile(RCP3ScriptGraph(nodes: [update, action, selfNode, position, rotation], wires: wires, data: data))

        #expect(js.contains("const Math3D = require(\"Math3D\")"))
        #expect(js.contains("if (new Math3D.Quaternion(0.5, new Math3D.Vector3(0, 1, 0)) != null) this.entity.setRelativeOrientation(new Math3D.Quaternion(0.5, new Math3D.Vector3(0, 1, 0)), this.entity);"))
        #expect(js.contains("if (new Math3D.Vector3(1, 2, 3) != null) this.entity.setRelativePosition(new Math3D.Vector3(1, 2, 3), this.entity);"))
        #expect(js.contains("if (null != null) this.entity.setRelativeScale(null, this.entity);"))
        #expect(!js.contains("unsupported"))
    }

    @Test func entityLookAtCompilesLookCall() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let look = RCP3ScriptGraph.Node(id: "look", type: "tm_entity_look_at")
        let selfNode = RCP3ScriptGraph.Node(id: "self", type: "tm_self")
        let at = RCP3ScriptGraph.Node(id: "at", type: "tm_make_vector3")
        let from = RCP3ScriptGraph.Node(id: "from", type: "tm_make_vector3")
        let up = RCP3ScriptGraph.Node(id: "up", type: "tm_make_vector3")
        let wires = [
            RCP3ScriptGraph.Wire(id: "e", from: "u", to: "look"),
            RCP3ScriptGraph.Wire(id: "entity", from: "self", to: "look", fromPin: TMHash.murmur64a("entity"), toPin: TMHash.murmur64a("entity")),
            RCP3ScriptGraph.Wire(id: "relative", from: "self", to: "look", fromPin: TMHash.murmur64a("entity"), toPin: TMHash.murmur64a("relativeTo")),
            RCP3ScriptGraph.Wire(id: "at", from: "at", to: "look", fromPin: TMHash.murmur64a("vec3"), toPin: TMHash.murmur64a("at")),
            RCP3ScriptGraph.Wire(id: "from", from: "from", to: "look", fromPin: TMHash.murmur64a("vec3"), toPin: TMHash.murmur64a("from")),
            RCP3ScriptGraph.Wire(id: "up", from: "up", to: "look", fromPin: TMHash.murmur64a("vec3"), toPin: TMHash.murmur64a("upVector")),
        ]
        let data = [
            RCP3ScriptGraph.DataLiteral(id: "atX", toNode: "at", toPin: TMHash.murmur64a("x"), scalarValue: 1),
            RCP3ScriptGraph.DataLiteral(id: "fromY", toNode: "from", toPin: TMHash.murmur64a("y"), scalarValue: 2),
            RCP3ScriptGraph.DataLiteral(id: "upY", toNode: "up", toPin: TMHash.murmur64a("y"), scalarValue: 1),
            RCP3ScriptGraph.DataLiteral(id: "forward", toNode: "look", toPin: TMHash.murmur64a("positiveZForward"), scalarValue: 1),
        ]

        let js = CanonicalScriptGraphCompiler().compile(RCP3ScriptGraph(nodes: [update, look, selfNode, at, from, up], wires: wires, data: data))

        #expect(js.contains("this.entity.look(new Math3D.Vector3(1, 0 /* y unwired */, 0 /* z unwired */), new Math3D.Vector3(0 /* x unwired */, 2, 0 /* z unwired */), new Math3D.Vector3(0 /* x unwired */, 1, 0 /* z unwired */), this.entity, 1);"))
        #expect(!js.contains("unsupported"))
    }

    @Test func selfAndSceneCompileToEntityExpressions() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let setSelf = RCP3ScriptGraph.Node(id: "setSelf", type: "tm_set_variable_node", variableName: "self")
        let setScene = RCP3ScriptGraph.Node(id: "setScene", type: "tm_set_variable_node", variableName: "scene")
        let selfNode = RCP3ScriptGraph.Node(id: "self", type: "tm_self")
        let sceneNode = RCP3ScriptGraph.Node(id: "scene", type: "tm_scene")
        let wires = [
            RCP3ScriptGraph.Wire(id: "e1", from: "u", to: "setSelf"),
            RCP3ScriptGraph.Wire(id: "e2", from: "setSelf", to: "setScene"),
            RCP3ScriptGraph.Wire(id: "selfValue", from: "self", to: "setSelf", fromPin: TMHash.murmur64a("entity"), toPin: TMHash.murmur64a("value")),
            RCP3ScriptGraph.Wire(id: "sceneValue", from: "scene", to: "setScene", fromPin: TMHash.murmur64a("scene"), toPin: TMHash.murmur64a("value")),
        ]

        let js = CanonicalScriptGraphCompiler().compile(RCP3ScriptGraph(nodes: [update, setSelf, setScene, selfNode, sceneNode], wires: wires, data: []))

        #expect(js.contains("= this.entity;"))
        #expect(js.contains("= this.entity.scene;"))
        #expect(!js.contains("unsupported"))
    }
}
