import Testing
import RCP3Document
import RCP3Runtime
@testable import RCP3GraphEditor

@Suite struct ScriptGraphExecutableCorpusTests {
    @Test func preservesCoverageAndDeterminism() {
        let minimal = ScriptGraphGeneratedCorpus.all
        let executable = ScriptGraphExecutableCorpus.all
        #expect(executable.map(\.requestedType) == minimal.map(\.requestedType))
        #expect(executable.map { $0.graph.nodes.map(\.id) } ==
                ScriptGraphExecutableCorpus.all.map { $0.graph.nodes.map(\.id) })
    }

    @Test func pureValuesReceiveOneGenericReachabilitySink() throws {
        for item in ScriptGraphExecutableCorpus.all where item.synthesis == .variableSink {
            #expect(item.graph.nodes.contains { $0.type == "tm_update" })
            let sink = try #require(item.graph.nodes.first { $0.type == "tm_set_variable_node" })
            #expect(item.graph.wires.contains { $0.to == sink.id && $0.isExec })
            #expect(item.graph.wires.contains { $0.to == sink.id && !$0.isExec })
            #expect(item.graph.variables.contains { $0.uuid == sink.variableRefUUID })
        }
    }

    @Test func synthesisIsBroadButDoesNotInventOutputs() {
        let counts = ScriptGraphExecutableCorpus.synthesisCounts
        #expect((counts[.variableSink] ?? 0) > 200)
        #expect((counts[.noDataOutput] ?? 0) < 20)
        #expect(counts.values.reduce(0, +) == ScriptGraphGeneratedCorpus.all.count)
    }

    @Test func reportsCompilerReachabilityDelta() {
        let diagnostic = ScriptGraphExecutableCorpus.all.filter {
            CanonicalScriptGraphCompiler().compile($0.graph).contains("unsupported")
        }
        // Baseline evidence only. The generic Double sink is intentionally
        // type-unsafe and this count must not be presented as semantic parity.
        let knownContextGaps: Set<String> = [
            "tm_break_collision_group_number", "tm_break_physically_based_material_blending",
            "tm_break_portal_component_clipping_mode", "tm_break_portal_component_crossing_mode",
            "tm_break_spot_light_component_shadow_shadow_clipping_plane",
            "tm_clear_remote_variable_node", "tm_clear_variable_node", "tm_find_scene_entity",
            "tm_set_component", "tm_spawn_entity", "tm_variable_divide", "tm_variable_multiply",
            "tm_variable_multiply_by_matrix", "tm_variable_multiply_by_quaternion",
            "tm_variable_multiply_by_scalar", "tm_variable_subtract",
        ]
        #expect(diagnostic.count <= 16)
        #expect(Set(diagnostic.map(\.requestedType)).isSubset(of: knownContextGaps))
    }
}
