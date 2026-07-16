import Foundation
import RCP3Document

/// Deterministic reconciliation of the live authoring surface with harvested and
/// external certification evidence. These tiers intentionally remain separate.
public enum ScriptGraphComplianceAudit {
    /// RCP3 metadata identifiers that are not distinct ordinary creator-palette
    /// nodes. Keeping the versioned set explicit prevents metadata-only, internal,
    /// and validation operations from being mistaken for authoring gaps.
    public static let rcp3CataloguedNonCreatorTypes: Set<String> = [
        "tm_begin_test",
        "tm_breakpoint",
        "tm_finish_test",
        "tm_if_breakpoint",
        "tm_log",
        "tm_make_anim_graph_parameter_type",
        "tm_make_keyboard_key_code",
        "tm_make_triangle_fill_mode",
        "tm_math_ease",
        "tm_math_easein",
        "tm_math_easeinout",
        "tm_math_easeout",
        "tm_math_remap",
        "tm_set_test_time_out",
        "tm_test_assert",
        "tm_test_assert_equal",
        "tm_test_undefined",
        "tm_test_update",
    ]

    public struct Report: Codable, Equatable, Sendable {
        public let cataloguedPublicTypes: [String]
        /// Catalogued `tm_*` identifiers that are internal, validation-only,
        /// unavailable in this RCP build, or an alias of a canonical creator node.
        public let cataloguedNonCreatorTypes: [String]
        public let authorableTypes: [String]
        public let cataloguedButNotAuthorable: [String]
        public let authorableButNotCatalogued: [String]
        /// Types exercised by the small, human-designed behavioral gallery.
        public let curatedScenarioCoveredTypes: [String]
        /// Types exercised by deterministic minimal authoring fixtures.
        public let generatedAuthoringCoveredTypes: [String]
        public let corpusCoveredTypes: [String]
        public let authorableWithoutCorpusScenario: [String]
        public let rcpRoundTripCertifiedTypes: [String]
        public let runtimeVerifiedTypes: [String]
    }

    public static func makeReport(
        cataloguedPublicTypes: Set<String>,
        cataloguedNonCreatorTypes: Set<String> = [],
        additionallyAuthorableTypes: Set<String> = [],
        rcpRoundTripCertifiedTypes: Set<String> = [],
        runtimeVerifiedTypes: Set<String> = []
    ) -> Report {
        let creatorCatalog = cataloguedPublicTypes.subtracting(cataloguedNonCreatorTypes)
        let palette = Set(ScriptGraphNodeLibrary.paletteItems.map(\.type))
        let recipes = Set(palette.filter { ScriptGraphAuthoringRecipes.recipe(for: $0) != nil })
            .union(additionallyAuthorableTypes)
        let curated = Set(ScriptGraphExamples.all.flatMap { $0.graph.nodes.map(\.type) })
        let generated = ScriptGraphGeneratedCorpus.coveredRequestedTypes
        let corpus = curated.union(generated)
        return Report(
            cataloguedPublicTypes: creatorCatalog.sorted(),
            cataloguedNonCreatorTypes: cataloguedNonCreatorTypes.sorted(),
            authorableTypes: recipes.sorted(),
            cataloguedButNotAuthorable: creatorCatalog.subtracting(recipes).sorted(),
            authorableButNotCatalogued: recipes.subtracting(creatorCatalog).sorted(),
            curatedScenarioCoveredTypes: curated.sorted(),
            generatedAuthoringCoveredTypes: generated.sorted(),
            corpusCoveredTypes: corpus.sorted(),
            authorableWithoutCorpusScenario: recipes.subtracting(corpus).sorted(),
            rcpRoundTripCertifiedTypes: rcpRoundTripCertifiedTypes.sorted(),
            runtimeVerifiedTypes: runtimeVerifiedTypes.sorted()
        )
    }
}
