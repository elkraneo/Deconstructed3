import Foundation
import Testing
import TMFormat

@testable import RCP3GraphEditor
import RCP3Document

/// Tests for the full named-interface parity with RCP 3: each node renders its
/// whole declared pin set (not just the wired pins), with resolved names and
/// exposed literal values, via ``ScriptGraphNodeLibrary`` + ``ScriptGraphFlowBridge``.
@Suite("ScriptGraphNodeLibrary parity")
struct ScriptGraphNodeLibraryTests {

    // MARK: - Library

    @Test("Drag spec declares the full named output set")
    func dragSpecOutputs() throws {
        let spec = try #require(ScriptGraphNodeLibrary.spec(for: "tm_gesture_event_drag"))
        #expect(spec.inputs.isEmpty)
        // One exec output + nine data outputs.
        #expect(spec.outputs.filter(\.isExec).count == 1)
        let dataNames = spec.outputs.filter { !$0.isExec }.map(\.displayName)
        #expect(dataNames == [
            "Entity", "Location", "Start Location", "Translation",
            "Scene Location", "Scene Start Location", "Scene Translation",
            "Scene Input Device Rotation", "Did End",
        ])
    }

    @Test("Palette lists every node type that has a spec, with readable names")
    func paletteItems() throws {
        let items = ScriptGraphNodeLibrary.paletteItems
        #expect(!items.isEmpty)

        // Every palette item maps to a real spec (so inserted nodes have an interface),
        // and id == type.
        for item in items {
            #expect(item.id == item.type)
            #expect(ScriptGraphNodeLibrary.spec(for: item.type) != nil)
        }

        // The known insertable types appear with their curated display names.
        let byType = Dictionary(uniqueKeysWithValues: items.map { ($0.type, $0.displayName) })
        #expect(byType["tm_set_component"] == "Set Component")
        #expect(byType["tm_gesture_event_drag"] == "On Drag")
        #expect(byType["tm_gesture_event_tap"] == "On Tap")

        // Data-driven: one palette item per type that has a spec.
        #expect(items.count == ["tm_set_component", "tm_gesture_event_drag", "tm_gesture_event_tap"].count)
    }

    @Test("Humanized fallback name drops the tm_ prefix and Title Cases the type")
    func humanizedPaletteName() {
        #expect(ScriptGraphNodeLibrary.paletteDisplayName(for: "tm_some_new_node") == "Some New Node")
    }

    @Test("Transform component type resolves by hash")
    func transformTypeName() {
        #expect(ScriptGraphNodeLibrary.componentTypeName(forHash: TMHash.murmur64a("Transform")) == "Transform")
        #expect(TMHash.hex(TMHash.murmur64a("Transform")) == "af53dc359e631774")
        #expect(ScriptGraphNodeLibrary.componentTypeName(forHash: 0xdead_beef) == nil)
    }

    @Test("Transform exposes its four editable properties as data inputs")
    func transformProperties() throws {
        let props = try #require(
            ScriptGraphNodeLibrary.componentProperties(forComponentTypeHash: TMHash.murmur64a("Transform"))
        )
        #expect(props.map(\.displayName) == ["Translation", "Rotation", "Scale", "Matrix"])
        #expect(props.allSatisfy { !$0.isExec })
    }

    // MARK: - Bridge: full On Drag interface

    @Test("On Drag node renders all nine named outputs, wired or not")
    func dragNodeFullInterface() throws {
        let nodes = ScriptGraphFlowBridge.nodes(for: Self.dragToSetGraph())
        let drag = try #require(nodes.first { $0.id == "n1" })

        let outputs = drag.data.outputPins.filter { !$0.isExec }
        #expect(outputs.count >= 9)
        let labels = Set(outputs.map(\.label))
        #expect(labels.contains("Scene Translation"))
        #expect(labels.contains("Entity"))
        #expect(labels.contains("Did End"))

        // The wired output (`sceneTranslation`) shares the hashed handle id, so the
        // data edge still resolves to a declared handle.
        #expect(drag.handles.contains { $0.id == "out." + TMHash.hex(TMHash.murmur64a("sceneTranslation")) })
    }

    // MARK: - Bridge: Set Component interface + exposed values

    @Test("Set Component node renders Source/Component Type + Transform properties with exposed values")
    func setComponentFullInterface() throws {
        let nodes = ScriptGraphFlowBridge.nodes(for: Self.dragToSetGraph())
        let set = try #require(nodes.first { $0.id == "n2" })
        let inputs = set.data.inputPins

        let source = try #require(inputs.first { $0.label == "Source" })
        #expect(source.valueLabel == "(Self)")

        let componentType = try #require(inputs.first { $0.label == "Component Type" })
        #expect(componentType.valueLabel == "Transform")

        // The four Transform properties appear as data inputs.
        let labels = Set(inputs.map(\.label))
        #expect(labels.isSuperset(of: ["Translation", "Rotation", "Scale", "Matrix"]))

        // Set Component is a passthrough — it declares both exec input and output.
        #expect(set.data.pins.contains { $0.isExec && $0.isInput })
        #expect(set.data.pins.contains { $0.isExec && !$0.isInput })
    }

    @Test("Without a component_type literal, no Transform properties are added")
    func setComponentWithoutType() throws {
        // A bare set node with only the exec wire — no component_type literal.
        let n1 = RCP3ScriptGraph.Node(id: "n1", type: "tm_gesture_event_drag")
        let n2 = RCP3ScriptGraph.Node(id: "n2", type: "tm_set_component", label: "Set")
        let exec = RCP3ScriptGraph.Wire(id: "c1", from: "n1", to: "n2")
        let graph = RCP3ScriptGraph(nodes: [n1, n2], wires: [exec], data: [])

        let nodes = ScriptGraphFlowBridge.nodes(for: graph)
        let set = try #require(nodes.first { $0.id == "n2" })
        let labels = Set(set.data.inputPins.map(\.label))
        #expect(labels.contains("Source"))
        #expect(labels.contains("Component Type"))
        #expect(!labels.contains("Rotation"))
        // Component type is unresolved, so it exposes no value.
        let componentType = try #require(set.data.inputPins.first { $0.label == "Component Type" })
        #expect(componentType.valueLabel == nil)
    }

    // MARK: - Integrity

    @Test("Every edge endpoint resolves to an existing handle (no dangling)")
    func noDanglingEdges() {
        let graph = Self.dragToSetGraph()
        let nodes = ScriptGraphFlowBridge.nodes(for: graph)
        let edges = ScriptGraphFlowBridge.edges(for: graph)
        let handlesByNode = Dictionary(
            uniqueKeysWithValues: nodes.map { ($0.id, Set($0.handles.map(\.id))) }
        )
        for edge in edges {
            let sourceHandles = handlesByNode[edge.sourceNodeID]
            #expect(sourceHandles != nil)
            if let sourceHandleID = edge.sourceHandleID {
                #expect(sourceHandles?.contains(sourceHandleID) == true)
            }
            let targetHandles = handlesByNode[edge.targetNodeID]
            #expect(targetHandles != nil)
            if let targetHandleID = edge.targetHandleID {
                #expect(targetHandles?.contains(targetHandleID) == true)
            }
        }
    }

    // MARK: - Optional real-bundle parity (depth-robust skip)

    @Test("Random capture (if present): On Drag + Set Component render full interfaces")
    func realBundleParity() throws {
        guard let url = Self.locateReferenceBundle() else { return }
        let bundle = try RCP3Bundle.open(url)

        var sawDrag = false
        var sawSet = false
        for entity in Self.allEntities(bundle.entity) {
            guard let graph = bundle.scriptGraph(forEntityID: entity.id), !graph.nodes.isEmpty else { continue }
            let nodes = ScriptGraphFlowBridge.nodes(for: graph)

            if let drag = nodes.first(where: { $0.data.type == "tm_gesture_event_drag" }) {
                sawDrag = true
                #expect(drag.data.outputPins.filter { !$0.isExec }.count >= 9)
                #expect(drag.data.outputPins.contains { $0.label == "Scene Translation" })
            }
            if let set = nodes.first(where: { $0.data.type == "tm_set_component" }) {
                sawSet = true
                let labels = Set(set.data.inputPins.map(\.label))
                #expect(labels.contains("Source"))
                #expect(labels.contains("Component Type"))
            }

            // Integrity holds on the real graph too.
            let handlesByNode = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, Set($0.handles.map(\.id))) })
            for edge in ScriptGraphFlowBridge.edges(for: graph) {
                if let h = edge.sourceHandleID { #expect(handlesByNode[edge.sourceNodeID]?.contains(h) == true) }
                if let h = edge.targetHandleID { #expect(handlesByNode[edge.targetNodeID]?.contains(h) == true) }
            }
        }
        _ = (sawDrag, sawSet) // not assertion targets — the capture may differ
    }

    // MARK: - Fixtures

    /// The "drag → set" graph with a `component_type` literal naming `Transform`, so
    /// the set node resolves its component and exposes Transform's property pins.
    static func dragToSetGraph() -> RCP3ScriptGraph {
        let n1 = RCP3ScriptGraph.Node(id: "n1", type: "tm_gesture_event_drag")
        let n2 = RCP3ScriptGraph.Node(id: "n2", type: "tm_set_component", label: "Set Transform")
        let exec = RCP3ScriptGraph.Wire(id: "c1", from: "n1", to: "n2")
        // A data wire from the drag's `sceneTranslation` output into the set's
        // `translation` input (matches the canonical capture).
        let data = RCP3ScriptGraph.Wire(
            id: "c2",
            from: "n1",
            to: "n2",
            fromPin: TMHash.murmur64a("sceneTranslation"),
            toPin: TMHash.murmur64a("translation")
        )
        // The `component_type` literal: its `valueHash` names the Transform component.
        let literal = RCP3ScriptGraph.DataLiteral(
            id: "d1",
            toNode: "n2",
            toPin: TMHash.murmur64a("component_type"),
            valueType: "re_scripting_graph_component_type",
            valueHash: TMHash.murmur64a("Transform")
        )
        return RCP3ScriptGraph(nodes: [n1, n2], wires: [exec, data], data: [literal])
    }

    private static func allEntities(_ root: RCP3Entity) -> [RCP3Entity] {
        var result = [root]
        for child in root.children { result.append(contentsOf: allEntities(child)) }
        return result
    }

    private static func locateReferenceBundle() -> URL? {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let relative = "references/Random.realitycomposerpro"
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}
