import ComposableArchitecture
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

    public init() {}

    public var body: some View {
        DocumentView(store: store)
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
