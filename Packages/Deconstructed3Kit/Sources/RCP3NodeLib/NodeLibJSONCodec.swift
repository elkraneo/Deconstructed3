import Foundation

public enum NodeLibJSONCodec {
    public static func decode(_ data: Data) throws -> NodeLibLibrary {
        try JSONDecoder().decode(NodeLibLibrary.self, from: data)
    }

    public static func encode(_ library: NodeLibLibrary) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(library)
        data.append(0x0a)
        return data
    }
}
