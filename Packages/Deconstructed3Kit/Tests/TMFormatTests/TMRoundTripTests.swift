import Testing
import Foundation
import TMFormat

@Suite struct TMRoundTripTests {
    @Test func roundTripsSyntheticSceneSemantically() throws {
        let text = """
        __type: "tm_entity"
        name: "world"
        components: [
          { __type: "tm_transform_component"  local_scale: { __uuid: "s1" } }
        ]
        children: [
          { __prototype_type: "tm_entity"  __prototype_uuid: "05fe482f"  name: "box" }
        ]
        g: -9.8100004196166992
        flag: true
        tag: bareword
        """
        let original = try TM.parse(text)
        let reparsed = try TM.parse(original.tmText())
        #expect(reparsed == original)
    }

    @Test func roundTripsTopLevelArraySemantically() throws {
        let text = """
        [
          { name: "A"  properties: [ { type: "string" } ] }
          { name: "B" }
        ]
        """
        let original = try TM.parse(text)
        #expect(try TM.parse(original.tmText()) == original)
    }

    /// The real `world.tm_entity` from the workspace `Empty` capture, if present.
    static var worldEntityURL: URL? {
        referencesDir()?.appending(path: "Empty/Empty.realitycomposerpro/world.tm_entity")
    }

    static func referencesDir() -> URL? {
        var dir = URL(filePath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            let refs = dir.appending(path: "references")
            if FileManager.default.fileExists(atPath: refs.appending(path: "Empty/Empty.realitycomposerpro").path) {
                return refs
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    @Test func roundTripsRealWorldEntitySemantically() throws {
        guard let url = Self.worldEntityURL else { return } // capture not present
        let original = try TM.parse(String(contentsOf: url, encoding: .utf8))
        let reparsed = try TM.parse(original.tmText())
        #expect(reparsed == original)
    }
}
