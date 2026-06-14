import Testing
import Foundation
import RCP3Runtime

@MainActor
@Suite struct ScriptJSHostTests {
    @Test func directTransformWriteReachesState() {
        let state = RuntimeEntityState()
        let host = ScriptJSHost(state: state)

        host.load("entity.transform.translation = [1, 2, 3];")

        #expect(state.translation == SIMD3(1, 2, 3))
        #expect(host.lastException == nil)
    }

    @Test func transformReadReflectsState() {
        let state = RuntimeEntityState(translation: SIMD3(4, 5, 6))
        let host = ScriptJSHost(state: state)

        // Round-trip the value through JS: read translation, write it to scale.
        host.load("entity.transform.scale = entity.transform.translation;")

        #expect(state.scale == SIMD3(4, 5, 6))
    }

    @Test func dragHandlerWritesFromPayload() {
        let state = RuntimeEntityState()
        let host = ScriptJSHost(state: state)

        host.load("entity.on(\"drag\", (e) => { entity.transform.translation = e.delta; });")
        #expect(host.hasHandler(for: "drag"))

        host.dispatch(event: "drag", payload: ["delta": [5.0, 0.0, 0.0]])

        #expect(state.translation == SIMD3(5, 0, 0))
    }

    @Test func dragHandlerAccumulatesAcrossDispatches() {
        let state = RuntimeEntityState()
        let host = ScriptJSHost(state: state)

        host.load("""
        entity.on("drag", (e) => {
            const t = entity.transform.translation;
            entity.transform.translation = [t[0]+e.delta[0], t[1]+e.delta[1], t[2]+e.delta[2]];
        });
        """)

        host.dispatch(event: "drag", payload: ["delta": [1.0, 0.0, 0.0]])
        host.dispatch(event: "drag", payload: ["delta": [2.0, 0.0, 0.0]])

        #expect(state.translation == SIMD3(3, 0, 0))
    }

    @Test func multipleHandlersAllFire() {
        let state = RuntimeEntityState()
        let host = ScriptJSHost(state: state)

        host.load("""
        entity.on("drag", (e) => {
            const t = entity.transform.translation;
            entity.transform.translation = [t[0]+1, t[1], t[2]];
        });
        entity.on("drag", (e) => {
            const t = entity.transform.translation;
            entity.transform.translation = [t[0], t[1]+10, t[2]];
        });
        """)

        host.dispatch(event: "drag")

        #expect(state.translation == SIMD3(1, 10, 0))
    }

    @Test func dispatchWithoutHandlerIsNoOp() {
        let state = RuntimeEntityState(translation: SIMD3(7, 8, 9))
        let host = ScriptJSHost(state: state)

        host.dispatch(event: "drag", payload: ["delta": [1.0, 1.0, 1.0]])

        #expect(state.translation == SIMD3(7, 8, 9))
    }

    @Test func rotationRoundTripsThroughJS() {
        let state = RuntimeEntityState()
        let host = ScriptJSHost(state: state)

        host.load("entity.transform.rotation = [0, 0, 0, 1];")

        #expect(state.rotation.real == 1)
        #expect(state.rotation.imag == SIMD3(0, 0, 0))
    }

    @Test func uncaughtExceptionIsRecorded() {
        let state = RuntimeEntityState()
        let host = ScriptJSHost(state: state)

        host.load("throw new Error(\"boom\");")

        #expect(host.lastException?.contains("boom") == true)
    }

    @Test func consoleLogIsCollected() {
        let state = RuntimeEntityState()
        let host = ScriptJSHost(state: state)

        host.load("console.log(\"hello\", 42);")
        host.load("entity.on(\"tap\", (e) => { console.log(\"tapped\"); });")
        host.dispatch(event: "tap")

        #expect(host.consoleMessages == ["hello 42", "tapped"])
        #expect(host.lastException == nil)
    }
}
