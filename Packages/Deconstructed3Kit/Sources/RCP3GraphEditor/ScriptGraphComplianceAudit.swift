import Foundation
import RCP3Document

/// Deterministic reconciliation of the live authoring surface with harvested and
/// external certification evidence. These tiers intentionally remain separate.
public enum ScriptGraphComplianceAudit {
    public struct Report: Codable, Equatable, Sendable {
        public let cataloguedPublicTypes: [String]
        public let authorableTypes: [String]
        public let cataloguedButNotAuthorable: [String]
        public let authorableButNotCatalogued: [String]
        public let corpusCoveredTypes: [String]
        public let authorableWithoutCorpusScenario: [String]
        public let rcpRoundTripCertifiedTypes: [String]
        public let runtimeVerifiedTypes: [String]
    }

    public static func makeReport(
        cataloguedPublicTypes: Set<String>,
        additionallyAuthorableTypes: Set<String> = [],
        rcpRoundTripCertifiedTypes: Set<String> = [],
        runtimeVerifiedTypes: Set<String> = []
    ) -> Report {
        let palette = Set(ScriptGraphNodeLibrary.paletteItems.map(\.type))
        let recipes = Set(palette.filter { ScriptGraphAuthoringRecipes.recipe(for: $0) != nil })
            .union(additionallyAuthorableTypes)
        let corpus = Set(ScriptGraphExamples.all.flatMap { $0.graph.nodes.map(\.type) })
        return Report(
            cataloguedPublicTypes: cataloguedPublicTypes.sorted(),
            authorableTypes: recipes.sorted(),
            cataloguedButNotAuthorable: cataloguedPublicTypes.subtracting(recipes).sorted(),
            authorableButNotCatalogued: recipes.subtracting(cataloguedPublicTypes).sorted(),
            corpusCoveredTypes: corpus.sorted(),
            authorableWithoutCorpusScenario: recipes.subtracting(corpus).sorted(),
            rcpRoundTripCertifiedTypes: rcpRoundTripCertifiedTypes.sorted(),
            runtimeVerifiedTypes: runtimeVerifiedTypes.sorted()
        )
    }
}
