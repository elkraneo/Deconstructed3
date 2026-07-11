import Testing
import RCP3Document
@testable import RCP3GraphEditor

@Suite struct ScriptGraphGeneratedCorpusTests {
    @Test func coversEveryAuthorablePaletteTypeExactlyOnce() {
        let expected = Set(ScriptGraphNodeLibrary.paletteItems.compactMap { item in
            ScriptGraphAuthoringRecipes.recipe(for: item.type).map { _ in item.type }
        })
        let cases = ScriptGraphGeneratedCorpus.all

        #expect(Set(cases.map(\.requestedType)) == expected)
        #expect(Set(cases.map(\.id)).count == cases.count)
        #expect(Set(cases.map(\.requestedType)).count == cases.count)
        #expect(cases.count > 300)
    }

    @Test func generationIsStableAndEveryFixtureHasItsAuthoredSubject() {
        let first = ScriptGraphGeneratedCorpus.all
        let second = ScriptGraphGeneratedCorpus.all
        #expect(first.map(\.id) == second.map(\.id))
        #expect(first.map { $0.graph.nodes.map(\.id) } == second.map { $0.graph.nodes.map(\.id) })

        for item in first {
            #expect(item.graph.id == item.id)
            #expect(item.graph.nodes.contains { $0.type == item.authoredType })
            #expect(item.graph.nodes.count == (item.topology == .action || item.topology == .scoped ? 2 : 1))
            #expect(item.graph.wires.count == (item.topology == .action || item.topology == .scoped ? 1 : 0))
        }
    }

    @Test func familiesRemainBrowsableAndBounded() {
        let categories = Set(ScriptGraphGeneratedCorpus.all.map(\.category))
        #expect(categories.count >= 8)
        for category in categories {
            let family = ScriptGraphGeneratedCorpus.cases(in: category)
            #expect(!family.isEmpty)
            #expect(family.allSatisfy { $0.category == category })
        }
    }
}
