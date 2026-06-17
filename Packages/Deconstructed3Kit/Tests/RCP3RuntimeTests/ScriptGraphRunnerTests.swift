import Testing
import Foundation
import TMFormat
import RCP3Document
import RCP3Runtime

@MainActor
@Suite struct ScriptGraphRunnerTests {
    /// The workspace-local `Random` capture, if present.
    static var randomBundleURL: URL? {
        var dir = URL(filePath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            let bundle = dir.appending(path: "references/Random.realitycomposerpro")
            if FileManager.default.fileExists(atPath: bundle.appending(path: "world.tm_entity").path) {
                return bundle
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    @Test func runsInMemoryGraphAndMovesOnDrag() {
        let graph = ScriptGraphCompilerTests.dragToSetTranslationGraph()
        let state = RuntimeEntityState()

        let host = ScriptGraphRunner.run(graph, into: state)
        host.dispatch(event: "drag", payload: ["delta": [2.0, 0.0, 1.0]])

        #expect(state.translation == SIMD3(2, 0, 1))
    }

    @Test func endToEndRandomFixtureMovesBoxByDelta() throws {
        guard let url = Self.randomBundleURL else { return } // capture not present
        let bundle = try RCP3Bundle.open(url)
        // The "on drag → move box" logic lives in the standalone prototype
        // `Script Graph` asset; the `box` entity now carries an EDITED instance
        // override (a different graph), so load the prototype asset directly to
        // exercise the drag-moves-box runtime this test is about.
        let asset = try #require(
            bundle.scriptGraphAssets().first { $0.name.contains("Script Graph") }
        )
        let graph = try #require(bundle.scriptGraph(assetID: asset.id))

        let state = RuntimeEntityState()
        let host = ScriptGraphRunner.run(graph, into: state)

        host.dispatch(event: "drag", payload: ["delta": [2.0, 0.0, 1.0]])

        #expect(state.translation == SIMD3(2, 0, 1))

        // A second drag accumulates: the state is mutated in place.
        host.dispatch(event: "drag", payload: ["delta": [0.0, 3.0, 0.0]])
        #expect(state.translation == SIMD3(2, 3, 1))
        #expect(host.lastException == nil)
    }
}
