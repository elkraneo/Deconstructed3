import Testing
import Foundation
import TMFormat
import RCP3Document

/// Faithful entity-transform editing + save, proved against a real RCP3
/// before/after capture (`Random3 (base)` → `Random3 (transformed)`), which differs
/// ONLY in the box entity's `local_rotation` quaternion. The capture is the oracle:
/// applying the same edit through our write-back must reproduce the transformed file's
/// transform block exactly (the four x/y/z/w floats, in order, with position/scale
/// still inherited/omitted) — i.e. byte/structural interchange with RCP3.
@Suite struct RCP3EntityTransformTests {
    /// The box entity's `RCP3Entity.id` in the `Random3` capture (its `__uuid`).
    static let boxID = "6d239d1c-9102-ddc7-31e8-bb499d09aa06"

    /// The exact rotation quaternion RCP3 wrote in the transformed capture, in stored
    /// order (x, y, z, w).
    static let capturedRotation = (
        x: -0.02881590835750103,
        y: -0.28827366232872009,
        z: -0.17299818992614746,
        w: 0.94134980440139771
    )

    // MARK: Capture resolution (walk-up; no-op cleanly when absent)

    /// Walk-up resolver for a workspace-local `references/<name>` capture bundle.
    static func bundleURL(named name: String) -> URL? {
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

    static var baseBundleURL: URL? { bundleURL(named: "Random3 (base).realitycomposerpro") }
    static var transformedBundleURL: URL? { bundleURL(named: "Random3 (transformed).realitycomposerpro") }

    /// Copies a capture bundle into `temporaryDirectory` so write tests never mutate
    /// the source under `references/`. The caller cleans up.
    static func copyToTemp(_ src: URL) throws -> URL {
        let dst = FileManager.default.temporaryDirectory
            .appending(path: "rcp3-tform-\(UUID().uuidString).realitycomposerpro")
        try FileManager.default.copyItem(at: src, to: dst)
        return dst
    }

    // MARK: THE PARITY PROOF — reproduce the transformed capture exactly

    /// Open base → apply the captured rotation quaternion to the box → write back →
    /// the resulting `world.tm_entity` reproduces `Random3 (transformed)`'s transform
    /// block exactly (the four x/y/z/w floats in order; position/scale still inherited
    /// and omitted). Compared via the canonical serializer so both sides normalize
    /// identically — any structural, ordering, or lexeme divergence fails.
    @Test func reproducesTransformedCaptureExactly() throws {
        guard let baseURL = Self.baseBundleURL,
              let transformedURL = Self.transformedBundleURL else { return } // captures absent

        var editor = try RCP3Editor.open(baseURL)

        // The base box inherits identity for every transform component (all omitted).
        let before = try #require(editor.transform(forEntityID: Self.boxID))
        #expect(before == .identity)

        // Apply ONLY the rotation RCP3 changed; position + scale stay at identity.
        var edited = before
        edited.rotation = Self.capturedRotation
        let changed = editor.setTransform(edited, forEntityID: Self.boxID)
        #expect(changed)
        #expect(editor.hasUnsavedChanges)

        // Structural parity: the edited root, re-serialized, equals the transformed
        // capture re-serialized. (Both go through the same writer, so the trailing
        // newline + spacing normalize on both sides; only content can differ.)
        let transformedRoot = try #require(try RCP3Bundle.open(transformedURL).root)
        let ours = editor.root.tmText()
        #expect(ours == transformedRoot.tmText())

        // Byte-level parity against the RAW transformed capture file: identical, modulo
        // the writer's single trailing newline (RCP3 omits it). This proves we reproduce
        // RCP3's exact bytes — tabs, key order, and the 17-sig-fig float lexemes.
        let rawTransformed = try String(
            contentsOf: transformedURL.appending(path: "world.tm_entity"),
            encoding: .utf8
        )
        #expect(ours == rawTransformed || ours == rawTransformed + "\n")

        // And spell out the transform block itself for a legible failure.
        let box = try #require(boxEntity(in: editor.root))
        let component = try #require(transformComponent(of: box))

        // local_rotation: identity members preserved, then x, y, z, w in order with the
        // captured lexemes.
        let rotation = try #require(component["local_rotation"]?.objectValue)
        #expect(rotation.uuid == "5ec96c4e-91ca-9137-76e7-ea2a7c9dc624")
        #expect(rotation.prototypeType == "tm_rotation")
        #expect(rotation.prototypeUUID == "57af832e-ffd8-3b93-df13-c9e5698f7cb2")
        #expect(rotation.members.map(\.key) == ["__uuid", "__prototype_type", "__prototype_uuid", "x", "y", "z", "w"])
        #expect(rotation["x"]?.numberLexeme == "-0.02881590835750103")
        #expect(rotation["y"]?.numberLexeme == "-0.28827366232872009")
        #expect(rotation["z"]?.numberLexeme == "-0.17299818992614746")
        #expect(rotation["w"]?.numberLexeme == "0.94134980440139771")

        // local_position_double + local_scale: still inherited — identity members ONLY,
        // no value fields (omitted), exactly as RCP3 left them.
        let position = try #require(component["local_position_double"]?.objectValue)
        #expect(position.members.map(\.key) == ["__uuid", "__prototype_type", "__prototype_uuid"])
        let scale = try #require(component["local_scale"]?.objectValue)
        #expect(scale.members.map(\.key) == ["__uuid", "__prototype_type", "__prototype_uuid"])
    }

    /// The same edit persisted to disk and reopened reproduces the transformed
    /// capture's transform — proving the full open → edit → save loop.
    @Test func savesAndReopensMatchingTransformedCapture() throws {
        guard let baseURL = Self.baseBundleURL,
              let transformedURL = Self.transformedBundleURL else { return }

        let dir = try Self.copyToTemp(baseURL)
        defer { try? FileManager.default.removeItem(at: dir) }

        var editor = try RCP3Editor.open(dir)
        var edited = try #require(editor.transform(forEntityID: Self.boxID))
        edited.rotation = Self.capturedRotation
        editor.setTransform(edited, forEntityID: Self.boxID)
        try editor.save()
        #expect(!editor.hasUnsavedChanges)

        // Reopen from disk; its root re-serializes identically to the transformed capture.
        let reopened = try RCP3Bundle.open(dir)
        let transformedRoot = try RCP3Bundle.open(transformedURL).root
        #expect(reopened.root.tmText() == transformedRoot.tmText())
    }

    // MARK: No-op round-trip (open base, save with no edit → unchanged)

    /// Opening the base capture, saving with NO transform edit, and reopening leaves
    /// the file's structure (and every transform subobject) unchanged.
    @Test func noOpSaveLeavesBaseUnchanged() throws {
        guard let baseURL = Self.baseBundleURL else { return }

        let dir = try Self.copyToTemp(baseURL)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = try RCP3Bundle.open(dir)
        try original.save() // re-serialize, no edit
        let reopened = try RCP3Bundle.open(dir)
        #expect(reopened.root == original.root)
        #expect(reopened.root.tmText() == original.root.tmText())
    }

    /// A `setTransform` that writes the SAME (identity) transform the box already
    /// inherits is a true no-op: no change reported, nothing dirtied.
    @Test func settingInheritedIdentityIsNoOp() throws {
        guard let baseURL = Self.baseBundleURL else { return }
        var editor = try RCP3Editor.open(baseURL)
        let current = try #require(editor.transform(forEntityID: Self.boxID))
        #expect(current == .identity)
        let changed = editor.setTransform(current, forEntityID: Self.boxID)
        #expect(!changed)
        #expect(!editor.hasUnsavedChanges)
    }

    // MARK: Write-back rules (synthesized, capture-independent)

    /// A component object shaped like the capture's box transform (all subobjects
    /// inherited / identity), so write-back rules can be exercised without a capture.
    static let inheritedComponent: TMObject = {
        let text = """
        __type: "tm_transform_component"
        __uuid: "3dcae77c-3539-b923-144a-4a172d99fe8d"
        __prototype_type: "tm_transform_component"
        __prototype_uuid: "a2fed85d-b27e-81ad-31ed-843c8efc7d97"
        local_position_double: {
        \t__uuid: "ef67939d-9909-7e21-88a1-8b554cc55dbf"
        \t__prototype_type: "tm_position_double"
        \t__prototype_uuid: "3ac3855d-a753-ed5e-7217-b0f82932d85c"
        }
        local_rotation: {
        \t__uuid: "5ec96c4e-91ca-9137-76e7-ea2a7c9dc624"
        \t__prototype_type: "tm_rotation"
        \t__prototype_uuid: "57af832e-ffd8-3b93-df13-c9e5698f7cb2"
        }
        local_scale: {
        \t__uuid: "f15bf017-b0b8-b3df-b228-d3383fdbe595"
        \t__prototype_type: "tm_scale"
        \t__prototype_uuid: "168bee59-1061-b09d-9f34-de65b8d67eea"
        }
        """
        return try! TM.parse(text).objectValue!
    }()

    /// Writing a non-default position appends x/y/z after the identity members and
    /// preserves the subobject's identity; rotation/scale (left at default) stay omitted.
    @Test func writesPositionAndOmitsDefaults() throws {
        var t = RCP3Transform.identity
        t.translation = (x: 1.5, y: 0, z: -2.25) // y stays at the default → omitted
        let updated = RCP3TransformWriteBack.applied(t, to: Self.inheritedComponent)

        let position = try #require(updated["local_position_double"]?.objectValue)
        #expect(position.uuid == "ef67939d-9909-7e21-88a1-8b554cc55dbf")
        #expect(position.members.map(\.key) == ["__uuid", "__prototype_type", "__prototype_uuid", "x", "z"])
        #expect(position["x"]?.doubleValue == 1.5)
        #expect(position["z"]?.doubleValue == -2.25)
        #expect(position["y"] == nil) // default → omitted

        // Untouched rotation/scale stay inherited (identity members only).
        #expect(updated["local_rotation"]?.objectValue?.members.count == 3)
        #expect(updated["local_scale"]?.objectValue?.members.count == 3)
    }

    /// Whole-number scale components are written as integer lexemes (`2`, not `2.0`),
    /// matching how RCP stores them; a component returned to its default is dropped.
    @Test func wholeNumberLexemeAndDefaultDrop() throws {
        var t = RCP3Transform.identity
        t.scale = (x: 2, y: 1, z: 3) // y back at default 1 → omitted
        let updated = RCP3TransformWriteBack.applied(t, to: Self.inheritedComponent)
        let scale = try #require(updated["local_scale"]?.objectValue)
        #expect(scale["x"]?.numberLexeme == "2")
        #expect(scale["z"]?.numberLexeme == "3")
        #expect(scale["y"] == nil)
    }

    /// Re-applying the exact value already stored keeps its original lexeme (no drift)
    /// and reports no change.
    @Test func preservesExistingLexemeOnUnchangedValue() throws {
        // Start from a component that already has an explicit rotation lexeme.
        var t = RCP3Transform.identity
        t.rotation = Self.capturedRotation
        let first = RCP3TransformWriteBack.applied(t, to: Self.inheritedComponent)
        // Apply the SAME transform again — the lexemes must be byte-identical.
        let second = RCP3TransformWriteBack.applied(t, to: first)
        #expect(first == second)
        #expect(first["local_rotation"]?.objectValue?["x"]?.numberLexeme == "-0.02881590835750103")
        #expect(second["local_rotation"]?.objectValue?["x"]?.numberLexeme == "-0.02881590835750103")
    }

    /// An absent subobject stays absent when every value is the default (no spurious
    /// empty `{}` member RCP3 would never emit); it is added only when a value differs.
    @Test func absentSubobjectAddedOnlyWhenNonDefault() throws {
        // A transform component with NO subobjects at all.
        var bare = TMObject()
        bare.set(.string("tm_transform_component"), forKey: "__type")
        bare.set(.string("3dcae77c-3539-b923-144a-4a172d99fe8d"), forKey: "__uuid")

        // All-identity edit: nothing is added.
        let unchanged = RCP3TransformWriteBack.applied(.identity, to: bare)
        #expect(unchanged["local_position_double"] == nil)
        #expect(unchanged["local_rotation"] == nil)
        #expect(unchanged["local_scale"] == nil)
        #expect(unchanged == bare)

        // A non-default position adds ONLY that subobject, with just its value fields.
        var t = RCP3Transform.identity
        t.translation = (x: 0, y: 4.5, z: 0)
        let added = RCP3TransformWriteBack.applied(t, to: bare)
        let position = try #require(added["local_position_double"]?.objectValue)
        #expect(position.members.map(\.key) == ["y"])
        #expect(position["y"]?.numberLexeme == "4.5")
        #expect(added["local_rotation"] == nil)
        #expect(added["local_scale"] == nil)
    }

    // MARK: Euler ⇆ quaternion conversion

    /// The captured quaternion → Euler degrees → quaternion round-trips back to the
    /// same rotation (within float tolerance).
    @Test func eulerRoundTripsThroughQuaternion() {
        var t = RCP3Transform.identity
        t.rotation = Self.capturedRotation
        let euler = t.eulerDegrees
        let back = t.settingEulerDegrees(euler).rotation
        // Tolerance reflects the capture's ~16-digit quaternion (not perfectly unit).
        #expect(abs(back.x - Self.capturedRotation.x) < 1e-6)
        #expect(abs(back.y - Self.capturedRotation.y) < 1e-6)
        #expect(abs(back.z - Self.capturedRotation.z) < 1e-6)
        #expect(abs(back.w - Self.capturedRotation.w) < 1e-6)
    }

    /// A clean 90° rotation about Y produces the expected quaternion (sanity for the
    /// Euler-degrees → quaternion direction).
    @Test func ninetyDegreesAboutYproducesExpectedQuaternion() {
        let t = RCP3Transform.identity.settingEulerDegrees((x: 0, y: 90, z: 0))
        let s = (2.0).squareRoot() / 2
        #expect(abs(t.rotation.x) < 1e-9)
        #expect(abs(t.rotation.y - s) < 1e-9)
        #expect(abs(t.rotation.z) < 1e-9)
        #expect(abs(t.rotation.w - s) < 1e-9)
    }

    // MARK: Euler ⇆ quaternion convention, pinned to RCP3 captures (via Spatial)

    /// The inspector's degrees ⇆ quaternion conversion (Apple's Spatial `Rotation3D` /
    /// `EulerAngles`) must match RCP3's stored rotation. Verified against controlled
    /// captures: single-axis X/Y/Z = 30° (direct axis mapping) and the combined
    /// X=30, Y=45, Z=0 (`Random3 (known values)`), whose stored quaternion is the
    /// discriminator. Each typed Euler must yield RCP3's quaternion, and the inverse
    /// must return the typed angles.
    @Test func eulerConversionMatchesRCP3Captures() {
        func quat(_ x: Double, _ y: Double, _ z: Double) -> (x: Double, y: Double, z: Double, w: Double) {
            RCP3Transform.identity.settingEulerDegrees((x: x, y: y, z: z)).rotation
        }
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-5 }
        let s = 0.25881904, c = 0.96592583 // sin/cos 15°

        let qx = quat(30, 0, 0); #expect(near(qx.x, s) && near(qx.y, 0) && near(qx.z, 0) && near(qx.w, c))
        let qy = quat(0, 30, 0); #expect(near(qy.x, 0) && near(qy.y, s) && near(qy.z, 0) && near(qy.w, c))
        let qz = quat(0, 0, 30); #expect(near(qz.x, 0) && near(qz.y, 0) && near(qz.z, s) && near(qz.w, c))

        // Combined capture: X=30, Y=45, Z=0 → the exact quaternion RCP3 wrote.
        let qc = quat(30, 45, 0)
        #expect(near(qc.x, 0.23911761) && near(qc.y, 0.36964384)
            && near(qc.z, -0.09904577) && near(qc.w, 0.89239907))

        // Inverse returns the typed angles.
        var t = RCP3Transform.identity; t.rotation = qc
        let e = t.eulerDegrees
        #expect(near(e.x, 30) && near(e.y, 45) && near(e.z, 0))
    }

    // MARK: Helpers

    /// The `box` child entity of the captured world root (public-API tree walk).
    private func boxEntity(in root: TMObject) -> TMObject? {
        for value in root["children"]?.arrayValue ?? [] {
            guard let child = value.objectValue else { continue }
            if child.uuid == Self.boxID || child.name == "box" { return child }
        }
        return nil
    }

    private func transformComponent(of entity: TMObject) -> TMObject? {
        for key in ["components", "components__instantiated"] {
            guard let array = entity[key]?.arrayValue else { continue }
            for value in array {
                guard let component = value.objectValue else { continue }
                if (component.type ?? component.prototypeType) == "tm_transform_component" {
                    return component
                }
            }
        }
        return nil
    }
}
