import Testing
import TMFormat
import RCP3Document
import RCP3Runtime

/// A small, deterministic certification boundary for the compiler/runtime pair.
///
/// This deliberately does not link the binary RKS runtime. It verifies the source
/// contract byte-for-byte, then executes that same source in the public
/// JavaScriptCore preview host and checks its externally observable mutation.
@MainActor
@Suite struct ScriptGraphCertificationTests {
    static let dragGolden = """
    // Compiled from RCP 3 script graph (2 nodes).
    entity.on("drag", (e) => {
        const t = entity.transform.translation; entity.transform.translation = [t[0]+e.delta[0], t[1]+e.delta[1], t[2]+e.delta[2]];
    });

    """

    static func dragGraph() -> RCP3ScriptGraph {
        let event = RCP3ScriptGraph.Node(id: "event", type: "tm_gesture_event_drag")
        let action = RCP3ScriptGraph.Node(id: "action", type: "tm_set_component")
        return RCP3ScriptGraph(
            nodes: [event, action],
            wires: [
                .init(id: "exec", from: event.id, to: action.id),
                .init(
                    id: "translation",
                    from: event.id,
                    to: action.id,
                    fromPin: TMHash.murmur64a("sceneTranslation"),
                    toPin: TMHash.murmur64a("translation")
                ),
            ],
            data: []
        )
    }

    @Test func representativeCompilerGoldenIsByteStable() {
        let compiler = ScriptGraphCompiler()
        let first = compiler.compile(Self.dragGraph())
        let second = compiler.compile(Self.dragGraph())

        #expect(first == Self.dragGolden)
        #expect(second == first)
    }

    @Test func goldenSourceHasCertifiedObservableBehavior() {
        let state = RuntimeEntityState(translation: SIMD3(10, 20, 30))
        let host = ScriptJSHost(state: state)

        // Execute the golden itself. This ensures the source we approve above—not
        // merely another compiler invocation—is what receives behavior coverage.
        host.load(Self.dragGolden)
        #expect(host.hasHandler(for: "drag"))
        #expect(host.lastException == nil)

        host.dispatch(event: "drag", payload: ["delta": [1.0, -2.0, 3.5]])
        #expect(state.translation == SIMD3(11, 18, 33.5))
        #expect(host.lastException == nil)

        host.dispatch(event: "drag", payload: ["delta": [-4.0, 2.0, 0.5]])
        #expect(state.translation == SIMD3(7, 20, 34))
        #expect(host.lastException == nil)
    }

    @Test func compiledSourceAndGoldenHaveIdenticalBehavior() {
        func result(afterLoading source: String) -> SIMD3<Double> {
            let state = RuntimeEntityState(translation: SIMD3(2, 4, 8))
            let host = ScriptJSHost(state: state)
            host.load(source)
            host.dispatch(event: "drag", payload: ["delta": [3.0, 5.0, 7.0]])
            return state.translation
        }

        let compiled = ScriptGraphCompiler().compile(Self.dragGraph())
        #expect(result(afterLoading: compiled) == result(afterLoading: Self.dragGolden))
        #expect(result(afterLoading: compiled) == SIMD3(5, 9, 15))
    }
}
