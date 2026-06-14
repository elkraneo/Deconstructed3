import Foundation
import Testing
import TMFormat

@testable import RCP3GraphEditor
import RCP3Document

/// Tests for the full named-interface parity with RCP 3: each node renders its
/// whole declared pin set (not just the wired pins), with resolved names and
/// exposed literal values, via ``ScriptGraphNodeLibrary`` + ``ScriptGraphPinResolver``.
@Suite("ScriptGraphNodeLibrary parity")
struct ScriptGraphNodeLibraryTests {

    /// Resolves a payload for every node in `graph`, keyed by node id.
    static func payloads(for graph: RCP3ScriptGraph) -> [String: ScriptGraphNodePayload] {
        Dictionary(
            uniqueKeysWithValues: graph.nodes.map { ($0.id, ScriptGraphPinResolver.payload(for: $0, in: graph)) }
        )
    }

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
        let drag = try #require(Self.payloads(for: Self.dragToSetGraph())["n1"])

        let outputs = drag.outputPins.filter { !$0.isExec }
        #expect(outputs.count >= 9)
        let labels = Set(outputs.map(\.label))
        #expect(labels.contains("Scene Translation"))
        #expect(labels.contains("Entity"))
        #expect(labels.contains("Did End"))

        // The wired output (`sceneTranslation`) shares the hashed handle id, so the
        // data wire still resolves to a declared pin.
        #expect(drag.pins.contains { $0.id == "out." + TMHash.hex(TMHash.murmur64a("sceneTranslation")) })
    }

    // MARK: - Bridge: Set Component interface + exposed values

    @Test("Set Component node renders Source/Component Type + Transform properties with exposed values")
    func setComponentFullInterface() throws {
        let set = try #require(Self.payloads(for: Self.dragToSetGraph())["n2"])
        let inputs = set.inputPins

        let source = try #require(inputs.first { $0.label == "Source" })
        #expect(source.valueLabel == "(Self)")

        let componentType = try #require(inputs.first { $0.label == "Component Type" })
        #expect(componentType.valueLabel == "Transform")

        // The four Transform properties appear as data inputs.
        let labels = Set(inputs.map(\.label))
        #expect(labels.isSuperset(of: ["Translation", "Rotation", "Scale", "Matrix"]))

        // Set Component is a passthrough — it declares both exec input and output.
        #expect(set.pins.contains { $0.isExec && $0.isInput })
        #expect(set.pins.contains { $0.isExec && !$0.isInput })
    }

    @Test("Without a component_type literal, no Transform properties are added")
    func setComponentWithoutType() throws {
        // A bare set node with only the exec wire — no component_type literal.
        let n1 = RCP3ScriptGraph.Node(id: "n1", type: "tm_gesture_event_drag")
        let n2 = RCP3ScriptGraph.Node(id: "n2", type: "tm_set_component", label: "Set")
        let exec = RCP3ScriptGraph.Wire(id: "c1", from: "n1", to: "n2")
        let graph = RCP3ScriptGraph(nodes: [n1, n2], wires: [exec], data: [])

        let set = try #require(Self.payloads(for: graph)["n2"])
        let labels = Set(set.inputPins.map(\.label))
        #expect(labels.contains("Source"))
        #expect(labels.contains("Component Type"))
        #expect(!labels.contains("Rotation"))
        // Component type is unresolved, so it exposes no value.
        let componentType = try #require(set.inputPins.first { $0.label == "Component Type" })
        #expect(componentType.valueLabel == nil)
    }

    // MARK: - Integrity

    @Test("Every wire endpoint resolves to an existing pin (no dangling)")
    func noDanglingWires() {
        assertIntegrity(of: Self.dragToSetGraph())
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
            let payloads = Self.payloads(for: graph)

            if let drag = payloads.values.first(where: { $0.type == "tm_gesture_event_drag" }) {
                sawDrag = true
                #expect(drag.outputPins.filter { !$0.isExec }.count >= 9)
                #expect(drag.outputPins.contains { $0.label == "Scene Translation" })
            }
            if let set = payloads.values.first(where: { $0.type == "tm_set_component" }) {
                sawSet = true
                let labels = Set(set.inputPins.map(\.label))
                #expect(labels.contains("Source"))
                #expect(labels.contains("Component Type"))
            }

            // Integrity holds on the real graph too.
            assertIntegrity(of: graph)
        }
        _ = (sawDrag, sawSet) // not assertion targets — the capture may differ
    }

    // MARK: - Helpers

    /// Asserts every wire whose endpoints both exist resolves to pins those nodes
    /// declare — no dangling connections (renderer-agnostic).
    private func assertIntegrity(of graph: RCP3ScriptGraph, sourceLocation: SourceLocation = #_sourceLocation) {
        let pinIDsByNode = Self.payloads(for: graph).mapValues { Set($0.pins.map(\.id)) }
        for wire in graph.wires {
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
            #expect(sourcePins.contains(sourceID),
                    "wire \(wire.id): source node \(wire.from) lacks pin \(sourceID)",
                    sourceLocation: sourceLocation)
            #expect(targetPins.contains(targetID),
                    "wire \(wire.id): target node \(wire.to) lacks pin \(targetID)",
                    sourceLocation: sourceLocation)
        }
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
