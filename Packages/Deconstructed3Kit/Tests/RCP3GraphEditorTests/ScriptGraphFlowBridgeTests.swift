import Foundation
import Testing

@testable import RCP3GraphEditor
import RCP3Document

/// Tests for ``ScriptGraphFlowBridge`` — the data bridge that maps an
/// ``RCP3ScriptGraph`` into SwiftFlow's node/edge model.
@Suite("ScriptGraphFlowBridge")
struct ScriptGraphFlowBridgeTests {

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

    // MARK: - Nodes

    @Test("Produces one FlowNode per source node, preserving order")
    func nodeCount() {
        let nodes = ScriptGraphFlowBridge.nodes(for: Self.dragToSetGraph())
        #expect(nodes.count == 2)
        #expect(nodes.map(\.id) == ["n1", "n2"])
    }

    @Test("Roles are classified from the node type")
    func roles() {
        let nodes = ScriptGraphFlowBridge.nodes(for: Self.dragToSetGraph())
        let n1 = try! #require(nodes.first { $0.id == "n1" })
        let n2 = try! #require(nodes.first { $0.id == "n2" })
        #expect(n1.data.role == .event)
        #expect(n2.data.role == .action)
    }

    @Test("Source node declares an exec output and a hashed data output")
    func sourceHandles() {
        let nodes = ScriptGraphFlowBridge.nodes(for: Self.dragToSetGraph())
        let n1 = try! #require(nodes.first { $0.id == "n1" })
        let handleIDs = Set(n1.handles.map(\.id))
        #expect(handleIDs.contains("exec.out"))
        #expect(handleIDs.contains("out." + Self.dragOutputHex))
        // The exec source handle is a `.source` on the right edge.
        let execOut = try! #require(n1.handles.first { $0.id == "exec.out" })
        #expect(execOut.type == .source)
        #expect(execOut.position == .right)
        // n1 only emits, so it should declare no input handles.
        #expect(n1.handles.allSatisfy { $0.type == .source })
    }

    @Test("Target node declares an exec input and a hashed data input")
    func targetHandles() {
        let nodes = ScriptGraphFlowBridge.nodes(for: Self.dragToSetGraph())
        let n2 = try! #require(nodes.first { $0.id == "n2" })
        let handleIDs = Set(n2.handles.map(\.id))
        #expect(handleIDs.contains("exec.in"))
        #expect(handleIDs.contains("in." + Self.translationHex))
        let dataIn = try! #require(n2.handles.first { $0.id == "in." + Self.translationHex })
        #expect(dataIn.type == .target)
        #expect(dataIn.position == .left)
        // n2 only receives, so it should declare no output handles.
        #expect(n2.handles.allSatisfy { $0.type == .target })
    }

    @Test("A node's handles exactly mirror its payload pins")
    func handlesMirrorPins() {
        let nodes = ScriptGraphFlowBridge.nodes(for: Self.dragToSetGraph())
        for node in nodes {
            #expect(node.handles.map(\.id) == node.data.pins.map(\.id))
        }
    }

    @Test("Resolved data-input pin uses the known 'translation' label")
    func pinLabelResolution() {
        let nodes = ScriptGraphFlowBridge.nodes(for: Self.dragToSetGraph())
        let n2 = try! #require(nodes.first { $0.id == "n2" })
        let pin = try! #require(n2.data.pins.first { $0.id == "in." + Self.translationHex })
        #expect(pin.label == "translation")
    }

    // MARK: - Edges

    @Test("Produces one FlowEdge per wire")
    func edgeCount() {
        let edges = ScriptGraphFlowBridge.edges(for: Self.dragToSetGraph())
        #expect(edges.count == 2)
        #expect(Set(edges.map(\.id)) == ["c1", "c2"])
    }

    @Test("Exec and data wires get the right handles and path types")
    func edgeWiring() {
        let edges = ScriptGraphFlowBridge.edges(for: Self.dragToSetGraph())
        let exec = try! #require(edges.first { $0.id == "c1" })
        #expect(exec.sourceNodeID == "n1")
        #expect(exec.sourceHandleID == "exec.out")
        #expect(exec.targetNodeID == "n2")
        #expect(exec.targetHandleID == "exec.in")
        #expect(exec.pathType == .smoothStep)

        let data = try! #require(edges.first { $0.id == "c2" })
        #expect(data.sourceHandleID == "out." + Self.dragOutputHex)
        #expect(data.targetHandleID == "in." + Self.translationHex)
        #expect(data.pathType == .bezier)
    }

    // MARK: - Integrity (the crucial test)

    /// Every edge endpoint must resolve to a real node that actually declares the
    /// referenced handle id — no dangling edges.
    @Test("No edge references a missing node or handle")
    func noDanglingEdges() {
        assertIntegrity(of: Self.dragToSetGraph())
    }

    @Test("Data literals contribute input handles even without a wire")
    func dataLiteralInputs() {
        let n1 = RCP3ScriptGraph.Node(id: "n1", type: "tm_set_component")
        let literal = RCP3ScriptGraph.DataLiteral(id: "d1", toNode: "n1", toPin: Self.translationHash)
        let graph = RCP3ScriptGraph(nodes: [n1], wires: [], data: [literal])
        let nodes = ScriptGraphFlowBridge.nodes(for: graph)
        let node = try! #require(nodes.first)
        #expect(node.handles.contains { $0.id == "in." + Self.translationHex })
    }

    @Test("Wires with a missing endpoint node are skipped")
    func skipsDanglingWire() {
        let n1 = RCP3ScriptGraph.Node(id: "n1", type: "tm_gesture_event_drag")
        // c1's target "ghost" does not exist.
        let exec = RCP3ScriptGraph.Wire(id: "c1", from: "n1", to: "ghost")
        let graph = RCP3ScriptGraph(nodes: [n1], wires: [exec], data: [])
        #expect(ScriptGraphFlowBridge.edges(for: graph).isEmpty)
        assertIntegrity(of: graph)
    }

    @Test("Nodes without explicit positions are laid out by index")
    func fallbackLayout() {
        let n1 = RCP3ScriptGraph.Node(id: "n1", type: "tm_a")
        let n2 = RCP3ScriptGraph.Node(id: "n2", type: "tm_b")
        let nodes = ScriptGraphFlowBridge.nodes(for: RCP3ScriptGraph(nodes: [n1, n2], wires: [], data: []))
        #expect(nodes[0].position.x == 0)
        #expect(Double(nodes[1].position.x) == ScriptGraphFlowBridge.fallbackColumnWidth)
    }

    @Test("Explicit node positions are honored")
    func explicitPosition() {
        let n1 = RCP3ScriptGraph.Node(id: "n1", type: "tm_a", x: 42, y: 17)
        let nodes = ScriptGraphFlowBridge.nodes(for: RCP3ScriptGraph(nodes: [n1], wires: [], data: []))
        #expect(nodes[0].position.x == 42)
        #expect(nodes[0].position.y == 17)
    }

    // MARK: - Store

    @MainActor
    @Test("store(for:) populates nodes and edges with no dangling endpoints")
    func storePopulated() {
        let graph = Self.dragToSetGraph()
        let store = ScriptGraphFlowBridge.store(for: graph)
        #expect(store.nodes.count == 2)
        #expect(store.edges.count == 2)

        // SwiftFlow's `addEdge` silently drops edges whose endpoint nodes are
        // unknown; getting both edges back proves the handles/ids line up.
        let handlesByNode = Dictionary(
            uniqueKeysWithValues: store.nodes.map { ($0.id, Set($0.handles.map(\.id))) }
        )
        for edge in store.edges {
            let sourceHandles = try! #require(handlesByNode[edge.sourceNodeID])
            let targetHandles = try! #require(handlesByNode[edge.targetNodeID])
            #expect(sourceHandles.contains(try! #require(edge.sourceHandleID)))
            #expect(targetHandles.contains(try! #require(edge.targetHandleID)))
        }
    }

    // MARK: - Optional real-bundle integrity

    /// If `references/Random.realitycomposerpro` is reachable from this source
    /// file, load every entity's script graph and assert the same edge/handle
    /// integrity. Skips cleanly when the reference bundle is absent.
    @Test("Real bundle graphs (if present) have no dangling edges")
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

    /// Asserts every edge endpoint resolves to a node that declares the handle.
    private func assertIntegrity(of graph: RCP3ScriptGraph, sourceLocation: SourceLocation = #_sourceLocation) {
        let nodes = ScriptGraphFlowBridge.nodes(for: graph)
        let edges = ScriptGraphFlowBridge.edges(for: graph)
        let handlesByNode = Dictionary(
            uniqueKeysWithValues: nodes.map { ($0.id, Set($0.handles.map(\.id))) }
        )
        for edge in edges {
            let sourceHandles = handlesByNode[edge.sourceNodeID]
            #expect(sourceHandles != nil, "edge \(edge.id): missing source node \(edge.sourceNodeID)", sourceLocation: sourceLocation)
            if let sourceHandleID = edge.sourceHandleID {
                #expect(
                    sourceHandles?.contains(sourceHandleID) == true,
                    "edge \(edge.id): source node \(edge.sourceNodeID) lacks handle \(sourceHandleID)",
                    sourceLocation: sourceLocation
                )
            }
            let targetHandles = handlesByNode[edge.targetNodeID]
            #expect(targetHandles != nil, "edge \(edge.id): missing target node \(edge.targetNodeID)", sourceLocation: sourceLocation)
            if let targetHandleID = edge.targetHandleID {
                #expect(
                    targetHandles?.contains(targetHandleID) == true,
                    "edge \(edge.id): target node \(edge.targetNodeID) lacks handle \(targetHandleID)",
                    sourceLocation: sourceLocation
                )
            }
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
