import AppKit
import RCP3Document
import SwiftUI

@main
struct DeconstructedThreeApp: App {
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

/// View model for the open-and-inspect shell. Plain `@Observable` for now; TCA
/// arrives when selection-driven editing lands.
@MainActor
@Observable
final class SceneModel {
    var bundleURL: URL?
    var root: RCP3Entity?
    var selection: RCP3Entity.ID?
    var errorMessage: String?

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a .realitycomposerpro bundle"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    func load(_ url: URL) {
        do {
            let bundle = try RCP3Bundle.open(url)
            bundleURL = url
            root = bundle.entity
            selection = bundle.entity.id
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
            root = nil
            selection = nil
        }
    }

    var selectedEntity: RCP3Entity? {
        guard let root, let selection else { return nil }
        return Self.find(selection, in: root)
    }

    private static func find(_ id: RCP3Entity.ID, in entity: RCP3Entity) -> RCP3Entity? {
        if entity.id == id { return entity }
        for child in entity.children {
            if let found = find(id, in: child) { return found }
        }
        return nil
    }
}
