import Testing
import Foundation
import RCP3Document

@Suite struct RCP3BundleTests {
    /// The workspace-local `Empty` capture, if present. Captures live outside the
    /// OSS package (in `../../references/`), so these tests no-op cleanly when the
    /// capture is absent — keeping the package green standalone.
    static var emptyBundleURL: URL? {
        let container = URL(filePath: #filePath)
            .deletingLastPathComponent()  // RCP3DocumentTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
            .deletingLastPathComponent()  // source
            .deletingLastPathComponent()  // Deconstructed3 container
        let url = container.appending(path: "references/Empty/Empty.realitycomposerpro")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @Test func opensEmptyWithBox() throws {
        guard let url = Self.emptyBundleURL else { return } // capture not present
        let bundle = try RCP3Bundle.open(url)

        let world = bundle.entity
        #expect(world.name == "world")

        let box = try #require(world.children.first { $0.name == "box" })
        #expect(box.prototypeUUID == "05fe482f-df58-c56a-fa4b-ddf77c8dcfa0")

        if let typeCount = bundle.typeCount {
            #expect(typeCount > 0)
        }
    }
}
