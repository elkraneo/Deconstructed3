import Testing
import Foundation
import TMFormat
import RCP3Document
import RCP3Runtime

/// The compiler-backing for the **Examples gallery** (`ScriptGraphExamples`): the
/// same fixtures the editor LOADs and PLAYs, asserted against the canonical
/// `CanonicalScriptGraphCompiler` here so "the tests are visible" — what the gallery
/// shows is exactly what these assert lowers to faithful runtime JS.
///
/// For every `runsToday` example: the whole **wired path** must lower with NO
/// `unsupported` note (an unwired scalar pin lowering to a safe `0` is fine — that is
/// NOT an `unsupported` note), and the emitted handler must have the expected
/// canonical shape (`this.*` hooks, `event.*` gesture reads, `Math.*` / `Math3D`).
///
/// The variable-driven examples (Spin / Sine Bob / Orbit / Squash by Sin / Drag
/// Momentum) carry a LOCAL accumulator name on their Get/Set nodes, which lowers to a
/// stable per-script slot (`this.variable_<slot>`) with no placeholder on the wired
/// path. Rotation examples build a quaternion before writing orientation, so all
/// curated examples run today.
@Suite struct ScriptGraphExamplesCompilerTests {
    static func referenceBundle(named name: String) -> URL? {
        var dir = URL(filePath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            let bundle = dir.appending(path: "references/\(name)")
            if FileManager.default.fileExists(atPath: bundle.appending(path: "world.tm_entity").path) {
                return bundle
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// A runs-today example's wired path must never surface an `unsupported` note.
    /// (`/* unsupported: … */` and `// unsupported node: …` both count.)
    private func expectNoUnsupported(_ js: String, _ name: String) {
        #expect(!js.contains("unsupported"), "\(name) lowered an unsupported note:\n\(js)")
    }

    // MARK: - Gallery invariants

    @Test func galleryHasTheCuratedExamples() {
        let names = ScriptGraphExamples.all.map(\.name)
        // Literal-driven.
        #expect(names.contains("Drag to Move"))
        #expect(names.contains("Drag with Offset"))
        #expect(names.contains("Drift"))
        #expect(names.contains("Tap to Grow"))
        #expect(names.contains("Snap on Add"))
        #expect(names.contains("Squash by Sin"))
        // Local-variable-driven.
        #expect(names.contains("Spin"))
        #expect(names.contains("Sine Bob"))
        #expect(names.contains("Orbit"))
        #expect(names.contains("Drag Momentum"))
        // Cross-system interaction recipes.
        #expect(names.contains("Look At Target"))
        #expect(names.contains("Delayed Move"))
        #expect(names.contains("One-shot Tap"))
        #expect(names.contains("Tap Toggle"))
        #expect(names.contains("Grow by Loop"))
        // Exactly fifteen curated examples, ids unique, lookup works.
        #expect(ScriptGraphExamples.all.count == 15)
        let ids = ScriptGraphExamples.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for example in ScriptGraphExamples.all {
            #expect(ScriptGraphExamples.example(id: example.id)?.name == example.name)
        }
    }

    @Test func everyRunsTodayExampleLowersWithNoUnsupportedNote() {
        for example in ScriptGraphExamples.all where example.runsToday {
            let js = CanonicalScriptGraphCompiler().compile(example.graph)
            expectNoUnsupported(js, example.name)
            // Every runs-today example drives the entity transform on the canonical
            // surface (position / orientation / scale), never the in-house dialect.
            #expect(!js.contains("entity.transform.translation"))
        }
    }

    @Test func everyExampleLowersToALocalSlotNeverARemotePlaceholder() {
        // Every curated example's variable-driven path lowers to a real
        // `this.variable_<slot>` rather than the remote-value placeholder.
        for example in ScriptGraphExamples.all {
            let js = CanonicalScriptGraphCompiler().compile(example.graph)
            expectNoUnsupported(js, example.name)
            #expect(!js.contains("variable name unresolved"), "\(example.name) still has a variable placeholder:\n\(js)")
            #expect(!js.contains("RemoteValue"), "\(example.name) should compile locals to a slot, not RemoteValue:\n\(js)")
        }
    }

    @Test func allCuratedExamplesRunToday() {
        let pending = Set(ScriptGraphExamples.all.filter { !$0.runsToday }.map(\.name))
        #expect(pending.isEmpty)
        #expect(ScriptGraphExamples.all.filter(\.runsToday).count == 15)
    }

    @Test func everyExampleHasAnActionableCertificationManifest() {
        for example in ScriptGraphExamples.all {
            let manifest = example.certification
            #expect(!manifest.capabilities.isEmpty, "\(example.name) has no coverage capabilities")
            #expect(!manifest.expectedOutcome.isEmpty, "\(example.name) has no observable outcome")
            #expect(manifest.manualSteps.count >= 4, "\(example.name) has no complete manual procedure")
            #expect(example.requiredNodeTypes == Set(example.graph.nodes.map(\.type)))
        }
        #expect(Set(ScriptGraphExamples.all.map(\.certification.provenance)).isSuperset(of: [
            .nativeRCP3, .unityPattern, .unrealPattern,
        ]))
        #expect(ScriptGraphExamples.coveredNodeTypes.contains("tm_make_look_at_rotation"))
        #expect(ScriptGraphExamples.coveredNodeTypes.contains("tm_delay"))
        #expect(ScriptGraphExamples.coveredNodeTypes.contains("tm_do_once"))
    }

    @Test func random2CapturedEntityRelativeTransformPathCompiles() throws {
        guard let url = Self.referenceBundle(named: "Random2.realitycomposerpro") else { return }
        let bundle = try RCP3Bundle.open(url)
        let asset = try #require(bundle.scriptGraphAssets().first { $0.name.contains("My Script Graph") })
        let graph = try #require(bundle.scriptGraph(assetID: asset.id))
        let entityPathNodeIDs = Set(
            graph.nodes
                .filter { ["tm_gesture_event_drag", "tm_entity_set_relative_transform"].contains($0.type) }
                .map(\.id)
        )
        let entityPath = RCP3ScriptGraph(
            nodes: graph.nodes.filter { entityPathNodeIDs.contains($0.id) },
            wires: graph.wires.filter { entityPathNodeIDs.contains($0.from) && entityPathNodeIDs.contains($0.to) },
            data: graph.data.filter { entityPathNodeIDs.contains($0.toNode) }
        )

        let js = CanonicalScriptGraphCompiler().compile(entityPath)

        expectNoUnsupported(js, "Random2 entity relative-transform path")
        #expect(js.contains("this.entity.on(RealityKit.DragGestureEvent.name"))
        #expect(js.contains("this.entity.setRelativePosition(event.sceneTranslation, null);"))
    }

    @Test func random2CapturedBillboardAttachPathCompiles() throws {
        guard let url = Self.referenceBundle(named: "Random2.realitycomposerpro") else { return }
        let bundle = try RCP3Bundle.open(url)
        let asset = try #require(bundle.scriptGraphAssets().first { $0.name.contains("My Script Graph") })
        let graph = try #require(bundle.scriptGraph(assetID: asset.id))
        let set = try #require(graph.nodes.first { $0.label == "Set Billboard" })
        let sourceIDs = Set(graph.wires.filter { $0.to == set.id && $0.isExec }.map(\.from))
        let pathNodeIDs = sourceIDs.union([set.id])
        let path = RCP3ScriptGraph(
            nodes: graph.nodes.filter { pathNodeIDs.contains($0.id) },
            wires: graph.wires.filter { pathNodeIDs.contains($0.from) && pathNodeIDs.contains($0.to) },
            data: graph.data.filter { pathNodeIDs.contains($0.toNode) }
        )

        let js = CanonicalScriptGraphCompiler().compile(path)

        expectNoUnsupported(js, "Random2 billboard attach path")
        #expect(js.contains("this.entity.setComponent(new RealityKit.BillboardComponent());"))
    }

    @Test func randomCapturedAccessibilityAttachPathCompiles() throws {
        guard let url = Self.referenceBundle(named: "Random.realitycomposerpro") else { return }
        let bundle = try RCP3Bundle.open(url)
        let box = try #require(
            bundle.root["children"]?.arrayValue?
                .compactMap(\.objectValue)
                .first { $0.name == "box" }
        )
        let graph = try #require(bundle.scriptGraph(forEntity: box))
        let set = try #require(graph.nodes.first { $0.label == "Set Accessibility" })
        let sourceIDs = Set(graph.wires.filter { $0.to == set.id && $0.isExec }.map(\.from))
        let pathNodeIDs = sourceIDs.union([set.id])
        let path = RCP3ScriptGraph(
            nodes: graph.nodes.filter { pathNodeIDs.contains($0.id) },
            wires: graph.wires.filter { pathNodeIDs.contains($0.from) && pathNodeIDs.contains($0.to) },
            data: graph.data.filter { pathNodeIDs.contains($0.toNode) }
        )

        let js = CanonicalScriptGraphCompiler().compile(path)

        expectNoUnsupported(js, "Random accessibility attach path")
        #expect(js.contains("this.entity.setComponent(new RealityKit.AccessibilityComponent());"))
    }

    // MARK: - Runs today: per-example shape

    @Test func dragToMoveIsTheReferenceDragHandler() {
        let js = CanonicalScriptGraphCompiler().compile(ScriptGraphExamples.dragToMove.graph)
        expectNoUnsupported(js, "Drag to Move")
        #expect(js.contains("const RealityKit = require(\"RealityKit\")"))
        #expect(js.contains("const Math3D = require(\"Math3D\")"))
        #expect(js.contains("this.didAdd = function()"))
        #expect(js.contains("this.entity.on(RealityKit.DragGestureEvent.name"))
        // The documented reference wiring: scene-translation moves entity.position.
        #expect(js.contains("Math3D.add(dragStart, event.sceneTranslation)"))
        #expect(js.contains("event.entity.position"))
    }

    @Test func dragWithOffsetAddsAVectorToTheSceneTranslation() {
        let js = CanonicalScriptGraphCompiler().compile(ScriptGraphExamples.dragWithOffset.graph)
        expectNoUnsupported(js, "Drag with Offset")
        #expect(js.contains("this.entity.on(RealityKit.DragGestureEvent.name"))
        // add(sceneTranslation, Vector3(...)) → position. Both operands are VECTORS, so
        // the add lowers to the documented `Math3D.add` (JS `+` is not vector addition),
        // with the Math3D.Vector3 constructor on the wired path. Math3D must be bound.
        #expect(js.contains("const Math3D = require(\"Math3D\")"))
        #expect(js.contains("event.entity.position = Math3D.add(event.sceneTranslation, new Math3D.Vector3("))
        // The baked +0.5 X offset literal lowers into the Vector3.
        #expect(js.contains("new Math3D.Vector3(0.5,"))
    }

    @Test func driftReadsItsOwnPositionViaGetAndAddsDeltaTime() {
        let js = CanonicalScriptGraphCompiler().compile(ScriptGraphExamples.drift.graph)
        expectNoUnsupported(js, "Drift")
        #expect(js.contains("this.update = function(deltaTime)"))
        // Get Transform.translation lowers to the entity's current position (a VECTOR),
        // added to a Vector3 whose X is the per-frame deltaTime. A vector add must lower
        // to `Math3D.add`, not the scalar `+` (which would yield a string / NaN and the
        // box would never move). Math3D must be bound.
        #expect(js.contains("const Math3D = require(\"Math3D\")"))
        #expect(js.contains("this.entity.position = Math3D.add(this.entity.position, new Math3D.Vector3(deltaTime,"))
    }

    @Test func tapToGrowReadsScaleViaGetInsideATapHandler() {
        let js = CanonicalScriptGraphCompiler().compile(ScriptGraphExamples.tapToGrow.graph)
        expectNoUnsupported(js, "Tap to Grow")
        #expect(js.contains("this.entity.on(RealityKit.TapGestureEvent.name"))
        // Get Transform.scale lowers to the entity's current scale (a VECTOR, read via the
        // gesture's event.entity), added to a Vector3 and written back to scale. The
        // vector add lowers to `Math3D.add`, not the scalar `+`. Math3D must be bound.
        #expect(js.contains("const Math3D = require(\"Math3D\")"))
        #expect(js.contains("event.entity.scale = Math3D.add(event.entity.scale, new Math3D.Vector3("))
        // The baked uniform 0.2 growth literals lower into the Vector3.
        #expect(js.contains("new Math3D.Vector3(0.2, 0.2, 0.2)"))
    }

    @Test func snapOnAddSetsPositionFromAVectorInADidAddHook() {
        let js = CanonicalScriptGraphCompiler().compile(ScriptGraphExamples.snapOnAdd.graph)
        expectNoUnsupported(js, "Snap on Add")
        #expect(js.contains("this.didAdd = function()"))
        #expect(js.contains("this.entity.position = new Math3D.Vector3("))
        // The baked (0.3, 0.3, 0) snap coordinates lower into the Vector3.
        #expect(js.contains("this.entity.position = new Math3D.Vector3(0.3, 0.3,"))
    }

    @Test func squashBySinDrivesScaleYFromSinOfAccumulatedTime() {
        let js = CanonicalScriptGraphCompiler().compile(ScriptGraphExamples.squashBySin.graph)
        expectNoUnsupported(js, "Squash by Sin")
        #expect(js.contains("this.update = function(deltaTime)"))
        // It now accumulates `t += deltaTime` on a real local slot (mirroring Sine Bob),
        // and drives the squash from sin(t) — NOT sin(deltaTime) — so it oscillates.
        let t = slot("t")
        #expect(js.contains("this.\(t) = ((this.\(t) ?? 0) + deltaTime);"))
        // sin of the ACCUMULATED time drives the Y component of the scale Vector3, not
        // sin of the per-frame deltaTime.
        #expect(js.contains("Math.sin((this.\(t) ?? 0))"))
        #expect(!js.contains("Math.sin(deltaTime)"))
        #expect(js.contains("this.entity.scale = new Math3D.Vector3("))
        // Baked base (1) + amp (0.5) + unit x/z literals, so scale no longer collapses
        // to (0,0,0) — it scales around 1.
        #expect(js.contains("this.entity.scale = new Math3D.Vector3(1, (1 + (0.5 * Math.sin((this.\(t) ?? 0)))), 1)"))
        #expect(!js.contains("RemoteValue"))
    }

    // MARK: - Local-variable-driven: per-example shape

    /// The slot a LOCAL variable `name` lowers to: `variable_<MurmurHash64A(lowercase)>`
    /// rendered as a decimal `UInt64` — recomputed here from the same hash, never hard-coded.
    private func slot(_ name: String) -> String {
        "variable_\(TMHash.murmur64a(name.lowercased()))"
    }

    @Test func spinAccumulatesAngleViaLocalVariableSlot() {
        let js = CanonicalScriptGraphCompiler().compile(ScriptGraphExamples.spin.graph)
        expectNoUnsupported(js, "Spin")
        #expect(js.contains("this.update = function(deltaTime)"))
        let angle = slot("angle")
        // angle += deltaTime, then orientation from a Y-axis quaternion built from that
        // angle slot.
        #expect(js.contains("this.\(angle) = ((this.\(angle) ?? 0) + deltaTime);"))
        #expect(js.contains("this.entity.orientation = new Math3D.Quaternion((this.\(angle) ?? 0), new Math3D.Vector3(0 /* x unwired */, 1, 0 /* z unwired */));"))
        // Real slot, not the remote placeholder.
        #expect(!js.contains("RemoteValue"))
        #expect(!js.contains("variable name unresolved"))
    }

    @Test func sineBobReadsTFromItsLocalSlotInsideSin() {
        let js = CanonicalScriptGraphCompiler().compile(ScriptGraphExamples.sineBob.graph)
        expectNoUnsupported(js, "Sine Bob")
        #expect(js.contains("this.update = function(deltaTime)"))
        let t = slot("t")
        #expect(js.contains("this.\(t) = ((this.\(t) ?? 0) + deltaTime);"))
        #expect(js.contains("Math.sin((this.\(t) ?? 0))"))
        #expect(js.contains("this.entity.position = new Math3D.Vector3("))
        #expect(!js.contains("RemoteValue"))
    }

    @Test func orbitReadsTFromItsLocalSlotInBothCosAndSin() {
        let js = CanonicalScriptGraphCompiler().compile(ScriptGraphExamples.orbit.graph)
        expectNoUnsupported(js, "Orbit")
        #expect(js.contains("this.update = function(deltaTime)"))
        let t = slot("t")
        #expect(js.contains("Math.cos((this.\(t) ?? 0))"))
        #expect(js.contains("Math.sin((this.\(t) ?? 0))"))
        #expect(js.contains("this.entity.position = new Math3D.Vector3("))
        #expect(!js.contains("RemoteValue"))
    }

    @Test func dragMomentumEmitsBothHandlersOverTwoLocalSlots() {
        let js = CanonicalScriptGraphCompiler().compile(ScriptGraphExamples.dragMomentum.graph)
        expectNoUnsupported(js, "Drag Momentum")
        // Two handlers: a drag kick sets angularVelocity, and a per-frame integrate
        // updates angle and drives rotation — both via real local slots.
        #expect(js.contains("this.entity.on(RealityKit.DragGestureEvent.name"))
        #expect(js.contains("this.update = function(deltaTime)"))
        let vel = slot("angularVelocity")
        let angle = slot("angle")
        // The drag kick writes the velocity slot from a scalar literal.
        #expect(js.contains("this.\(vel) = 0.05;"))
        // The per-frame integrate accumulates angle += angularVelocity over the two slots.
        #expect(js.contains("this.\(angle) = ((this.\(angle) ?? 0) + (this.\(vel) ?? 0));"))
        #expect(js.contains("this.entity.orientation = new Math3D.Quaternion((this.\(angle) ?? 0), new Math3D.Vector3(0 /* x unwired */, 1, 0 /* z unwired */));"))
        #expect(!js.contains("RemoteValue"))
    }
}
