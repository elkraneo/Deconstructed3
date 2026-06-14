import DeconstructedFeature
import RCP3CanonicalRuntime
import SwiftUI

@main
struct DeconstructedThreeApp: App {
    @MainActor
    init() {
        // Shell-runtime install: the live `DocumentClient` (disk-backed
        // RCP3Editor open/save) replaces the throwing stub at startup. A missed
        // install would fail loudly — see DocumentClient+Live.
        DocumentClient.installLiveForApp()

        // Boot Apple's RealityKitScripting runtime once, before any scripted
        // RealityView is rendered (the canonical "Simulate" view). Idempotent.
        try? CanonicalRuntime.initializeOnce()
    }

    var body: some Scene {
        WindowGroup("Deconstructed 3") {
            ContentView()
                .frame(minWidth: 720, minHeight: 480)
        }
        .commands {
            // No document "New" yet — this shell opens existing bundles.
            CommandGroup(replacing: .newItem) {}
        }
    }
}
