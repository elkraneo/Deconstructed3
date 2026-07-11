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

    @Test func collisionEventBeganCompilesToRuntimeEventHook() {
        let collision = RCP3ScriptGraph.Node(id: "c", type: "tm_collision_event_began")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component")
        let exec = RCP3ScriptGraph.Wire(id: "e", from: "c", to: "s")
        let position = RCP3ScriptGraph.Wire(
            id: "p",
            from: "c",
            to: "s",
            fromPin: TMHash.murmur64a("position"),
            toPin: TMHash.murmur64a("translation")
        )
        let graph = RCP3ScriptGraph(nodes: [collision, set], wires: [exec, position], data: [])

        let js = CanonicalScriptGraphCompiler().compile(graph)

        #expect(js.contains("this.collisionBegan = function(event)"))
        #expect(js.contains("this.entity.position = event.position;"))
        #expect(!js.contains("RealityKit.Collision"))
        #expect(!js.contains("unsupported"))
    }

    @Test func physicsEventDidSimulateExposesDeltaTimeAndRootEntity() {
        let event = RCP3ScriptGraph.Node(id: "p", type: "tm_physics_event_did_simulate")
        let set = RCP3ScriptGraph.Node(id: "v", type: "tm_set_variable_node", variableName: "dt")
        let exec = RCP3ScriptGraph.Wire(id: "e", from: "p", to: "v")
        let value = RCP3ScriptGraph.Wire(
            id: "d",
            from: "p",
            to: "v",
            fromPin: TMHash.murmur64a("deltaTime"),
            toPin: TMHash.murmur64a("value")
        )
        let graph = RCP3ScriptGraph(nodes: [event, set], wires: [exec, value], data: [])

        let js = CanonicalScriptGraphCompiler().compile(graph)

        #expect(js.contains("this.physicsDidSimulate = function(event)"))
        #expect(js.contains("this.variable_"))
        #expect(js.contains("= event.deltaTime;"))
        #expect(!js.contains("unsupported"))
    }

    @Test func boolAndStringPinLiteralsCompileToJSValues() {
        // On Update → Set Variable, with the value pin fed by a literal (no wire).
        let valuePin = TMHash.murmur64a("value")

        func setVariableGraph(value: TMGraphValue) -> RCP3ScriptGraph {
            let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
            let set = RCP3ScriptGraph.Node(id: "v", type: "tm_set_variable_node", variableName: "flag")
            let exec = RCP3ScriptGraph.Wire(id: "e", from: "u", to: "v")
            let literal = RCP3ScriptGraph.DataLiteral(id: "lit", toNode: "v", toPin: valuePin, value: value)
            return RCP3ScriptGraph(nodes: [update, set], wires: [exec], data: [literal])
        }

        let boolJS = CanonicalScriptGraphCompiler().compile(setVariableGraph(value: .bool(true)))
        #expect(boolJS.contains("= true;"))
        #expect(!boolJS.contains("undefined"))

        let stringJS = CanonicalScriptGraphCompiler().compile(setVariableGraph(value: .string("hi")))
        #expect(stringJS.contains("= \"hi\";"))
    }

    static func dynamicSettings(
        inputs: [String],
        outputs: [String] = []
    ) -> RCP3ScriptGraph.Node.DynamicConnectorSettings {
        func connector(_ name: String, order: Int) -> RCP3ScriptGraph.Node.DynamicConnector {
            .init(
                name: name,
                typeHash: 0x1111_1111_1111_1111,
                editHash: 0x2222_2222_2222_2222,
                order: Double(order),
                optionality: 0
            )
        }
        return .init(
            container: .direct,
            inputs: inputs.enumerated().map { connector($0.element, order: $0.offset) },
            outputs: outputs.enumerated().map { connector($0.element, order: $0.offset) }
        )
    }

    @Test func typedToStringAndStringMergeCompileFromAuthoredConnectorNames() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let set = RCP3ScriptGraph.Node(id: "set", type: "tm_set_variable_node", variableName: "text")
        let toString = RCP3ScriptGraph.Node(
            id: "convert",
            type: "tm_to_string",
            dynamicConnectorSettings: Self.dynamicSettings(inputs: ["number_value"])
        )
        let merge = RCP3ScriptGraph.Node(
            id: "merge",
            type: "tm_string_merge",
            dynamicConnectorSettings: Self.dynamicSettings(inputs: ["first_value", "second_value"])
        )
        let pi = RCP3ScriptGraph.Node(id: "pi", type: "tm_constant_pi")
        let makeString = RCP3ScriptGraph.Node(id: "s", type: "tm_make_string")
        let graph = RCP3ScriptGraph(
            nodes: [update, set, toString, merge, pi, makeString],
            wires: [
                .init(id: "exec", from: "u", to: "set"),
                .init(id: "pi-convert", from: "pi", to: "convert",
                      fromPin: TMHash.murmur64a("PI"), toPin: TMHash.murmur64a("number_value")),
                .init(id: "convert-merge", from: "convert", to: "merge",
                      fromPin: TMHash.murmur64a("value"), toPin: TMHash.murmur64a("first_value")),
                .init(id: "string-merge", from: "s", to: "merge",
                      fromPin: TMHash.murmur64a("value"), toPin: TMHash.murmur64a("second_value")),
                .init(id: "merge-set", from: "merge", to: "set",
                      fromPin: TMHash.murmur64a("result"), toPin: TMHash.murmur64a("value")),
            ],
            data: [
                .init(id: "string", toNode: "s", toPin: TMHash.murmur64a("initial_value"), value: .string("units")),
                .init(id: "separator", toNode: "merge", toPin: TMHash.murmur64a("separator"), value: .string(" / ")),
            ]
        )

        let js = CanonicalScriptGraphCompiler().compile(graph)
        #expect(js.contains("[String(Math.PI), \"units\"].flat().join(\" / \")"))
        #expect(!js.contains("unsupported: tm_to_string"))
        #expect(!js.contains("unsupported: tm_string_merge"))
    }

    @Test func typedArrayCountAndGetUseLengthAndSubscript() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let set = RCP3ScriptGraph.Node(id: "set", type: "tm_set_variable_node", variableName: "item")
        let children = RCP3ScriptGraph.Node(id: "children", type: "tm_get_children")
        let count = RCP3ScriptGraph.Node(
            id: "count", type: "tm_array_count",
            dynamicConnectorSettings: Self.dynamicSettings(inputs: ["entities"])
        )
        let get = RCP3ScriptGraph.Node(
            id: "get", type: "tm_array_get",
            dynamicConnectorSettings: Self.dynamicSettings(inputs: ["entities"])
        )
        let graph = RCP3ScriptGraph(
            nodes: [update, set, children, count, get],
            wires: [
                .init(id: "exec", from: "u", to: "set"),
                .init(id: "children-count", from: "children", to: "count",
                      fromPin: TMHash.murmur64a("children"), toPin: TMHash.murmur64a("entities")),
                .init(id: "children-get", from: "children", to: "get",
                      fromPin: TMHash.murmur64a("children"), toPin: TMHash.murmur64a("entities")),
                .init(id: "count-index", from: "count", to: "get",
                      fromPin: TMHash.murmur64a("count"), toPin: TMHash.murmur64a("index")),
                .init(id: "get-set", from: "get", to: "set",
                      fromPin: TMHash.murmur64a("element"), toPin: TMHash.murmur64a("value")),
            ], data: []
        )

        let js = CanonicalScriptGraphCompiler().compile(graph)
        #expect(js.contains("(this.entity.children)[(this.entity.children).length]"))
        #expect(!js.contains("unsupported: tm_array_count"))
        #expect(!js.contains("unsupported: tm_array_get"))
    }

    @Test func typedArraySetBoundsChecksMutatesAndExposesItsArrayOutput() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let setArray = RCP3ScriptGraph.Node(
            id: "replace", type: "tm_array_set",
            dynamicConnectorSettings: Self.dynamicSettings(inputs: ["entities"], outputs: ["entities"])
        )
        let setVariable = RCP3ScriptGraph.Node(id: "set", type: "tm_set_variable_node", variableName: "entities")
        let children = RCP3ScriptGraph.Node(id: "children", type: "tm_get_children")
        let graph = RCP3ScriptGraph(
            nodes: [update, setArray, setVariable, children],
            wires: [
                .init(id: "exec1", from: "u", to: "replace"),
                .init(id: "exec2", from: "replace", to: "set"),
                .init(id: "array", from: "children", to: "replace",
                      fromPin: TMHash.murmur64a("children"), toPin: TMHash.murmur64a("entities")),
                .init(id: "output", from: "replace", to: "set",
                      fromPin: TMHash.murmur64a("entities"), toPin: TMHash.murmur64a("value")),
            ],
            data: [
                .init(id: "index", toNode: "replace", toPin: TMHash.murmur64a("index"), value: .number(0)),
                .init(id: "element", toNode: "replace", toPin: TMHash.murmur64a("element"), value: .number(42)),
            ]
        )

        let js = CanonicalScriptGraphCompiler().compile(graph)
        #expect(js.contains("let __d3_tm_array_set_replace = this.entity.children;"))
        #expect(js.contains("if ((0) >= 0 && (0) < __d3_tm_array_set_replace.length)"))
        #expect(js.contains("__d3_tm_array_set_replace[0] = 42;"))
        #expect(js.contains("= __d3_tm_array_set_replace;"))
        #expect(!js.contains("unsupported node: tm_array_set"))
    }

    @Test func typedArrayCreateAddAndRemoveUseHarvestedArrayOperations() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let create = RCP3ScriptGraph.Node(
            id: "create", type: "tm_array_create",
            dynamicConnectorSettings: Self.dynamicSettings(inputs: ["value0", "value1"])
        )
        let add = RCP3ScriptGraph.Node(
            id: "add", type: "tm_array_add",
            dynamicConnectorSettings: Self.dynamicSettings(inputs: ["array"])
        )
        let remove = RCP3ScriptGraph.Node(
            id: "remove", type: "tm_array_remove",
            dynamicConnectorSettings: Self.dynamicSettings(inputs: ["array"])
        )
        let set = RCP3ScriptGraph.Node(id: "set", type: "tm_set_variable_node", variableName: "array")
        let graph = RCP3ScriptGraph(
            nodes: [update, create, add, remove, set],
            wires: [
                .init(id: "exec1", from: "u", to: "add"),
                .init(id: "exec2", from: "add", to: "remove"),
                .init(id: "exec3", from: "remove", to: "set"),
                .init(id: "create-add", from: "create", to: "add",
                      fromPin: TMHash.murmur64a("array"), toPin: TMHash.murmur64a("array")),
                .init(id: "add-remove", from: "add", to: "remove",
                      fromPin: TMHash.murmur64a("array"), toPin: TMHash.murmur64a("array")),
                .init(id: "remove-set", from: "remove", to: "set",
                      fromPin: TMHash.murmur64a("array"), toPin: TMHash.murmur64a("value")),
            ],
            data: [
                .init(id: "v0", toNode: "create", toPin: TMHash.murmur64a("value0"), value: .number(1)),
                .init(id: "v1", toNode: "create", toPin: TMHash.murmur64a("value1"), value: .number(2)),
                .init(id: "element", toNode: "add", toPin: TMHash.murmur64a("element"), value: .number(3)),
                .init(id: "index", toNode: "remove", toPin: TMHash.murmur64a("index"), value: .number(0)),
            ]
        )

        let js = CanonicalScriptGraphCompiler().compile(graph)
        #expect(js.contains("let __d3_tm_array_add_add = [1, 2];"))
        #expect(js.contains("__d3_tm_array_add_add.push(3);"))
        #expect(js.contains("let __d3_tm_array_remove_remove = __d3_tm_array_add_add;"))
        #expect(js.contains("__d3_tm_array_remove_remove.splice(0, 1);"))
        #expect(js.contains("= __d3_tm_array_remove_remove;"))
        #expect(!js.contains("unsupported node: tm_array_"))
    }

    @Test func typedArrayForEachEmitsStepScopeAndElementSubscript() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let children = RCP3ScriptGraph.Node(id: "children", type: "tm_get_children")
        let each = RCP3ScriptGraph.Node(
            id: "each", type: "tm_array_for_each",
            dynamicConnectorSettings: Self.dynamicSettings(inputs: ["entities"])
        )
        let set = RCP3ScriptGraph.Node(id: "set", type: "tm_set_variable_node", variableName: "entity")
        let graph = RCP3ScriptGraph(nodes: [update, children, each, set], wires: [
            .init(id: "start", from: "u", to: "each"),
            .init(id: "step", from: "each", to: "set",
                  fromPin: TMHash.murmur64a("step"), toPin: TMHash.murmur64a("")),
            .init(id: "array", from: "children", to: "each",
                  fromPin: TMHash.murmur64a("children"), toPin: TMHash.murmur64a("entities")),
            .init(id: "element", from: "each", to: "set",
                  fromPin: TMHash.murmur64a("element"), toPin: TMHash.murmur64a("value")),
        ], data: [])

        let js = CanonicalScriptGraphCompiler().compile(graph)
        #expect(js.contains("for (let __d3_array_index_each = 0;"))
        #expect(js.contains("(this.entity.children)[__d3_array_index_each]"))
        #expect(!js.contains("unsupported node: tm_array_for_each"))
    }

    @Test func typedArrayFindEmitsEqualitySearchAndFoundNotFoundScopes() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let children = RCP3ScriptGraph.Node(id: "children", type: "tm_get_children")
        let find = RCP3ScriptGraph.Node(
            id: "find", type: "tm_array_find",
            dynamicConnectorSettings: Self.dynamicSettings(inputs: ["entities"])
        )
        let found = RCP3ScriptGraph.Node(id: "found-set", type: "tm_set_variable_node", variableName: "found")
        let missing = RCP3ScriptGraph.Node(id: "missing-set", type: "tm_set_variable_node", variableName: "missing")
        let graph = RCP3ScriptGraph(nodes: [update, children, find, found, missing], wires: [
            .init(id: "start", from: "u", to: "find"),
            .init(id: "found", from: "find", to: "found-set",
                  fromPin: TMHash.murmur64a("found"), toPin: TMHash.murmur64a("")),
            .init(id: "missing", from: "find", to: "missing-set",
                  fromPin: TMHash.murmur64a("not found"), toPin: TMHash.murmur64a("")),
            .init(id: "array", from: "children", to: "find",
                  fromPin: TMHash.murmur64a("children"), toPin: TMHash.murmur64a("entities")),
            .init(id: "found-element", from: "find", to: "found-set",
                  fromPin: TMHash.murmur64a("element"), toPin: TMHash.murmur64a("value")),
            .init(id: "missing-index", from: "find", to: "missing-set",
                  fromPin: TMHash.murmur64a("index"), toPin: TMHash.murmur64a("value")),
        ], data: [
            .init(id: "search", toNode: "find", toPin: TMHash.murmur64a("searchValue"), value: .string("target")),
        ])

        let js = CanonicalScriptGraphCompiler().compile(graph)
        #expect(js.contains("let __d3_array_find_index_find = -1;"))
        #expect(js.contains("typeof __d3_array_candidate_find.equals === \"function\""))
        #expect(js.contains("__d3_array_candidate_find.equals(\"target\")"))
        #expect(js.contains("__d3_array_find_element_find = __d3_array_candidate_find;"))
        #expect(js.contains("= __d3_array_find_element_find;"))
        #expect(js.contains("= __d3_array_find_index_find;"))
        #expect(!js.contains("unsupported node: tm_array_find"))
    }

    @Test func playbackEventsExposePlaybackController() {
        for (type, hook) in [
            ("tm_animation_event_playback_started", "animationPlaybackStarted"),
            ("tm_animation_event_playback_completed", "animationPlaybackCompleted"),
            ("tm_animation_event_playback_looped", "animationPlaybackLooped"),
            ("tm_animation_event_playback_terminated", "animationPlaybackTerminated"),
            ("tm_audio_event_playback_completed", "audioPlaybackCompleted"),
        ] {
            let event = RCP3ScriptGraph.Node(id: "event", type: type)
            let set = RCP3ScriptGraph.Node(id: "set", type: "tm_set_variable_node", variableName: "controller")
            let graph = RCP3ScriptGraph(
                nodes: [event, set],
                wires: [
                    RCP3ScriptGraph.Wire(id: "e", from: "event", to: "set"),
                    RCP3ScriptGraph.Wire(
                        id: "d",
                        from: "event",
                        to: "set",
                        fromPin: TMHash.murmur64a("playbackController"),
                        toPin: TMHash.murmur64a("value")
                    ),
                ],
                data: []
            )

            let js = CanonicalScriptGraphCompiler().compile(graph)

            #expect(js.contains("this.\(hook) = function(event)"))
            #expect(js.contains("= event.playbackController;"))
            #expect(!js.contains("unsupported"))
        }
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

    @Test func vectorSubtractAndMultiplyStayBareOperatorsWithoutFallbackNote() {
        for (type, op) in [("tm_math_subtract", "-"), ("tm_math_multiply", "*")] {
            let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
            let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component")
            let math = RCP3ScriptGraph.Node(id: "m", type: type)
            let v1 = RCP3ScriptGraph.Node(id: "v1", type: "tm_make_vector3")
            let v2 = RCP3ScriptGraph.Node(id: "v2", type: "tm_make_vector3")
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
                    id: "out", from: "m", to: "s",
                    fromPin: TMHash.murmur64a("result"), toPin: TMHash.murmur64a("translation")
                ),
            ]

            let js = CanonicalScriptGraphCompiler().compile(RCP3ScriptGraph(nodes: [update, set, math, v1, v2], wires: wires, data: []))

            #expect(js.contains("this.entity.position = (new Math3D.Vector3("))
            #expect(js.contains(") \(op) new Math3D.Vector3("))
            #expect(!js.contains("TODO: vector op"))
            #expect(!js.contains("unsupported"))
        }
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

    @Test func makeLookAtRotationCompilesToThreeArgumentQuaternionConstructor() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let at = RCP3ScriptGraph.Node(id: "at", type: "tm_make_vector3")
        let from = RCP3ScriptGraph.Node(id: "from", type: "tm_make_vector3")
        let up = RCP3ScriptGraph.Node(id: "up", type: "tm_make_vector3")
        let rotation = RCP3ScriptGraph.Node(id: "r", type: "tm_make_look_at_rotation")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component")
        let graph = RCP3ScriptGraph(
            nodes: [update, at, from, up, rotation, set],
            wires: [
                RCP3ScriptGraph.Wire(id: "exec", from: "u", to: "s"),
                RCP3ScriptGraph.Wire(
                    id: "atWire", from: "at", to: "r",
                    fromPin: TMHash.murmur64a("vec3"), toPin: TMHash.murmur64a("at")
                ),
                RCP3ScriptGraph.Wire(
                    id: "fromWire", from: "from", to: "r",
                    fromPin: TMHash.murmur64a("vec3"), toPin: TMHash.murmur64a("from")
                ),
                RCP3ScriptGraph.Wire(
                    id: "upWire", from: "up", to: "r",
                    fromPin: TMHash.murmur64a("vec3"), toPin: TMHash.murmur64a("upVector")
                ),
                RCP3ScriptGraph.Wire(
                    id: "rotationWire", from: "r", to: "s",
                    fromPin: TMHash.murmur64a("new"), toPin: TMHash.murmur64a("rotation")
                ),
            ],
            data: [
                RCP3ScriptGraph.DataLiteral(id: "atX", toNode: "at", toPin: TMHash.murmur64a("x"), scalarValue: 1),
                RCP3ScriptGraph.DataLiteral(id: "fromY", toNode: "from", toPin: TMHash.murmur64a("y"), scalarValue: 2),
                RCP3ScriptGraph.DataLiteral(id: "upY", toNode: "up", toPin: TMHash.murmur64a("y"), scalarValue: 1),
            ]
        )

        let js = CanonicalScriptGraphCompiler().compile(graph)

        #expect(js.contains("const Math3D = require(\"Math3D\")"))
        #expect(js.contains(
            "new Math3D.Quaternion(new Math3D.Vector3(1, 0 /* y unwired */, 0 /* z unwired */), "
                + "new Math3D.Vector3(0 /* x unwired */, 2, 0 /* z unwired */), "
                + "new Math3D.Vector3(0 /* x unwired */, 1, 0 /* z unwired */))"
        ))
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

    @Test func variableMathOperationsUseOneMutationTemplateAndForwardResult() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let add = RCP3ScriptGraph.Node(
            id: "add", type: "tm_variable_add", variableName: "score"
        )
        let rotate = RCP3ScriptGraph.Node(
            id: "rotate", type: "tm_variable_multiply_by_quaternion",
            variableName: "direction"
        )
        let set = RCP3ScriptGraph.Node(
            id: "set", type: "tm_set_variable_node", variableName: "result"
        )
        let wires = [
            RCP3ScriptGraph.Wire(id: "exec1", from: "u", to: "add"),
            RCP3ScriptGraph.Wire(id: "exec2", from: "add", to: "rotate"),
            RCP3ScriptGraph.Wire(id: "exec3", from: "rotate", to: "set"),
            RCP3ScriptGraph.Wire(
                id: "result", from: "add", to: "set",
                fromPin: TMHash.murmur64a("result"), toPin: TMHash.murmur64a("value")
            ),
        ]
        let data = [
            RCP3ScriptGraph.DataLiteral(
                id: "value", toNode: "add", toPin: TMHash.murmur64a("value"),
                scalarValue: 2
            ),
            RCP3ScriptGraph.DataLiteral(
                id: "quaternion", toNode: "rotate",
                toPin: TMHash.murmur64a("quaternion"), scalarValue: 3
            ),
        ]

        let js = CanonicalScriptGraphCompiler().compile(
            RCP3ScriptGraph(nodes: [update, add, rotate, set], wires: wires, data: data)
        )
        let score = "variable_\(TMHash.murmur64a("score"))"
        let direction = "variable_\(TMHash.murmur64a("direction"))"
        let result = "variable_\(TMHash.murmur64a("result"))"
        #expect(js.contains("this.\(score) = (this.\(score) ?? 0) + 2;"))
        #expect(js.contains("this.\(direction) = Math3D.multiply((this.\(direction) ?? 0), 3);"))
        #expect(js.contains("this.\(result) = (this.\(score) ?? 0);"))
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

    @Test func inverseUsesTheSourceNamedMath3DOperation() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let inverse = RCP3ScriptGraph.Node(id: "inverse", type: "tm_math_inverse")
        let set = RCP3ScriptGraph.Node(id: "set", type: "tm_set_variable_node", variableName: "result")
        let graph = RCP3ScriptGraph(
            nodes: [update, inverse, set],
            wires: [
                .init(id: "exec", from: "u", to: "set"),
                .init(id: "value", from: "inverse", to: "set",
                      fromPin: TMHash.murmur64a("result"), toPin: TMHash.murmur64a("value")),
            ],
            data: [.init(id: "input", toNode: "inverse", toPin: TMHash.murmur64a("value"), scalarValue: 4)]
        )
        let js = CanonicalScriptGraphCompiler().compile(graph)
        #expect(js.contains("Math3D.inverse(4)"))
        #expect(!js.contains("unsupported"))
    }

    @Test func textConstructorsUseTheHarvestedFoundationPipelines() {
        func compile(
            type: String, output: String, values: [(String, TMGraphValue)]
        ) -> String {
            let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
            let make = RCP3ScriptGraph.Node(id: "make", type: type)
            let set = RCP3ScriptGraph.Node(id: "set", type: "tm_set_variable_node", variableName: "result")
            return CanonicalScriptGraphCompiler().compile(RCP3ScriptGraph(
                nodes: [update, make, set],
                wires: [
                    .init(id: "exec", from: "u", to: "set"),
                    .init(id: "value", from: "make", to: "set",
                          fromPin: TMHash.murmur64a(output), toPin: TMHash.murmur64a("value")),
                ],
                data: values.enumerated().map { index, item in
                    .init(id: "d\(index)", toNode: "make", toPin: TMHash.murmur64a(item.0), value: item.1)
                }
            ))
        }

        let font = compile(type: "tm_make_font", output: "font", values: [
            ("name", .string("A")), ("size", .number(20)), ("weight", .number(2)),
            ("italic", .bool(true)), ("monospaced", .bool(true)),
            ("monospacedDigit", .bool(true)),
        ])
        #expect(font.contains("new Foundation.Font(\"A\", 20).boldFont(2)"))
        #expect(font.contains("italicFont()"))
        #expect(font.contains("monospacedFont()"))
        #expect(font.contains("monospacedDigitFont()"))

        let attributed = compile(type: "tm_make_attributed_string", output: "string", values: [
            ("Text", .string("Hello")), ("font", .number(1)),
            ("alignment", .number(2)), ("foregroundColor", .number(3)),
            ("backgroundColor", .number(4)),
        ])
        #expect(attributed.contains("new Foundation.AttributedString(\"Hello\")"))
        #expect(attributed.contains("value.font = 1;"))
        #expect(attributed.contains("value.alignment = 2;"))
        #expect(attributed.contains("value.foregroundColor = 3;"))
        #expect(attributed.contains("value.backgroundColor = 4;"))
    }

    @Test func customEventsUseDynamicPayloadConnectorsForSendAndReceive() {
        let payload = RCP3ScriptGraph.Node.DynamicConnector(name: "score", typeHash: 1, order: 0)
        let listener = RCP3ScriptGraph.Node(
            id: "listener", type: "tm_custom_event",
            dynamicConnectorSettings: .init(container: .direct, inputs: [], outputs: [payload])
        )
        let set = RCP3ScriptGraph.Node(id: "set", type: "tm_set_variable_node", variableName: "score")
        let listenerJS = CanonicalScriptGraphCompiler().compile(RCP3ScriptGraph(
            nodes: [listener, set],
            wires: [
                .init(id: "exec", from: "listener", to: "set"),
                .init(id: "score", from: "listener", to: "set",
                      fromPin: TMHash.murmur64a("score"), toPin: TMHash.murmur64a("value")),
            ],
            data: [.init(id: "name", toNode: "listener", toPin: TMHash.murmur64a("eventName"), value: .string("changed"))]
        ))
        #expect(listenerJS.contains("this.on(\"changed\", (event) => {"))
        #expect(listenerJS.contains("event.eventData[\"score\"]"))

        let update = RCP3ScriptGraph.Node(id: "update", type: "tm_update")
        let send = RCP3ScriptGraph.Node(
            id: "send", type: "tm_send_scene_event",
            dynamicConnectorSettings: .init(container: .direct, inputs: [payload], outputs: [])
        )
        let sendJS = CanonicalScriptGraphCompiler().compile(RCP3ScriptGraph(
            nodes: [update, send],
            wires: [.init(id: "exec", from: "update", to: "send")],
            data: [
                .init(id: "name", toNode: "send", toPin: TMHash.murmur64a("eventName"), value: .string("changed")),
                .init(id: "score", toNode: "send", toPin: TMHash.murmur64a("score"), value: .number(7)),
            ]
        ))
        #expect(sendJS.contains("this.send(\"changed\", { \"score\": 7 });"))
    }

    @Test func trackingInputsUseTheExactInputRuntimeMembers() {
        func compile(_ type: String, output: String, values: [(String, Double)] = []) -> String {
            let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
            let input = RCP3ScriptGraph.Node(id: "input", type: type)
            let set = RCP3ScriptGraph.Node(id: "set", type: "tm_set_variable_node", variableName: "result")
            return CanonicalScriptGraphCompiler().compile(RCP3ScriptGraph(
                nodes: [update, input, set],
                wires: [
                    .init(id: "exec", from: "u", to: "set"),
                    .init(id: "value", from: "input", to: "set",
                          fromPin: TMHash.murmur64a(output), toPin: TMHash.murmur64a("value")),
                ],
                data: values.enumerated().map { index, item in
                    .init(id: "d\(index)", toNode: "input", toPin: TMHash.murmur64a(item.0), scalarValue: item.1)
                }
            ))
        }
        #expect(compile("tm_is_head_tracking_available", output: "status").contains(
            "this.input.worldTrackingDataAvailable"
        ))
        #expect(compile("tm_is_hand_tracking_available", output: "status").contains(
            "this.input.handTrackingDataAvailable"
        ))
        #expect(compile("tm_head_tracking", output: "orientation").contains(
            "this.input.getDeviceTransform().orientation"
        ))
        #expect(compile("tm_hand_joint", output: "position", values: [("hand", 1), ("joint", 2)]).contains(
            "this.input.getJointTransform(1, 2).position"
        ))
        #expect(compile("tm_input_get_keyboard", output: "keyboard").contains("this.input.keyboard"))
        #expect(compile("tm_input_get_mouse", output: "mouse").contains("this.input.mouse"))
        #expect(compile("tm_input_get_gamepad", output: "gamepad", values: [("player", 2)]).contains("this.input.players[2]"))
        #expect(compile("tm_input_gamepad_axes", output: "rightTriggerPressure", values: [("gamepad", 1)]).contains("1.rightTriggerPressure"))
        #expect(compile("tm_input_mouse_button", output: "pressCount", values: [("mouse", 1), ("button", 2)]).contains("2 == 2 ? 1.rightButton"))
        #expect(compile("tm_input_gamepad_button", output: "pressed", values: [("gamepad", 1), ("button", 2)]).contains("1[2]?.pressed ?? false"))
        #expect(compile("tm_input_keyboard_key", output: "pressed", values: [("keyboard", 1), ("key", 2)]).contains("1.key(2).pressed"))
        #expect(compile("tm_input_mouse_motion", output: "delta", values: [("mouse", 1)]).contains("1.delta"))
        #expect(compile("tm_get_material", output: "material", values: [("index", 2)]).contains(
            "this.entity.getComponent(\"RealityKit.ModelComponent\").materials[2]"
        ))
    }

    @Test func animationControllerActionsUseTheHarvestedMethods() {
        func compile(_ type: String, values: [(String, TMGraphValue)]) -> String {
            let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
            let action = RCP3ScriptGraph.Node(id: "action", type: type)
            return CanonicalScriptGraphCompiler().compile(RCP3ScriptGraph(
                nodes: [update, action],
                wires: [.init(id: "exec", from: "u", to: "action")],
                data: values.enumerated().map { index, item in
                    .init(id: "d\(index)", toNode: "action", toPin: TMHash.murmur64a(item.0), value: item.1)
                }
            ))
        }
        #expect(compile("tm_stop_all_animations", values: [("recursive", .bool(true))]).contains(
            "this.entity.stopAllAnimations(true);"
        ))
        #expect(compile("tm_stop_animation", values: [
            ("playbackController", .number(1)), ("blendOutDuration", .number(2)),
        ]).contains("1.stop(2);"))
        #expect(compile("tm_pause_animation", values: [
            ("playbackController", .number(1)), ("pause", .bool(false)),
        ]).contains("if (false) { 1.pause(); } else { 1.resume(); }"))
        let byName = compile("tm_play_animation_by_name", values: [
            ("name", .string("Walk")), ("repeat", .bool(true)),
            ("transitionDuration", .number(2)), ("startsPaused", .bool(false)),
        ])
        #expect(byName.contains("availableAnimations.find(animation => animation.name == \"Walk\")"))
        #expect(byName.contains("playAnimation(true ? __d3_animation_action.repeat() : __d3_animation_action, 2, false)"))
        let byIndex = compile("tm_play_animation_by_index", values: [
            ("index", .number(3)), ("repeat", .bool(false)),
            ("transitionDuration", .number(1)), ("startsPaused", .bool(true)),
        ])
        #expect(byIndex.contains("availableAnimations[3]"))
        #expect(byIndex.contains("playAnimation(false ? __d3_animation_action.repeat() : __d3_animation_action, 1, true)"))
    }

    @Test func sceneCastsUseNearestAndRouteHitMissScopes() {
        func compile(_ type: String, values: [(String, Double)]) -> String {
            let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
            let cast = RCP3ScriptGraph.Node(id: "cast", type: type)
            let hit = RCP3ScriptGraph.Node(id: "hitSet", type: "tm_set_variable_node", variableName: "hit")
            let miss = RCP3ScriptGraph.Node(id: "missSet", type: "tm_set_variable_node", variableName: "miss")
            return CanonicalScriptGraphCompiler().compile(RCP3ScriptGraph(
                nodes: [update, cast, hit, miss],
                wires: [
                    .init(id: "start", from: "u", to: "cast"),
                    .init(id: "hit", from: "cast", to: "hit", fromPin: TMHash.murmur64a("hit"), toPin: nil),
                    .init(id: "miss", from: "cast", to: "miss", fromPin: TMHash.murmur64a("miss"), toPin: nil),
                ],
                data: values.enumerated().map { index, item in
                    .init(id: "d\(index)", toNode: "cast", toPin: TMHash.murmur64a(item.0), scalarValue: item.1)
                }
            ))
        }
        let ray = compile("tm_scene_raycast_v2", values: [
            ("from", 1), ("direction", 2), ("length", 3), ("mask", 4), ("relativeTo", 5),
        ])
        #expect(ray.contains("this.entity.scene.raycast(1, 2, 3, RealityKit.CollisionCastQueryType.nearest, 4, 5)"))
        #expect(ray.contains("if (__d3_cast_hits_cast.length > 0)"))

        let convex = compile("tm_scene_convex_cast", values: [
            ("shape", 1), ("from", 2), ("to", 3), ("mask", 4), ("relativeTo", 5),
        ])
        #expect(convex.contains("this.entity.scene.convexCast({ shape: 1, fromPosition: 2, toPosition: 3, mask: 4, query: RealityKit.CollisionCastQueryType.nearest, entity: 5 })"))
    }


    /// `On Update → Set Transform.translation = interp(a, b, factor)` with `a`/`b` from
    /// vectors and the factor from a scalar constant, returning the compiled JS.
    static func interpolationJS(type: String, factorPin: String) -> String {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component")
        let op = RCP3ScriptGraph.Node(id: "m", type: type)
        let va = RCP3ScriptGraph.Node(id: "va", type: "tm_make_vector3")
        let vb = RCP3ScriptGraph.Node(id: "vb", type: "tm_make_vector3")
        let t = RCP3ScriptGraph.Node(id: "t", type: "tm_constant")
        let wires = [
            RCP3ScriptGraph.Wire(id: "e1", from: "u", to: "s"),
            RCP3ScriptGraph.Wire(id: "wa", from: "va", to: "m", fromPin: TMHash.murmur64a("vec3"), toPin: TMHash.murmur64a("a")),
            RCP3ScriptGraph.Wire(id: "wb", from: "vb", to: "m", fromPin: TMHash.murmur64a("vec3"), toPin: TMHash.murmur64a("b")),
            RCP3ScriptGraph.Wire(id: "wt", from: "t", to: "m", fromPin: TMHash.murmur64a("value"), toPin: TMHash.murmur64a(factorPin)),
            RCP3ScriptGraph.Wire(id: "out", from: "m", to: "s", fromPin: TMHash.murmur64a("result"), toPin: TMHash.murmur64a("translation")),
        ]
        return CanonicalScriptGraphCompiler().compile(
            RCP3ScriptGraph(nodes: [update, set, op, va, vb, t], wires: wires, data: [])
        )
    }

    @Test func interpolationOpsEmitFaithfulMath3DCalls() {
        // lerp/slerp read the factor pin `t`; smoothstep reads `x`. All emit
        // `Math3D.<fn>(a, b, factor)` (the observed emission) with the Math3D module.
        for (type, fn, factorPin) in [
            ("tm_math_lerp", "lerp", "t"),
            ("tm_math_slerp", "slerp", "t"),
            ("tm_math_smoothstep", "smoothstep", "x"),
        ] {
            let js = Self.interpolationJS(type: type, factorPin: factorPin)
            #expect(js.contains("const Math3D = require(\"Math3D\")"))
            // a and b are the two vector operands; the factor is the third argument.
            #expect(js.contains("Math3D.\(fn)(new Math3D.Vector3("), "\(type) call shape")
            #expect(!js.contains("unsupported"), "\(type) must not lower to unsupported")
        }
        // smoothstep's factor pin is `x`, so a value wired to `t` must NOT satisfy it —
        // guards against the earlier wrong `t`-for-all-three assumption.
        let wrong = Self.interpolationJS(type: "tm_math_smoothstep", factorPin: "t")
        #expect(wrong.contains("/* x unwired */") || wrong.contains("0 /* x"))
    }

    /// `On Update → Set Transform.translation.<axis> = break(source).<axis>` — wires a
    /// Make Vector3 into a Break Vector3 and pulls one component output into a scalar sink,
    /// returning the compiled JS. Uses `tm_math_add` (scalar) as the sink so the break
    /// output must appear as a member access.
    static func breakJS(type: String, outputPin: String) -> String {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let set = RCP3ScriptGraph.Node(id: "s", type: "tm_set_component")
        let src = RCP3ScriptGraph.Node(id: "src", type: "tm_make_vector3")
        let brk = RCP3ScriptGraph.Node(id: "b", type: type)
        let wires = [
            RCP3ScriptGraph.Wire(id: "e1", from: "u", to: "s"),
            RCP3ScriptGraph.Wire(id: "wsrc", from: "src", to: "b", fromPin: TMHash.murmur64a("vec3"), toPin: TMHash.murmur64a("source")),
            RCP3ScriptGraph.Wire(id: "out", from: "b", to: "s", fromPin: TMHash.murmur64a(outputPin), toPin: TMHash.murmur64a("translation")),
        ]
        return CanonicalScriptGraphCompiler().compile(
            RCP3ScriptGraph(nodes: [update, set, src, brk], wires: wires, data: [])
        )
    }

    @Test func breakNodesEmitMemberAccessOnSource() {
        // Each break output is a member access on the destructured source value.
        #expect(Self.breakJS(type: "tm_break_vector3", outputPin: "y").contains(").y"))
        #expect(Self.breakJS(type: "tm_break_vector4", outputPin: "w").contains(").w"))
        #expect(Self.breakJS(type: "tm_break_color", outputPin: "green").contains(").green"))
        #expect(Self.breakJS(type: "tm_break_cgsize", outputPin: "width").contains(").width"))
        // No unsupported path on a fully-wired break.
        #expect(!Self.breakJS(type: "tm_break_vector3", outputPin: "x").contains("unsupported"))
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

    @Test func colorAndCGSizeUseTheirRuntimeConstructors() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let setColor = RCP3ScriptGraph.Node(
            id: "setColor", type: "tm_set_variable_node", variableName: "color"
        )
        let setSize = RCP3ScriptGraph.Node(
            id: "setSize", type: "tm_set_variable_node", variableName: "size"
        )
        let color = RCP3ScriptGraph.Node(id: "color", type: "tm_make_color")
        let size = RCP3ScriptGraph.Node(id: "size", type: "tm_make_cgsize")
        let wires = [
            RCP3ScriptGraph.Wire(id: "e1", from: "u", to: "setColor"),
            RCP3ScriptGraph.Wire(id: "e2", from: "setColor", to: "setSize"),
            RCP3ScriptGraph.Wire(
                id: "colorOut", from: "color", to: "setColor",
                fromPin: TMHash.murmur64a("color"), toPin: TMHash.murmur64a("value")
            ),
            RCP3ScriptGraph.Wire(
                id: "sizeOut", from: "size", to: "setSize",
                fromPin: TMHash.murmur64a("size"), toPin: TMHash.murmur64a("value")
            ),
        ]
        let data = [
            RCP3ScriptGraph.DataLiteral(
                id: "red", toNode: "color", toPin: TMHash.murmur64a("red"), scalarValue: 1
            ),
            RCP3ScriptGraph.DataLiteral(
                id: "green", toNode: "color", toPin: TMHash.murmur64a("green"), scalarValue: 0.5
            ),
            RCP3ScriptGraph.DataLiteral(
                id: "blue", toNode: "color", toPin: TMHash.murmur64a("blue"), scalarValue: 0.25
            ),
            RCP3ScriptGraph.DataLiteral(
                id: "alpha", toNode: "color", toPin: TMHash.murmur64a("alpha"), scalarValue: 1
            ),
            RCP3ScriptGraph.DataLiteral(
                id: "width", toNode: "size", toPin: TMHash.murmur64a("width"), scalarValue: 320
            ),
            RCP3ScriptGraph.DataLiteral(
                id: "height", toNode: "size", toPin: TMHash.murmur64a("height"), scalarValue: 180
            ),
        ]

        let js = CanonicalScriptGraphCompiler().compile(
            RCP3ScriptGraph(
                nodes: [update, setColor, setSize, color, size],
                wires: wires,
                data: data
            )
        )

        #expect(js.contains("const Foundation = require(\"Foundation\");"))
        #expect(js.contains("const CoreGraphics = require(\"CoreGraphics\");"))
        #expect(js.contains("new Foundation.Color(1, 0.5, 0.25, 1)"))
        #expect(js.contains("new CoreGraphics.CGSize(320, 180)"))
        #expect(!js.contains("unsupported"))
    }

    @Test func cgColorToColorUsesTheShippedFoundationConversion() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let set = RCP3ScriptGraph.Node(id: "set", type: "tm_set_variable_node", variableName: "color")
        let cgColor = RCP3ScriptGraph.Node(id: "cg", type: "tm_make_cgcolor")
        let convert = RCP3ScriptGraph.Node(id: "convert", type: "tm_cgcolor_to_color")
        let wires = [
            RCP3ScriptGraph.Wire(id: "exec", from: "u", to: "set"),
            RCP3ScriptGraph.Wire(id: "toConvert", from: "cg", to: "convert", fromPin: TMHash.murmur64a("source"), toPin: TMHash.murmur64a("source")),
            RCP3ScriptGraph.Wire(id: "toSet", from: "convert", to: "set", fromPin: TMHash.murmur64a("color"), toPin: TMHash.murmur64a("value")),
        ]
        let data = [
            RCP3ScriptGraph.DataLiteral(id: "red", toNode: "cg", toPin: TMHash.murmur64a("red"), scalarValue: 1),
            RCP3ScriptGraph.DataLiteral(id: "green", toNode: "cg", toPin: TMHash.murmur64a("green"), scalarValue: 0.5),
            RCP3ScriptGraph.DataLiteral(id: "blue", toNode: "cg", toPin: TMHash.murmur64a("blue"), scalarValue: 0.25),
            RCP3ScriptGraph.DataLiteral(id: "alpha", toNode: "cg", toPin: TMHash.murmur64a("alpha"), scalarValue: 1),
        ]

        let js = CanonicalScriptGraphCompiler().compile(
            RCP3ScriptGraph(nodes: [update, set, cgColor, convert], wires: wires, data: data)
        )

        #expect(js.contains("new CoreGraphics.CGColor(1, 0.5, 0.25, 1)"))
        #expect(js.contains("new Foundation.Color(new CoreGraphics.CGColor(1, 0.5, 0.25, 1))"))
        #expect(!js.contains("unsupported"))
    }

    @Test func colorToCGColorUsesTheShippedMemberConversion() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let set = RCP3ScriptGraph.Node(id: "set", type: "tm_set_variable_node", variableName: "cgColor")
        let color = RCP3ScriptGraph.Node(id: "color", type: "tm_make_color")
        let convert = RCP3ScriptGraph.Node(id: "convert", type: "tm_color_to_cgcolor")
        let wires = [
            RCP3ScriptGraph.Wire(id: "exec", from: "u", to: "set"),
            RCP3ScriptGraph.Wire(id: "toConvert", from: "color", to: "convert", fromPin: TMHash.murmur64a("color"), toPin: TMHash.murmur64a("source")),
            RCP3ScriptGraph.Wire(id: "toSet", from: "convert", to: "set", fromPin: TMHash.murmur64a("cgColor"), toPin: TMHash.murmur64a("value")),
        ]
        let data = [
            RCP3ScriptGraph.DataLiteral(id: "red", toNode: "color", toPin: TMHash.murmur64a("red"), scalarValue: 1),
            RCP3ScriptGraph.DataLiteral(id: "green", toNode: "color", toPin: TMHash.murmur64a("green"), scalarValue: 0.5),
            RCP3ScriptGraph.DataLiteral(id: "blue", toNode: "color", toPin: TMHash.murmur64a("blue"), scalarValue: 0.25),
            RCP3ScriptGraph.DataLiteral(id: "alpha", toNode: "color", toPin: TMHash.murmur64a("alpha"), scalarValue: 1),
        ]

        let js = CanonicalScriptGraphCompiler().compile(
            RCP3ScriptGraph(nodes: [update, set, color, convert], wires: wires, data: data)
        )

        #expect(js.contains("new Foundation.Color(1, 0.5, 0.25, 1).cgColor"))
        #expect(!js.contains("unsupported"))
    }

    @Test func remainingMakeNodesUseTheirRuntimeConstructors() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let constructors: [(id: String, type: String, output: String, inputs: [String])] = [
            ("cgcolor", "tm_make_cgcolor", "source", ["red", "green", "blue", "alpha"]),
            ("insets", "tm_make_edge_insets", "insets", ["top", "left", "bottom", "right"]),
            ("matrix2", "tm_make_matrix2x2", "source", ["col0", "col1"]),
            ("matrix3", "tm_make_matrix3x3", "source", ["col0", "col1", "col2"]),
            ("matrix4", "tm_make_matrix4x4", "source", ["col0", "col1", "col2", "col3"]),
        ]
        let makeNodes = constructors.map {
            RCP3ScriptGraph.Node(id: $0.id, type: $0.type)
        }
        let setters = constructors.enumerated().map {
            RCP3ScriptGraph.Node(
                id: "set\($0.offset)",
                type: "tm_set_variable_node",
                variableName: $0.element.id
            )
        }
        var wires = constructors.indices.map { index in
            RCP3ScriptGraph.Wire(
                id: "exec\(index)",
                from: index == 0 ? "u" : "set\(index - 1)",
                to: "set\(index)"
            )
        }
        wires += constructors.enumerated().map { index, constructor in
            RCP3ScriptGraph.Wire(
                id: "value\(index)",
                from: constructor.id,
                to: "set\(index)",
                fromPin: TMHash.murmur64a(constructor.output),
                toPin: TMHash.murmur64a("value")
            )
        }
        let data = constructors.flatMap { constructor in
            constructor.inputs.enumerated().map { index, pin in
                RCP3ScriptGraph.DataLiteral(
                    id: "\(constructor.id)-\(pin)",
                    toNode: constructor.id,
                    toPin: TMHash.murmur64a(pin),
                    scalarValue: Double(index + 1)
                )
            }
        }

        let js = CanonicalScriptGraphCompiler().compile(
            RCP3ScriptGraph(
                nodes: [update] + setters + makeNodes,
                wires: wires,
                data: data
            )
        )

        #expect(js.contains("const Foundation = require(\"Foundation\");"))
        #expect(js.contains("const CoreGraphics = require(\"CoreGraphics\");"))
        #expect(js.contains("const Math3D = require(\"Math3D\");"))
        #expect(js.contains("new CoreGraphics.CGColor(1, 2, 3, 4)"))
        #expect(js.contains("new Foundation.EdgeInsets(1, 2, 3, 4)"))
        #expect(js.contains("new Math3D.Matrix2x2(1, 2)"))
        #expect(js.contains("new Math3D.Matrix3x3(1, 2, 3)"))
        #expect(js.contains("new Math3D.Matrix4x4(1, 2, 3, 4)"))
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

    @Test func entityParentAndChildrenNodesCompile() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let setParent = RCP3ScriptGraph.Node(id: "setParent", type: "tm_set_variable_node", variableName: "parent")
        let setChildren = RCP3ScriptGraph.Node(id: "setChildren", type: "tm_set_variable_node", variableName: "children")
        let parent = RCP3ScriptGraph.Node(id: "parent", type: "tm_get_parent")
        let children = RCP3ScriptGraph.Node(id: "children", type: "tm_get_children")
        let wires = [
            RCP3ScriptGraph.Wire(id: "e0", from: "u", to: "setParent"),
            RCP3ScriptGraph.Wire(id: "e1", from: "setParent", to: "setChildren"),
            RCP3ScriptGraph.Wire(id: "p", from: "parent", to: "setParent", fromPin: TMHash.murmur64a("parent"), toPin: TMHash.murmur64a("value")),
            RCP3ScriptGraph.Wire(id: "c", from: "children", to: "setChildren", fromPin: TMHash.murmur64a("children"), toPin: TMHash.murmur64a("value")),
        ]

        let js = CanonicalScriptGraphCompiler().compile(RCP3ScriptGraph(nodes: [update, setParent, setChildren, parent, children], wires: wires, data: []))

        #expect(js.contains("= this.entity.parent;"))
        #expect(js.contains("= this.entity.children;"))
        #expect(!js.contains("unsupported"))
    }

    @Test func entityParentChildActionsCompile() {
        for (type, expected) in [
            ("tm_set_parent", ".setParent("),
            ("tm_add_child", ".addChild("),
            ("tm_remove_child", ".removeChild("),
            ("tm_remove_from_parent", ".removeFromParent("),
        ] {
            let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
            let action = RCP3ScriptGraph.Node(id: "action", type: type)
            let graph = RCP3ScriptGraph(
                nodes: [update, action],
                wires: [RCP3ScriptGraph.Wire(id: "e", from: "u", to: "action")],
                data: []
            )

            let js = CanonicalScriptGraphCompiler().compile(graph)

            #expect(js.contains(expected))
            if type == "tm_remove_from_parent" {
                #expect(js.contains("this.entity.isEnabled = false;"))
            }
            #expect(!js.contains("unsupported"))
        }
    }

    @Test func entityEnableActionCompilesToIsEnabledAssignment() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let enable = RCP3ScriptGraph.Node(id: "enable", type: "tm_set_entity_enable")
        let graph = RCP3ScriptGraph(
            nodes: [update, enable],
            wires: [RCP3ScriptGraph.Wire(id: "e", from: "u", to: "enable")],
            data: [
                RCP3ScriptGraph.DataLiteral(id: "enabled", toNode: "enable", toPin: TMHash.murmur64a("isEnabled"), scalarValue: 1),
            ]
        )

        let js = CanonicalScriptGraphCompiler().compile(graph)

        #expect(js.contains("this.entity.isEnabled = 1;"))
        #expect(!js.contains("unsupported"))
    }

    @Test func entityFindNodesCompileToEntityLookupCalls() {
        for (type, expected) in [
            ("tm_find_entity", ".findEntity(7, 1)"),
            ("tm_find_parent_entity", ".findParent(7)"),
            ("tm_find_entity_with_component", ".findEntityWithComponent(7)"),
        ] {
            let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
            let set = RCP3ScriptGraph.Node(id: "set", type: "tm_set_variable_node", variableName: "found")
            let find = RCP3ScriptGraph.Node(id: "find", type: type)
            var data = [
                RCP3ScriptGraph.DataLiteral(
                    id: "arg",
                    toNode: "find",
                    toPin: TMHash.murmur64a(type == "tm_find_entity_with_component" ? "component_type" : "name"),
                    scalarValue: 7
                ),
            ]
            if type == "tm_find_entity" {
                data.append(RCP3ScriptGraph.DataLiteral(id: "recursive", toNode: "find", toPin: TMHash.murmur64a("recursive"), scalarValue: 1))
            }
            let graph = RCP3ScriptGraph(
                nodes: [update, set, find],
                wires: [
                    RCP3ScriptGraph.Wire(id: "e", from: "u", to: "set"),
                    RCP3ScriptGraph.Wire(id: "value", from: "find", to: "set", fromPin: TMHash.murmur64a("entity"), toPin: TMHash.murmur64a("value")),
                ],
                data: data
            )

            let js = CanonicalScriptGraphCompiler().compile(graph)

            #expect(js.contains(expected))
            #expect(!js.contains("unsupported"))
        }
    }

    @Test func hasComponentCompilesToHasComponentCall() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let set = RCP3ScriptGraph.Node(id: "set", type: "tm_set_variable_node", variableName: "hasComponent")
        let has = RCP3ScriptGraph.Node(id: "has", type: "tm_has_component")
        let graph = RCP3ScriptGraph(
            nodes: [update, set, has],
            wires: [
                RCP3ScriptGraph.Wire(id: "e", from: "u", to: "set"),
                RCP3ScriptGraph.Wire(id: "value", from: "has", to: "set", fromPin: TMHash.murmur64a("result"), toPin: TMHash.murmur64a("value")),
            ],
            data: [
                RCP3ScriptGraph.DataLiteral(id: "component", toNode: "has", toPin: TMHash.murmur64a("component_type"), scalarValue: 7),
            ]
        )

        let js = CanonicalScriptGraphCompiler().compile(graph)

        #expect(js.contains("= this.entity.hasComponent(7);"))
        #expect(!js.contains("unsupported"))
    }

    @Test func removeComponentGuardsTheSourceMutation() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let remove = RCP3ScriptGraph.Node(id: "remove", type: "tm_remove_component")
        let graph = RCP3ScriptGraph(
            nodes: [update, remove],
            wires: [.init(id: "exec", from: "u", to: "remove")],
            data: [.init(
                id: "component", toNode: "remove",
                toPin: TMHash.murmur64a("component_type"), scalarValue: 7
            )]
        )

        let js = CanonicalScriptGraphCompiler().compile(graph)
        #expect(js.contains("if (this.entity.hasComponent(7)) {"))
        #expect(js.contains("this.entity.removeComponent(7);"))
        #expect(!js.contains("unsupported"))
    }

    @Test func entityWorldTransformNodesCompile() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let setVariable = RCP3ScriptGraph.Node(id: "setVar", type: "tm_set_variable_node", variableName: "worldPosition")
        let getWorld = RCP3ScriptGraph.Node(id: "getWorld", type: "tm_entity_get_world_transform")
        let setWorld = RCP3ScriptGraph.Node(id: "setWorld", type: "tm_entity_set_world_transform")
        let vector = RCP3ScriptGraph.Node(id: "vec", type: "tm_make_vector3")
        let graph = RCP3ScriptGraph(
            nodes: [update, setVariable, getWorld, setWorld, vector],
            wires: [
                RCP3ScriptGraph.Wire(id: "e0", from: "u", to: "setVar"),
                RCP3ScriptGraph.Wire(id: "e1", from: "setVar", to: "setWorld"),
                RCP3ScriptGraph.Wire(id: "read", from: "getWorld", to: "setVar", fromPin: TMHash.murmur64a("position"), toPin: TMHash.murmur64a("value")),
                RCP3ScriptGraph.Wire(id: "write", from: "vec", to: "setWorld", fromPin: TMHash.murmur64a("vec3"), toPin: TMHash.murmur64a("position")),
            ],
            data: [
                RCP3ScriptGraph.DataLiteral(id: "x", toNode: "vec", toPin: TMHash.murmur64a("x"), scalarValue: 1),
                RCP3ScriptGraph.DataLiteral(id: "y", toNode: "vec", toPin: TMHash.murmur64a("y"), scalarValue: 2),
                RCP3ScriptGraph.DataLiteral(id: "z", toNode: "vec", toPin: TMHash.murmur64a("z"), scalarValue: 3),
            ]
        )

        let js = CanonicalScriptGraphCompiler().compile(graph)

        #expect(js.contains("= this.entity.worldPosition;"))
        #expect(js.contains("this.entity.worldPosition = new Math3D.Vector3(1, 2, 3);"))
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

    @Test func entityEqualsUsesSchemaObjectEquality() {
        let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
        let selfNode = RCP3ScriptGraph.Node(id: "self", type: "tm_self")
        let equals = RCP3ScriptGraph.Node(id: "equals", type: "tm_entity_equals")
        let set = RCP3ScriptGraph.Node(id: "set", type: "tm_set_variable_node", variableName: "same")
        let graph = RCP3ScriptGraph(nodes: [update, selfNode, equals, set], wires: [
            .init(id: "exec", from: "u", to: "set"),
            .init(id: "a", from: "self", to: "equals",
                  fromPin: TMHash.murmur64a("entity"), toPin: TMHash.murmur64a("a")),
            .init(id: "b", from: "self", to: "equals",
                  fromPin: TMHash.murmur64a("entity"), toPin: TMHash.murmur64a("b")),
            .init(id: "result", from: "equals", to: "set",
                  fromPin: TMHash.murmur64a("result"), toPin: TMHash.murmur64a("value")),
        ], data: [])

        let js = CanonicalScriptGraphCompiler().compile(graph)
        #expect(js.contains("(this.entity).equals(this.entity)"))
        #expect(!js.contains("unsupported: tm_entity_equals"))
    }

    @Test func relativeTransformAndDirectionQueriesUsePublicEntitySurface() {
        func graph(sourceType: String, output: String) -> RCP3ScriptGraph {
            let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
            let selfNode = RCP3ScriptGraph.Node(id: "self", type: "tm_self")
            let source = RCP3ScriptGraph.Node(id: "source", type: sourceType)
            let set = RCP3ScriptGraph.Node(id: "set", type: "tm_set_variable_node", variableName: "value")
            return RCP3ScriptGraph(nodes: [update, selfNode, source, set], wires: [
                .init(id: "exec", from: "u", to: "set"),
                .init(id: "entity", from: "self", to: "source",
                      fromPin: TMHash.murmur64a("entity"), toPin: TMHash.murmur64a("entity")),
                .init(id: "value", from: "source", to: "set",
                      fromPin: TMHash.murmur64a(output), toPin: TMHash.murmur64a("value")),
            ], data: [])
        }

        let relative = CanonicalScriptGraphCompiler().compile(
            graph(sourceType: "tm_entity_get_relative_transform", output: "position")
        )
        #expect(relative.contains("this.entity.relativePosition(null)"))

        let local = CanonicalScriptGraphCompiler().compile(
            graph(sourceType: "tm_entity_get_local_direction_vectors", output: "forward")
        )
        #expect(local.contains("this.entity.localForward"))

        let world = CanonicalScriptGraphCompiler().compile(
            graph(sourceType: "tm_entity_get_world_direction_vectors", output: "right")
        )
        #expect(world.contains("this.entity.worldRight"))
    }

    @Test func simplePhysicsActionsUsePublicEntityMethods() {
        func graph(actionType: String, recursive: Bool) -> RCP3ScriptGraph {
            let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
            let action = RCP3ScriptGraph.Node(id: "action", type: actionType)
            return RCP3ScriptGraph(nodes: [update, action], wires: [
                .init(id: "exec", from: "u", to: "action"),
            ], data: [
                .init(id: "recursive", toNode: "action", toPin: TMHash.murmur64a("recursive"), value: .bool(recursive)),
            ])
        }

        let clear = CanonicalScriptGraphCompiler().compile(
            graph(actionType: "tm_physics_clear_forces_and_torques", recursive: true)
        )
        #expect(clear.contains("this.entity.clearForcesAndTorques(true);"))

        let reset = CanonicalScriptGraphCompiler().compile(
            graph(actionType: "tm_physics_reset_transform", recursive: false)
        )
        #expect(reset.contains("this.entity.resetPhysicsTransform(false);"))
    }

    @Test func forceAndImpulseActionsUseHarvestedOverloads() {
        func compile(_ type: String, valuePin: String, hasPosition: Bool) -> String {
            let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
            let action = RCP3ScriptGraph.Node(id: "action", type: type)
            var data = [
                RCP3ScriptGraph.DataLiteral(id: "value", toNode: "action", toPin: TMHash.murmur64a(valuePin), value: .number(2)),
            ]
            if hasPosition {
                data.append(.init(id: "at", toNode: "action", toPin: TMHash.murmur64a("at"), value: .number(3)))
            }
            return CanonicalScriptGraphCompiler().compile(RCP3ScriptGraph(
                nodes: [update, action], wires: [.init(id: "exec", from: "u", to: "action")], data: data
            ))
        }

        #expect(compile("tm_physics_add_force", valuePin: "force", hasPosition: true)
            .contains("this.entity.addForce(2, 3, null);"))
        #expect(compile("tm_physics_apply_impulse", valuePin: "impulse", hasPosition: true)
            .contains("this.entity.applyLinearImpulse(2, 3, null);"))
        #expect(compile("tm_physics_add_torque", valuePin: "torque", hasPosition: false)
            .contains("this.entity.addTorque(2, null);"))
        #expect(compile("tm_physics_apply_linear_impulse", valuePin: "impulse", hasPosition: false)
            .contains("this.entity.applyLinearImpulse(2, null);"))
        #expect(compile("tm_physics_apply_angular_impulse", valuePin: "impulse", hasPosition: false)
            .contains("this.entity.applyAngularImpulse(2, null);"))
    }

    @Test func schemaMakeConstructorsUseHarvestedOrderAndRuntimeTypes() {
        func compile(
            _ type: String,
            output: String,
            inputs: [(String, Double)]
        ) -> String {
            let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
            let make = RCP3ScriptGraph.Node(id: "make", type: type)
            let set = RCP3ScriptGraph.Node(
                id: "set", type: "tm_set_variable_node", variableName: "value"
            )
            let data = inputs.enumerated().map { index, input in
                RCP3ScriptGraph.DataLiteral(
                    id: "d\(index)", toNode: "make",
                    toPin: TMHash.murmur64a(input.0), value: .number(input.1)
                )
            }
            return CanonicalScriptGraphCompiler().compile(RCP3ScriptGraph(
                nodes: [update, make, set],
                wires: [
                    .init(id: "exec", from: "u", to: "set"),
                    .init(
                        id: "value", from: "make", to: "set",
                        fromPin: TMHash.murmur64a(output), toPin: TMHash.murmur64a("value")
                    ),
                ],
                data: data
            ))
        }

        let texture = compile(
            "tm_make_material_parameter_types_texture_coordinate_transform",
            output: "textureCoordinateTransform",
            inputs: [("offset", 1), ("scale", 2), ("rotation", 3)]
        )
        #expect(texture.contains(
            "new RealityKit.MaterialParameterTypes.TextureCoordinateTransform(1, 2, 3)"
        ))

        let scalarCases: [(String, String, String, String)] = [
            ("tm_make_physically_based_material_anisotropy_angle", "angle", "angle", "AnisotropyAngle"),
            ("tm_make_physically_based_material_anisotropy_level", "level", "level", "AnisotropyLevel"),
            ("tm_make_physically_based_material_clearcoat", "clearcoat", "clearcoat", "Clearcoat"),
            ("tm_make_physically_based_material_clearcoat_roughness", "roughness", "roughness", "ClearcoatRoughness"),
            ("tm_make_physically_based_material_metallic", "metallic", "metallic", "Metallic"),
            ("tm_make_physically_based_material_roughness", "roughness", "roughness", "Roughness"),
        ]
        for (type, input, output, runtimeType) in scalarCases {
            let js = compile(type, output: output, inputs: [(input, 1)])
            #expect(js.contains("new RealityKit.PhysicallyBasedMaterial.\(runtimeType)(1)"))
        }

        let colorCases: [(String, String, String)] = [
            ("tm_make_physically_based_material_base_color", "baseColor", "BaseColor"),
            ("tm_make_physically_based_material_emissive_color", "emissiveColor", "EmissiveColor"),
            ("tm_make_physically_based_material_sheen_color", "sheenColor", "SheenColor"),
        ]
        for (type, output, runtimeType) in colorCases {
            let js = compile(
                type, output: output,
                inputs: [("red", 1), ("green", 2), ("blue", 3), ("alpha", 4)]
            )
            #expect(js.contains(
                "new RealityKit.PhysicallyBasedMaterial.\(runtimeType)(1, 2, 3, 4)"
            ))
        }

        let mass = compile(
            "tm_make_physics_mass_properties", output: "massProperties",
            inputs: [("mass", 1), ("inertia", 2), ("position", 3), ("orientation", 4)]
        )
        #expect(mass.contains("new RealityKit.PhysicsMassProperties(1, 2, 3, 4)"))

        let material = compile(
            "tm_make_physics_material_resource", output: "material",
            inputs: [("staticFriction", 1), ("dynamicFriction", 2), ("restitution", 3)]
        )
        #expect(material.contains("new RealityKit.PhysicsMaterialResource(1, 2, 3)"))
    }

    @Test func matrixConversionAndEntityMotionUseHarvestedRuntimeSurface() {
        func valueGraph(type: String, output: String, inputs: [(String, Double)]) -> String {
            let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
            let value = RCP3ScriptGraph.Node(id: "value", type: type)
            let set = RCP3ScriptGraph.Node(id: "set", type: "tm_set_variable_node", variableName: "result")
            return CanonicalScriptGraphCompiler().compile(RCP3ScriptGraph(
                nodes: [update, value, set],
                wires: [
                    .init(id: "exec", from: "u", to: "set"),
                    .init(id: "valueWire", from: "value", to: "set",
                          fromPin: TMHash.murmur64a(output), toPin: TMHash.murmur64a("value")),
                ],
                data: inputs.enumerated().map { index, input in
                    .init(id: "d\(index)", toNode: "value", toPin: TMHash.murmur64a(input.0), value: .number(input.1))
                }
            ))
        }

        let to = valueGraph(
            type: "tm_entity_convert_matrix_to", output: "matrix",
            inputs: [("matrix", 1), ("toEntity", 2)]
        )
        #expect(to.contains("this.entity.convertMatrixTo(1, 2)"))

        let from = valueGraph(
            type: "tm_entity_convert_matrix_from", output: "matrix",
            inputs: [("matrix", 1), ("fromEntity", 2)]
        )
        #expect(from.contains(
            "this.entity.convertTransformFrom(new RealityKit.Transform(1), 2).matrix"
        ))

        for (value, method) in [
            ("direction", "Direction"), ("normal", "Normal"), ("position", "Position"),
        ] {
            let to = valueGraph(
                type: "tm_entity_convert_\(value)_to", output: value,
                inputs: [(value, 1), ("toEntity", 2)]
            )
            #expect(to.contains("this.entity.convert\(method)To(1, 2)"))
            let from = valueGraph(
                type: "tm_entity_convert_\(value)_from", output: value,
                inputs: [(value, 1), ("fromEntity", 2)]
            )
            #expect(from.contains("this.entity.convert\(method)From(1, 2)"))
        }

        func actionGraph(type: String, inputs: [(String, Double)]) -> String {
            let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
            let action = RCP3ScriptGraph.Node(id: "action", type: type)
            return CanonicalScriptGraphCompiler().compile(RCP3ScriptGraph(
                nodes: [update, action], wires: [.init(id: "exec", from: "u", to: "action")],
                data: inputs.enumerated().map { index, input in
                    .init(id: "d\(index)", toNode: "action", toPin: TMHash.murmur64a(input.0), value: .number(input.1))
                }
            ))
        }

        let teleport = actionGraph(
            type: "tm_entity_teleport_character", inputs: [("to", 1), ("relativeTo", 2)]
        )
        #expect(teleport.contains("this.entity.teleportCharacter(1, 2);"))

        let move = actionGraph(type: "tm_entity_move", inputs: [
            ("scale", 1), ("orientation", 2), ("position", 3), ("relativeTo", 4),
            ("duration", 5), ("timingFunction", 6),
        ])
        #expect(move.contains(
            "this.entity.move(new RealityKit.Transform(1, 2, 3), 4, 5, 6)"
        ))

        let character = actionGraph(
            type: "tm_entity_move_character",
            inputs: [("by", 1), ("deltaTime", 2), ("relativeTo", 3)]
        )
        #expect(character.contains("this.entity.moveCharacter(1, 2, 3,"))
    }

    @Test func audioMixGroupMutationsRoundTripTheComponent() {
        func graph(type: String, pin: String) -> RCP3ScriptGraph {
            let update = RCP3ScriptGraph.Node(id: "u", type: "tm_update")
            let action = RCP3ScriptGraph.Node(id: "audio", type: type)
            return RCP3ScriptGraph(
                nodes: [update, action], wires: [.init(id: "exec", from: "u", to: "audio")],
                data: [.init(id: "value", toNode: "audio", toPin: TMHash.murmur64a(pin), value: .number(1))]
            )
        }

        let add = CanonicalScriptGraphCompiler().compile(graph(
            type: "tm_audio_mix_groups_component_add_group", pin: "mixGroup"
        ))
        #expect(add.contains("getComponent(RealityKit.AudioMixGroupsComponent.Type) ?? new RealityKit.AudioMixGroupsComponent()"))
        #expect(add.contains(".set(1);"))
        #expect(add.contains("this.entity.setComponent("))

        let remove = CanonicalScriptGraphCompiler().compile(graph(
            type: "tm_audio_mix_groups_component_remove_group", pin: "name"
        ))
        #expect(remove.contains("getComponent(RealityKit.AudioMixGroupsComponent.Type);"))
        #expect(remove.contains(".remove(1);"))
    }

    @Test func audioControllerActionsShareTheHarvestedReceiverTemplate() {
        func compile(_ type: String, values: [(String, TMGraphValue)] = []) -> String {
            let update = RCP3ScriptGraph.Node(id: "update", type: "tm_update")
            let action = RCP3ScriptGraph.Node(id: "audio", type: type)
            let data = values.enumerated().map { index, item in
                RCP3ScriptGraph.DataLiteral(
                    id: "value-\(index)", toNode: "audio",
                    toPin: TMHash.murmur64a(item.0), value: item.1
                )
            }
            return CanonicalScriptGraphCompiler().compile(RCP3ScriptGraph(
                nodes: [update, action],
                wires: [.init(id: "exec", from: "update", to: "audio")],
                data: data
            ))
        }

        #expect(compile("tm_pause_audio").contains("undefined.pause();"))
        #expect(compile("tm_stop_all_audio").contains("this.entity.stopAllAudio();"))
        #expect(compile("tm_stop_audio").contains("undefined.stop();"))
        #expect(compile("tm_stop_audio_group").contains("undefined.stop();"))
        #expect(compile("tm_play_audio_at_time", values: [("time", .number(8))]).contains("undefined.play(8);"))
        #expect(compile("tm_play_audio_group_at_time", values: [("time", .number(9))]).contains("undefined.play(9);"))
        #expect(compile("tm_seek_audio", values: [("time", .number(4))]).contains(
            "undefined.seek(4);"
        ))
        #expect(compile("tm_fade_audio", values: [
            ("gain", .number(0.5)), ("duration", .number(2)),
        ]).contains("undefined.fade(0.5, 2);"))
        #expect(compile("tm_pause_audio_group", values: [("pause", .bool(true))]).contains(
            "if (true) { undefined.pause(); } else { undefined.play(); }"
        ))
        #expect(compile("tm_seek_audio_group", values: [("time", .number(3))]).contains(
            "undefined.seek(3);"
        ))
        #expect(compile("tm_fade_audio_group", values: [
            ("gain", .number(0.25)), ("duration", .number(1)),
        ]).contains("undefined.fade(0.25, 1);"))
        #expect(compile("tm_fade_audio_mix_group", values: [
            ("gain", .number(0.75)), ("duration", .number(3)),
        ]).contains("undefined.fade(0.75, 3);"))
        let named = compile("tm_play_audio_by_name", values: [
            ("name", .string("bell")), ("target", .number(1)),
            ("prepareOnly", .bool(true)),
        ])
        #expect(named.contains("getComponent(RealityKit.AudioLibraryComponent.Type)"))
        #expect(named.contains("resources[\"bell\"]"))
        #expect(named.contains("1.prepareAudio("))
        let group = compile("tm_play_audio_group_by_name", values: [
            ("prepareOnly", .bool(false)),
        ])
        #expect(group.contains("RealityKit.Audio.playAudio("))
    }

    @Test func materialParameterNodesUseModelComponentSlotAndPersistWrites() {
        let update = RCP3ScriptGraph.Node(id: "update", type: "tm_update")
        let setParameter = RCP3ScriptGraph.Node(id: "setParameter", type: "tm_set_material_parameter_v2")
        let getParameter = RCP3ScriptGraph.Node(id: "getParameter", type: "tm_get_material_parameter")
        let capture = RCP3ScriptGraph.Node(
            id: "capture", type: "tm_set_variable_node", variableName: "material value"
        )
        let graph = RCP3ScriptGraph(
            nodes: [update, setParameter, getParameter, capture],
            wires: [
                .init(id: "exec-set", from: "update", to: "setParameter"),
                .init(id: "exec-capture", from: "setParameter", to: "capture"),
                .init(
                    id: "value", from: "getParameter", to: "capture",
                    fromPin: TMHash.murmur64a("value"), toPin: TMHash.murmur64a("value")
                ),
            ],
            data: [
                .init(id: "set-slot", toNode: "setParameter", toPin: TMHash.murmur64a("slot"), value: .number(2)),
                .init(id: "set-parameter", toNode: "setParameter", toPin: TMHash.murmur64a("parameter"), value: .string("roughness")),
                .init(id: "set-value", toNode: "setParameter", toPin: TMHash.murmur64a("value"), value: .number(0.4)),
                .init(id: "get-slot", toNode: "getParameter", toPin: TMHash.murmur64a("slot"), value: .number(2)),
                .init(id: "get-parameter", toNode: "getParameter", toPin: TMHash.murmur64a("parameter"), value: .string("roughness")),
            ]
        )

        let js = CanonicalScriptGraphCompiler().compile(graph)
        #expect(js.contains("getComponent(RealityKit.ModelComponent.Type)"))
        #expect(js.contains(".getMaterial(2)"))
        #expect(js.contains(".setParameter(\"roughness\", 0.4);"))
        #expect(js.contains(".setMaterial(__d3_material_setParameter, 2);"))
        #expect(js.contains("this.entity.setComponent(__d3_model_component_setParameter);"))
        #expect(js.contains("return material.getParameter(\"roughness\");"))
        #expect(js.contains("console.error(\"Get Material Parameter: material not found\")"))
    }

    @Test func modifyAnyMaterialAssignsSerializedInspectableInputsAndPersistsMaterial() {
        let settings = RCP3ScriptGraph.Node.MaterialSettings(
            typeHash: 0x1234,
            objectIdentifier: "RealityKit.PhysicallyBasedMaterial",
            inputs: [
                .init(name: "roughness", typeHash: 1, editTypeHash: 1, isOptional: false),
                .init(name: "clearcoat", typeHash: 1, editTypeHash: 1, isOptional: true),
            ],
            outputs: []
        )
        let update = RCP3ScriptGraph.Node(id: "update", type: "tm_update")
        let modify = RCP3ScriptGraph.Node(
            id: "modify", type: "tm_modify_any_material", materialSettings: settings
        )
        let graph = RCP3ScriptGraph(
            nodes: [update, modify],
            wires: [.init(id: "exec", from: "update", to: "modify")],
            data: [
                .init(id: "slot", toNode: "modify", toPin: TMHash.murmur64a("slot"), value: .number(1)),
                .init(id: "roughness", toNode: "modify", toPin: TMHash.murmur64a("roughness"), value: .number(0.25)),
                .init(id: "clearcoat", toNode: "modify", toPin: TMHash.murmur64a("clearcoat"), value: .number(0.5)),
            ]
        )

        let js = CanonicalScriptGraphCompiler().compile(graph)
        #expect(js.contains("const __d3_modified_material_modify = __d3_model_component_modify.getMaterial(1);"))
        #expect(js.contains("__d3_modified_material_modify.roughness = 0.25;"))
        #expect(js.contains("if (0.5 !== undefined) { __d3_modified_material_modify.clearcoat = 0.5; }"))
        #expect(js.contains("__d3_model_component_modify.setMaterial(__d3_modified_material_modify, 1);"))
        #expect(js.contains("this.entity.setComponent(__d3_model_component_modify);"))
    }

    @Test func constantBitsetFoldsDataOnlyBooleanPins() {
        let update = RCP3ScriptGraph.Node(id: "update", type: "tm_update")
        let bitset = RCP3ScriptGraph.Node(id: "bits", type: "tm_constant_bitset")
        let set = RCP3ScriptGraph.Node(id: "set", type: "tm_set_variable_node", variableName: "mask")
        let graph = RCP3ScriptGraph(
            nodes: [update, bitset, set],
            wires: [
                .init(id: "exec", from: "update", to: "set"),
                .init(
                    id: "value", from: "bits", to: "set",
                    fromPin: TMHash.murmur64a("value"),
                    toPin: TMHash.murmur64a("value")
                ),
            ],
            data: [
                .init(id: "count", toNode: "bits", toPin: TMHash.murmur64a("count"), value: .number(4)),
                .init(id: "zero", toNode: "bits", toPin: TMHash.murmur64a("0"), value: .bool(true)),
                .init(id: "one", toNode: "bits", toPin: TMHash.murmur64a("1"), value: .bool(false)),
                .init(id: "two", toNode: "bits", toPin: TMHash.murmur64a("2"), value: .bool(true)),
                .init(id: "three", toNode: "bits", toPin: TMHash.murmur64a("3"), value: .bool(true)),
            ]
        )

        let js = CanonicalScriptGraphCompiler().compile(graph)
        #expect(js.contains("this.variable_"))
        #expect(js.contains("= 13;"))
    }

    @Test func typedIsValidRejectsUndefinedAndNull() {
        let update = RCP3ScriptGraph.Node(id: "update", type: "tm_update")
        let value = RCP3ScriptGraph.Node(id: "value", type: "tm_make_number")
        let valid = RCP3ScriptGraph.Node(
            id: "valid",
            type: "tm_is_valid",
            dynamicConnectorSettings: Self.dynamicSettings(inputs: ["value"])
        )
        let set = RCP3ScriptGraph.Node(id: "set", type: "tm_set_variable_node", variableName: "valid")
        let graph = RCP3ScriptGraph(
            nodes: [update, value, valid, set],
            wires: [
                .init(id: "exec", from: "update", to: "set"),
                .init(
                    id: "input", from: "value", to: "valid",
                    fromPin: TMHash.murmur64a("value"), toPin: TMHash.murmur64a("value")
                ),
                .init(
                    id: "result", from: "valid", to: "set",
                    fromPin: TMHash.murmur64a("result"), toPin: TMHash.murmur64a("value")
                ),
            ],
            data: [.init(
                id: "number", toNode: "value", toPin: TMHash.murmur64a("initial_value"),
                value: .number(7)
            )]
        )

        let js = CanonicalScriptGraphCompiler().compile(graph)
        #expect(js.contains("7 !== undefined && 7 !== null"))
    }

    @Test func typedIsValidBranchEmitsBothScopes() {
        let update = RCP3ScriptGraph.Node(id: "update", type: "tm_update")
        let branch = RCP3ScriptGraph.Node(
            id: "branch", type: "tm_is_valid_branch",
            dynamicConnectorSettings: Self.dynamicSettings(inputs: ["source"])
        )
        let valid = RCP3ScriptGraph.Node(id: "valid", type: "tm_log", label: "valid")
        let invalid = RCP3ScriptGraph.Node(id: "invalid", type: "tm_log", label: "invalid")
        let graph = RCP3ScriptGraph(
            nodes: [update, branch, valid, invalid],
            wires: [
                .init(id: "exec", from: "update", to: "branch"),
                .init(
                    id: "validWire", from: "branch", to: "valid",
                    fromPin: TMHash.murmur64a("valid"), toPin: nil
                ),
                .init(
                    id: "invalidWire", from: "branch", to: "invalid",
                    fromPin: TMHash.murmur64a("invalid"), toPin: nil
                ),
            ],
            data: [.init(
                id: "source", toNode: "branch", toPin: TMHash.murmur64a("source"),
                value: .number(3)
            )]
        )

        let js = CanonicalScriptGraphCompiler().compile(graph)
        #expect(js.contains("if (3 !== undefined && 3 !== null)"))
        #expect(js.contains("} else {"))
    }

    @Test func boolToAnyUsesTheShippedConditionalExpression() {
        let boolToAny = RCP3ScriptGraph.Node(id: "pick", type: "tm_bool_to_any")
        let set = RCP3ScriptGraph.Node(id: "set", type: "tm_set_variable_node", variableName: "picked")
        let update = RCP3ScriptGraph.Node(id: "update", type: "tm_update")
        let graph = RCP3ScriptGraph(
            nodes: [update, boolToAny, set],
            wires: [
                .init(id: "exec", from: "update", to: "set"),
                .init(
                    id: "result", from: "pick", to: "set",
                    fromPin: TMHash.murmur64a("result"), toPin: TMHash.murmur64a("value")
                ),
            ],
            data: [
                .init(id: "guard", toNode: "pick", toPin: TMHash.murmur64a("bool"), value: .bool(true)),
                .init(id: "yes", toNode: "pick", toPin: TMHash.murmur64a("true"), value: .number(4)),
                .init(id: "no", toNode: "pick", toPin: TMHash.murmur64a("false"), value: .number(9)),
            ]
        )

        let js = CanonicalScriptGraphCompiler().compile(graph)
        #expect(js.contains("(true ? 4 : 9)"))
    }
}
