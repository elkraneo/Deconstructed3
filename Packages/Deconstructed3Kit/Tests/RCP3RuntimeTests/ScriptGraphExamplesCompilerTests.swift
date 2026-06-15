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
/// For every needs-variables example: it must compile WITHOUT crashing, emitting the
/// honest `getRemoteValue`/`setRemoteValue` placeholder for the unresolved variable
/// name — it loads + edits today, and runs once variable-name authoring lands.
@Suite struct ScriptGraphExamplesCompilerTests {

    /// A runs-today example's wired path must never surface an `unsupported` note.
    /// (`/* unsupported: … */` and `// unsupported node: …` both count.)
    private func expectNoUnsupported(_ js: String, _ name: String) {
        #expect(!js.contains("unsupported"), "\(name) lowered an unsupported note:\n\(js)")
    }

    // MARK: - Gallery invariants

    @Test func galleryHasTheCuratedExamples() {
        let names = ScriptGraphExamples.all.map(\.name)
        // Runs today.
        #expect(names.contains("Drag to Move"))
        #expect(names.contains("Drag with Offset"))
        #expect(names.contains("Drift"))
        #expect(names.contains("Tap to Grow"))
        #expect(names.contains("Snap on Add"))
        #expect(names.contains("Squash by Sin"))
        // Needs variables.
        #expect(names.contains("Spin"))
        #expect(names.contains("Sine Bob"))
        #expect(names.contains("Orbit"))
        #expect(names.contains("Drag Momentum"))
        // Exactly ten curated examples, ids unique, lookup works.
        #expect(ScriptGraphExamples.all.count == 10)
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

    @Test func everyNeedsVariablesExampleCompilesWithoutCrashing() {
        for example in ScriptGraphExamples.all where !example.runsToday {
            let js = CanonicalScriptGraphCompiler().compile(example.graph)
            // It compiled (produced a non-trivial script) and emitted the honest
            // remote-variable placeholder rather than fabricating a name.
            #expect(!js.isEmpty)
            #expect(js.contains("RemoteValue"))
            #expect(js.contains("variable name unresolved"))
        }
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
        // add(sceneTranslation, Vector3(...)) → position. The infix add + the Math3D
        // Vector3 constructor are both on the wired path.
        #expect(js.contains("event.entity.position = (event.sceneTranslation + new Math3D.Vector3("))
    }

    @Test func driftReadsItsOwnPositionViaGetAndAddsDeltaTime() {
        let js = CanonicalScriptGraphCompiler().compile(ScriptGraphExamples.drift.graph)
        expectNoUnsupported(js, "Drift")
        #expect(js.contains("this.update = function(deltaTime)"))
        // Get Transform.translation lowers to the entity's current position, added to a
        // Vector3 whose X is the per-frame deltaTime.
        #expect(js.contains("this.entity.position = (this.entity.position + new Math3D.Vector3(deltaTime,"))
    }

    @Test func tapToGrowReadsScaleViaGetInsideATapHandler() {
        let js = CanonicalScriptGraphCompiler().compile(ScriptGraphExamples.tapToGrow.graph)
        expectNoUnsupported(js, "Tap to Grow")
        #expect(js.contains("this.entity.on(RealityKit.TapGestureEvent.name"))
        // Get Transform.scale lowers to the entity's current scale (read via the
        // gesture's event.entity), added to a Vector3 and written back to scale.
        #expect(js.contains("event.entity.scale = (event.entity.scale + new Math3D.Vector3("))
    }

    @Test func snapOnAddSetsPositionFromAVectorInADidAddHook() {
        let js = CanonicalScriptGraphCompiler().compile(ScriptGraphExamples.snapOnAdd.graph)
        expectNoUnsupported(js, "Snap on Add")
        #expect(js.contains("this.didAdd = function()"))
        #expect(js.contains("this.entity.position = new Math3D.Vector3("))
    }

    @Test func squashBySinDrivesScaleYFromSinOfDeltaTime() {
        let js = CanonicalScriptGraphCompiler().compile(ScriptGraphExamples.squashBySin.graph)
        expectNoUnsupported(js, "Squash by Sin")
        #expect(js.contains("this.update = function(deltaTime)"))
        // sin(deltaTime) drives the Y component of the scale Vector3.
        #expect(js.contains("Math.sin(deltaTime)"))
        #expect(js.contains("this.entity.scale = new Math3D.Vector3("))
    }

    // MARK: - Needs variables: per-example shape

    @Test func spinAccumulatesAngleViaRemoteVariablePlaceholders() {
        let js = CanonicalScriptGraphCompiler().compile(ScriptGraphExamples.spin.graph)
        #expect(js.contains("this.update = function(deltaTime)"))
        // $angle += deltaTime, then orientation from $angle — both via the honest
        // unresolved-name remote placeholder (the name lives in node settings).
        #expect(js.contains("this.setRemoteValue(/* variable name unresolved */ \"\", (this.getRemoteValue(/* variable name unresolved */ \"\") + deltaTime))"))
        #expect(js.contains("this.entity.orientation = this.getRemoteValue("))
    }

    @Test func sineBobReadsTViaRemotePlaceholderInsideSin() {
        let js = CanonicalScriptGraphCompiler().compile(ScriptGraphExamples.sineBob.graph)
        #expect(js.contains("this.update = function(deltaTime)"))
        #expect(js.contains("Math.sin(this.getRemoteValue("))
        #expect(js.contains("this.entity.position = new Math3D.Vector3("))
    }

    @Test func orbitReadsTViaRemotePlaceholderInBothCosAndSin() {
        let js = CanonicalScriptGraphCompiler().compile(ScriptGraphExamples.orbit.graph)
        #expect(js.contains("this.update = function(deltaTime)"))
        #expect(js.contains("Math.cos(this.getRemoteValue("))
        #expect(js.contains("Math.sin(this.getRemoteValue("))
        #expect(js.contains("this.entity.position = new Math3D.Vector3("))
    }

    @Test func dragMomentumEmitsBothADragAndAnUpdateHandler() {
        let js = CanonicalScriptGraphCompiler().compile(ScriptGraphExamples.dragMomentum.graph)
        // Two handlers: a drag kick sets $angVel, and a per-frame integrate updates
        // $angle and drives rotation — both through the remote-variable placeholder.
        #expect(js.contains("this.entity.on(RealityKit.DragGestureEvent.name"))
        #expect(js.contains("this.update = function(deltaTime)"))
        #expect(js.contains("this.setRemoteValue(/* variable name unresolved */ \"\", event.sceneTranslation)"))
        #expect(js.contains("this.entity.orientation = this.getRemoteValue("))
    }
}
