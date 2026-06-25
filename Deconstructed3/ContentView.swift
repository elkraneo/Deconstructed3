import DeconstructedFeature
import RCP3CanonicalRuntime
import SwiftUI

/// The app's root view, and the app-target seam for the canonical runtime.
///
/// The binary `RealityKitScripting` framework is linked + embedded here (via
/// `RCP3CanonicalRuntime`), so the **app** — not the tested library — provides the
/// inline canonical Play view. `AppRootView` exposes a `@ViewBuilder` seam; we hand
/// it `CanonicalPlayView` directly (no `AnyView`, no sheet). Pressing ▶ Play swaps
/// the document's center column to this view, running the graph on Apple's real
/// runtime.
struct ContentView: View {
    var body: some View {
        AppRootView { playScene in
            CanonicalPlayView(playScene)
        }
    }
}
