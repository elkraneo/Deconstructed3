import Foundation
import RCP3Document
import TMFormat

/// Mechanically adds reachability context to the minimal authoring corpus.
///
/// This is compiler/preview evidence only. Connecting a value to a generic local
/// variable proves that the lowering path is reachable; it does not prove that
/// the chosen value type is semantically valid in RCP or RKS.
public enum ScriptGraphExecutableCorpus {
    /// Extra authoring identity that a mechanically exec-connected node still needs
    /// before its runtime behavior is meaningful.  Keeping this separate from
    /// `Synthesis` prevents an intentionally context-free audit fixture from being
    /// counted as a compiler-lowering failure.
    public enum RequiredContext: String, Sendable {
        case none
        case remoteVariableReference
        case componentMutation
    }

    public enum Synthesis: String, Sendable {
        case alreadyExecutable
        case variableSink
        case noDataOutput
    }

    public struct Case: Identifiable, Sendable {
        public let id: String
        public let requestedType: String
        public let synthesis: Synthesis
        public let requiredContext: RequiredContext
        public let graph: RCP3ScriptGraph
    }

    public static let all: [Case] = ScriptGraphGeneratedCorpus.all.map(makeCase)

    public static var synthesisCounts: [Synthesis: Int] {
        Dictionary(grouping: all, by: \.synthesis).mapValues(\.count)
    }

    private static func makeCase(_ item: ScriptGraphGeneratedCorpus.Case) -> Case {
        let requiredContext: RequiredContext = switch item.requestedType {
        case "tm_get_remote_variable_node", "tm_set_remote_variable_node",
             "tm_clear_remote_variable_node":
            .remoteVariableReference
        case "tm_set_component":
            .componentMutation
        default:
            .none
        }
        guard item.topology == .pure,
              let subject = item.graph.nodes.first(where: { $0.type == item.authoredType })
        else {
            return Case(id: item.id, requestedType: item.requestedType,
                        synthesis: .alreadyExecutable, requiredContext: requiredContext,
                        graph: item.graph)
        }

        let output = ScriptGraphPinResolver.pins(for: subject, in: item.graph)
            .first { !$0.isInput && !$0.isExec && $0.id.hasPrefix("out.") }
        guard let output,
              let outputHash = UInt64(output.id.dropFirst(4), radix: 16)
        else {
            return Case(id: item.id, requestedType: item.requestedType,
                        synthesis: .noDataOutput, requiredContext: requiredContext,
                        graph: item.graph)
        }

        func uuid(_ role: String) -> String {
            let a = TMHash.hex(TMHash.murmur64a("executable|\(item.requestedType)|\(role)"))
            let b = TMHash.hex(TMHash.murmur64a("uuid|executable|\(item.requestedType)|\(role)"))
            let hex = a + b
            return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        }

        let variableName = "Observed \(item.requestedType)"
        let variableID = uuid("variable")
        let update = RCP3ScriptGraph.Node(id: uuid("update"), type: "tm_update", label: "Evidence Start")
        let sink = RCP3ScriptGraph.Node(
            id: uuid("sink"), type: "tm_set_variable_node", label: "Evidence Sink",
            variableName: variableName, variableRefUUID: variableID
        )
        let variable = RCP3ScriptGraph.Variable(
            uuid: variableID, name: variableName,
            typeHash: 0x3c2f3d0fe92dd9a0, editHash: 0x0ef2dd9a55accbe4,
            dataType: "tm_double"
        )
        let graph = RCP3ScriptGraph(
            id: "executable.\(item.requestedType)",
            nodes: item.graph.nodes + [update, sink],
            wires: item.graph.wires + [
                .init(id: uuid("exec"), from: update.id, to: sink.id),
                .init(id: uuid("value"), from: subject.id, to: sink.id,
                      fromPin: outputHash, toPin: TMHash.murmur64a("value")),
            ],
            data: item.graph.data,
            variables: item.graph.variables + [variable]
        )
        return Case(id: item.id, requestedType: item.requestedType,
                    synthesis: .variableSink, requiredContext: requiredContext, graph: graph)
    }
}
