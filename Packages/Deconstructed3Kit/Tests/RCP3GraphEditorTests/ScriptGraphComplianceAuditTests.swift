import Testing
@testable import RCP3GraphEditor

@Suite struct ScriptGraphComplianceAuditTests {
    @Test func evidenceTiersRemainIndependentAndSorted() {
        let report = ScriptGraphComplianceAudit.makeReport(
            cataloguedPublicTypes: ["tm_future", "tm_self"],
            additionallyAuthorableTypes: ["tm_material_fixture"],
            rcpRoundTripCertifiedTypes: ["tm_self"],
            runtimeVerifiedTypes: []
        )
        #expect(report.cataloguedButNotAuthorable == ["tm_future"])
        #expect(report.authorableButNotCatalogued.contains("tm_material_fixture"))
        #expect(report.rcpRoundTripCertifiedTypes == ["tm_self"])
        #expect(report.runtimeVerifiedTypes.isEmpty)
        #expect(report.authorableTypes == report.authorableTypes.sorted())
        #expect(report.generatedAuthoringCoveredTypes.count > 300)
        // Explicitly injected authorability evidence has no generated palette case.
        #expect(report.authorableWithoutCorpusScenario == ["tm_material_fixture"])
        #expect(Set(report.corpusCoveredTypes).isSuperset(of: report.curatedScenarioCoveredTypes))
    }
}
