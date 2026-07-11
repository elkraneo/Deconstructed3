import Foundation
import RCP3Document
import TMFormat

/// Deterministic, mechanically generated authoring fixtures for the complete live
/// Script Graph palette.
///
/// These fixtures are deliberately not added to the Examples gallery: a generated
/// one-node graph proves that a recipe can produce a concrete, serializable node
/// interface, while a curated example proves useful end-to-end behavior. Keeping
/// those evidence tiers separate lets the broad authoring surface grow without
/// pretending that hundreds of nodes have received manual runtime certification.
public enum ScriptGraphGeneratedCorpus {
    public struct Case: Identifiable, Sendable {
        public let id: String
        public let requestedType: String
        public let authoredType: String
        public let displayName: String
        public let category: ScriptGraphNodeLibrary.Category
        public let topology: ScriptGraphAuthoringRecipe.Topology
        public let graph: RCP3ScriptGraph
    }

    /// One minimal fixture for every palette type with a concrete authoring recipe.
    /// Ordering and every graph/node/wire UUID are stable across processes.
    public static let all: [Case] = ScriptGraphNodeLibrary.paletteItems
        .compactMap(makeCase)
        .sorted {
            ($0.category.order, $0.displayName, $0.requestedType) <
                ($1.category.order, $1.displayName, $1.requestedType)
        }

    public static var coveredRequestedTypes: Set<String> {
        Set(all.map(\.requestedType))
    }

    public static func cases(in category: ScriptGraphNodeLibrary.Category) -> [Case] {
        all.filter { $0.category == category }
    }

    private static func makeCase(_ item: ScriptGraphNodeLibrary.PaletteItem) -> Case? {
        guard let recipe = ScriptGraphAuthoringRecipes.recipe(for: item.type) else { return nil }
        var ordinal = 0
        let nextUUID = {
            defer { ordinal += 1 }
            return deterministicUUID(namespace: item.type, ordinal: ordinal)
        }
        guard let graph = ScriptGraphAuthoringRecipes.makeGraph(
            requestedType: item.type,
            label: item.displayName,
            graphID: "generated.\(item.type)",
            makeUUID: nextUUID
        ) else { return nil }
        return Case(
            id: "generated.\(item.type)",
            requestedType: item.type,
            authoredType: recipe.authoredType,
            displayName: item.displayName,
            category: item.category,
            topology: recipe.topology,
            graph: graph
        )
    }

    private static func deterministicUUID(namespace: String, ordinal: Int) -> String {
        let first = TMHash.hex(TMHash.murmur64a("generated|\(namespace)|\(ordinal)"))
        let second = TMHash.hex(TMHash.murmur64a("uuid|generated|\(namespace)|\(ordinal)"))
        let hex = first + second
        return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
    }
}
