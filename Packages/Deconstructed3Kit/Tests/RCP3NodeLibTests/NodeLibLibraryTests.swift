import Foundation
import RCP3NodeLib
import Testing

@Suite struct NodeLibLibraryTests {
    private let representative = Data(#"""
    {
      "name": "MyGameLibrary",
      "nodes": [{
        "name": "spawnPlayer",
        "displayName": "Spawn Player",
        "category": "Gameplay",
        "module": "RealityKit",
        "object": "Entity",
        "isPure": false,
        "method": {
          "name": "addChild",
          "type": "instance",
          "parameters": [
            {"name":"arg0","type":"Entity","module":"RealityKit"},
            {"name":"arg1","type":"Bool","module":"PrimitiveTypes"}
          ]
        }
      }],
      "events": [],
      "customTypes": [],
      "types": [],
      "uniqueID": "deconstructed3-certification-nodelib-v1"
    }
    """#.utf8)

    @Test func decodesAndDerivesStaticMethodDeclaration() throws {
        let library = try NodeLibJSONCodec.decode(representative)
        let method = try #require(library.methodDeclarations.first)
        #expect(method.identity == "node_17854906811712824314")
        #expect(method.inputs.map(\.name) == ["arg0", "arg1"])
        #expect(method.outputs.isEmpty)
        #expect(method.hasExecutionFlow)
    }

    @Test func deterministicJSONRoundTrip() throws {
        let library = try NodeLibJSONCodec.decode(representative)
        let encoded = try NodeLibJSONCodec.encode(library)
        #expect(try NodeLibJSONCodec.decode(encoded) == library)
        #expect(encoded.last == 0x0a)
    }
}
