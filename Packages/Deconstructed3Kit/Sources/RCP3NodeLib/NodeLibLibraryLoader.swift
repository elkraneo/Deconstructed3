import Foundation

public enum NodeLibLibraryLoader {
    /// Discovers portable NodeLib resources bundled beside an RCP project or in
    /// an agent/web workspace. RCP itself does not expose a UI importer for these
    /// files; discovery here feeds the portable catalogue and editor registry.
    public static func loadLibraries(in directory: URL) throws -> [NodeLibLibrary] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var libraries: [(URL, NodeLibLibrary)] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasSuffix(".nodelib.njson") else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            libraries.append((url, try NodeLibJSONCodec.decode(Data(contentsOf: url))))
        }
        return libraries.sorted { $0.0.path < $1.0.path }.map(\.1)
    }
}
