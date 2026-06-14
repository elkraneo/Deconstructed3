import ComposableArchitecture
import RCP3Document
import SwiftUI

/// The app-facing entry point for the document feature.
///
/// Owns the `StoreOf<DocumentFeature>` and presents the 3-pane `DocumentView`, so
/// the app target can drive the whole feature with a single `import
/// DeconstructedFeature` — no direct TCA dependency needed in the app.
public struct AppRootView: View {
    @State private var store = Store(initialState: DocumentFeature.State()) {
        DocumentFeature()
    }

    /// Invoked when the user asks to run a graph on Apple's real `RealityKitScripting`
    /// runtime. The **app** target wires it (it owns the presentation + links the
    /// binary framework); this layer stays free of that dependency so `swift test`
    /// works. When `nil`, the Simulate affordance is hidden.
    private let onCanonicalSimulate: ((RCP3ScriptGraph) -> Void)?

    public init(onCanonicalSimulate: ((RCP3ScriptGraph) -> Void)? = nil) {
        self.onCanonicalSimulate = onCanonicalSimulate
    }

    public var body: some View {
        DocumentView(store: store, onCanonicalSimulate: onCanonicalSimulate)
    }
}

public extension DocumentClient {
    /// App-startup hook: installs the live disk-backed client (re-exported so the
    /// app target needs only `import DeconstructedFeature`). Equivalent to
    /// `DocumentClient.installLive()`.
    static func installLiveForApp() {
        installLive()
    }
}
