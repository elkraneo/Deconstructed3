import DeconstructedFeature
import RCP3CanonicalRuntime
import RCP3Document
import SwiftUI

/// The app's root view, and the app-target seam for the canonical runtime.
///
/// The binary `RealityKitScripting` framework is linked + embedded here (via
/// `RCP3CanonicalRuntime`), so the **app** — not the tested library — owns
/// presenting the canonical "Simulate" view. `AppRootView` only reports the intent
/// (a plain `(RCP3ScriptGraph) -> Void`); we present `CanonicalSimulateView` in a
/// `.sheet(item:)`, no `AnyView` involved.
struct ContentView: View {
    @State private var simulateRequest: SimulateRequest?

    var body: some View {
        AppRootView(onCanonicalSimulate: { simulateRequest = SimulateRequest(graph: $0) })
            .sheet(item: $simulateRequest) { request in
                CanonicalSimulateView(graph: request.graph)
                    .frame(minWidth: 480, minHeight: 360)
            }
    }
}

/// A pending canonical-simulate request; its identity lets `.sheet(item:)` drive
/// presentation from the graph the user chose to run.
private struct SimulateRequest: Identifiable {
    let id = UUID()
    let graph: RCP3ScriptGraph
}
