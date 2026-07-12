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
        let contextual = ScriptGraphExecutableCorpus.all.filter {
            $0.requiredContext != .none
        }
        #expect(contextual.contains {
            $0.requestedType == "tm_clear_remote_variable_node" &&
            $0.requiredContext == .remoteVariableReference
        })
        #expect(contextual.contains {
            $0.requestedType == "tm_set_component" &&
            $0.requiredContext == .componentMutation
        })

        let diagnostic = ScriptGraphExecutableCorpus.all.filter {
            $0.requiredContext == .none &&
            $0.synthesis != .noDataOutput &&
            CanonicalScriptGraphCompiler().compile($0.graph).contains("unsupported")
        }
        // This proves compiler reachability for mechanically observable fixtures,
        // not semantic RCP/runtime certification. Cases requiring an identity or
        // concrete mutation are accounted by `requiredContext` above; valid pure
        // nodes with no selected-case output are accounted by `.noDataOutput`.
        #expect(diagnostic.isEmpty)
    }
}
