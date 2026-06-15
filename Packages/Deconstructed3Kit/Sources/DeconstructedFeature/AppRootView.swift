import ComposableArchitecture
import RCP3Document
import SwiftUI

/// The app-facing entry point for the document feature.
///
/// Owns the `StoreOf<DocumentFeature>` and presents the 3-pane `DocumentView`, so
/// the app target can drive the whole feature with a single `import
/// DeconstructedFeature` — no direct TCA dependency needed in the app.
///
/// Generic over `CanonicalPlay` — the concrete inline Play view the **app** injects
/// (it owns the presentation + links the binary `RealityKitScripting` framework).
/// The tested library never names that view, so `swift test` stays free of the
/// binary dependency; previews/tests use the `EmptyView`-returning default. No
/// `AnyView`.
public struct AppRootView<CanonicalPlay: View>: View {
    @State private var store = Store(initialState: DocumentFeature.State()) {
        DocumentFeature()
    }

    /// Builds the inline canonical Play view for a graph. Threaded straight through
    /// to `DocumentView`'s `@ViewBuilder` seam.
    private let canonicalPlay: (RCP3ScriptGraph) -> CanonicalPlay

    public init(
        @ViewBuilder canonicalPlay: @escaping (RCP3ScriptGraph) -> CanonicalPlay
    ) {
        self.canonicalPlay = canonicalPlay
    }

    public var body: some View {
        DocumentView(store: store, canonicalPlay: canonicalPlay)
    }
}

public extension AppRootView where CanonicalPlay == EmptyView {
    /// Constructs an `AppRootView` with NO canonical Play view (previews/tests). The
    /// real app provides a concrete view via the designated `@ViewBuilder` init.
    init() {
        self.init { _ in EmptyView() }
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
