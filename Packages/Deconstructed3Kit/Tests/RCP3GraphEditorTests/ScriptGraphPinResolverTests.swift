import Foundation
import Testing

@testable import RCP3GraphEditor
import RCP3Document

/// Tests for ``ScriptGraphPinResolver`` — the renderer-agnostic derivation that maps
/// an ``RCP3ScriptGraph`` node onto its ``ScriptGraphNodePayload`` (pins + roles +
/// exposed values), and the stable handle-ids wires reference.
@Suite("ScriptGraphPinResolver")
struct ScriptGraphPinResolverTests {

    // `murmur64a("translation")`, confirmed against real captures and reproduced
    // here as a literal so the test target needs no `TMFormat` dependency. See
    // `TMFormat.TMHash` doc-comment anchors: `translation == 0x3e132861ebce0169`.
    static let translationHash: UInt64 = 0x3e13_2861_ebce_0169
    static let translationHex = "3e132861ebce0169"
    // An arbitrary output pin hash used by the canonical graph.
    static let dragOutputHash: UInt64 = 0x4f98_0d17_0a59_f903
    static let dragOutputHex = "4f980d170a59f903"

    /// The canonical "drag → set" graph: a drag event whose exec output and a data
    /// output both feed a `Set Transform` action.
    static func dragToSetGraph() -> RCP3ScriptGraph {
        let n1 = RCP3ScriptGraph.Node(id: "n1", type: "tm_gesture_event_drag")
        let n2 = RCP3ScriptGraph.Node(id: "n2", type: "tm_set_component", label: "Set Transform")
        let exec = RCP3ScriptGraph.Wire(id: "c1", from: "n1", to: "n2")
        let data = RCP3ScriptGraph.Wire(
            id: "c2",
            from: "n1",
            to: "n2",
            fromPin: dragOutputHash,
            toPin: translationHash
        )
        return RCP3ScriptGraph(nodes: [n1, n2], wires: [exec, data], data: [])
    }

    /// Resolves a payload for every node in `graph`, keyed by node id.
    static func payloads(for graph: RCP3ScriptGraph) -> [String: ScriptGraphNodePayload] {
        Dictionary(
            uniqueKeysWithValues: graph.nodes.map { ($0.id, ScriptGraphPinResolver.payload(for: $0, in: graph)) }
        )
    }

    // MARK: - Payloads

    /// One payload per source node, with the role classified from the type.
    @Test("Resolves a payload per node with roles classified from the type")
    func payloadRoles() {
        let payloads = Self.payloads(for: Self.dragToSetGraph())
        let n1 = try! #require(payloads["n1"])
        let n2 = try! #require(payloads["n2"])
        #expect(n1.role == .event)
        #expect(n2.role == .action)
    }

    @Test("Source node declares an exec output and a hashed data output")
    func sourcePins() {
        let n1 = try! #require(Self.payloads(for: Self.dragToSetGraph())["n1"])
        let pinIDs = Set(n1.pins.map(\.id))
        #expect(pinIDs.contains("exec.out"))
        #expect(pinIDs.contains("out." + Self.dragOutputHex))
        // n1 only emits, so it declares no input pins.
        #expect(n1.pins.allSatisfy { !$0.isInput })
    }

    @Test("Target node declares an exec input and a hashed data input")
    func targetPins() {
        let n2 = try! #require(Self.payloads(for: Self.dragToSetGraph())["n2"])
        let pinIDs = Set(n2.pins.map(\.id))
        #expect(pinIDs.contains("exec.in"))
        #expect(pinIDs.contains("in." + Self.translationHex))
        let dataIn = try! #require(n2.pins.first { $0.id == "in." + Self.translationHex })
        #expect(dataIn.isInput)
        #expect(!dataIn.isExec)
    }

    @Test("Resolved data-input pin uses the known 'translation' label")
    func pinLabelResolution() {
        let n2 = try! #require(Self.payloads(for: Self.dragToSetGraph())["n2"])
        let pin = try! #require(n2.pins.first { $0.id == "in." + Self.translationHex })
        #expect(pin.label == "translation")
    }

    @Test("Data literals contribute input pins even without a wire")
    func dataLiteralInputs() {
        let n1 = RCP3ScriptGraph.Node(id: "n1", type: "tm_set_component")
        let literal = RCP3ScriptGraph.DataLiteral(id: "d1", toNode: "n1", toPin: Self.translationHash)
        let graph = RCP3ScriptGraph(nodes: [n1], wires: [], data: [literal])
        let payload = ScriptGraphPinResolver.payload(for: n1, in: graph)
        #expect(payload.pins.contains { $0.id == "in." + Self.translationHex })
    }

    // MARK: - Handle ids

    @Test("Handle-id helpers form the stable pin ids wires reference")
    func handleIDHelpers() {
        #expect(ScriptGraphPinResolver.execInHandleID == "exec.in")
        #expect(ScriptGraphPinResolver.execOutHandleID == "exec.out")
        #expect(ScriptGraphPinResolver.inputHandleID(forHash: Self.translationHash) == "in." + Self.translationHex)
        #expect(ScriptGraphPinResolver.outputHandleID(forHash: Self.dragOutputHash) == "out." + Self.dragOutputHex)
        #expect(ScriptGraphPinResolver.hex(Self.translationHash) == Self.translationHex)
    }

    // MARK: - Integrity (the crucial test)

    /// Every wire endpoint must resolve to a pin its endpoint node actually declares
    /// — no dangling connections. This reproduces, renderer-agnostically, the old
    /// "no edge references a missing handle" guarantee.
    @Test("No wire references a missing node or pin")
    func noDanglingWires() {
        assertIntegrity(of: Self.dragToSetGraph())
    }

    @Test("Wires with a missing endpoint node are skipped")
    func skipsDanglingWire() {
        let n1 = RCP3ScriptGraph.Node(id: "n1", type: "tm_gesture_event_drag")
        // c1's target "ghost" does not exist; integrity only checks present nodes.
        let exec = RCP3ScriptGraph.Wire(id: "c1", from: "n1", to: "ghost")
        let graph = RCP3ScriptGraph(nodes: [n1], wires: [exec], data: [])
        assertIntegrity(of: graph)
    }

    // MARK: - Optional real-bundle integrity

    /// If `references/Random.realitycomposerpro` is reachable from this source
    /// file, load every entity's script graph and assert the same wire/pin
    /// integrity. Skips cleanly when the reference bundle is absent.
    @Test("Real bundle graphs (if present) have no dangling wires")
    func realBundleIntegrity() throws {
        guard let bundleURL = Self.locateReferenceBundle() else { return }
        let bundle = try RCP3Bundle.open(bundleURL)

        var checkedAny = false
        for entity in Self.allEntities(bundle.entity) {
            guard let graph = bundle.scriptGraph(forEntityID: entity.id),
                  !graph.nodes.isEmpty else { continue }
            checkedAny = true
            assertIntegrity(of: graph)
        }
        // Not an assertion target — the bundle may simply contain no graphs.
        _ = checkedAny
    }

    // MARK: - Helpers

    /// Asserts every wire whose endpoints both exist resolves to pins those nodes
    /// declare. Exec wires use the fixed exec ids; data wires use the hashed ids.
    private func assertIntegrity(of graph: RCP3ScriptGraph, sourceLocation: SourceLocation = #_sourceLocation) {
        let payloads = Self.payloads(for: graph)
        let pinIDsByNode = payloads.mapValues { Set($0.pins.map(\.id)) }

        for wire in graph.wires {
            // Only present-node wires are renderable; missing endpoints are skipped
            // by the model and carry no integrity obligation.
            guard let sourcePins = pinIDsByNode[wire.from],
                  let targetPins = pinIDsByNode[wire.to] else { continue }

            let sourceID: String
            let targetID: String
            if wire.isExec {
                sourceID = ScriptGraphPinResolver.execOutHandleID
                targetID = ScriptGraphPinResolver.execInHandleID
            } else {
                guard let fromPin = wire.fromPin, let toPin = wire.toPin else { continue }
                sourceID = ScriptGraphPinResolver.outputHandleID(forHash: fromPin)
                targetID = ScriptGraphPinResolver.inputHandleID(forHash: toPin)
            }

            #expect(
                sourcePins.contains(sourceID),
                "wire \(wire.id): source node \(wire.from) lacks pin \(sourceID)",
                sourceLocation: sourceLocation
            )
            #expect(
                targetPins.contains(targetID),
                "wire \(wire.id): target node \(wire.to) lacks pin \(targetID)",
                sourceLocation: sourceLocation
            )
        }
    }

    /// Flattens an entity tree into a depth-first list.
    private static func allEntities(_ root: RCP3Entity) -> [RCP3Entity] {
        var result = [root]
        for child in root.children {
            result.append(contentsOf: allEntities(child))
        }
        return result
    }

    /// Walks up from this source file (depth-robust, ~12 levels) looking for
    /// `references/Random.realitycomposerpro`. Returns `nil` when absent.
    private static func locateReferenceBundle() -> URL? {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let relative = "references/Random.realitycomposerpro"
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}
