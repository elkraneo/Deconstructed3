import SwiftUI
import RealityKit
import RealityKitScripting
import RCP3Document
import RCP3Runtime

/// A standalone **"Simulate (canonical)"** view: it runs an RCP 3 script graph on
/// Apple's *real* `RealityKitScripting` runtime, in a `RealityView` we own.
///
/// The graph is compiled to the public-runtime JavaScript surface by
/// ``RCP3Runtime/CanonicalScriptGraphCompiler``, attached to the box via
/// `ScriptingComponent(source:)`, and executed by the system once `.realityScripting()`
/// is active. The script itself installs the input-target + collision and registers
/// the drag handler (see the compiler), so a plain `ModelEntity` is enough — drag it
/// and Apple's runtime moves it.
///
/// This is intentionally self-contained (its own `RealityView` + orbit camera, not
/// StageView's) so the canonical runtime can be proven without entangling StageView
/// with a macOS-27 binary dependency.
@MainActor
public struct CanonicalSimulateView: View {
    /// The compiled JavaScript (computed once from the graph).
    private let source: String
    @State private var validationError: String?

    public init(graph: RCP3ScriptGraph) {
        self.source = CanonicalScriptGraphCompiler().compile(graph)
    }

    public var body: some View {
        RealityView { content in
            // Boot the runtime before mounting scripted entities (idempotent).
            try? CanonicalRuntime.initializeOnce()

            let box = ModelEntity(
                mesh: .generateBox(size: 0.2),
                materials: [SimpleMaterial(color: .gray, isMetallic: false)]
            )
            box.name = "box"
            box.components.set(ScriptingComponent(source: source))
            content.add(box)
        }
        .realityScripting()
        #if os(macOS) || os(iOS)
        .realityViewCameraControls(.orbit)
        #endif
        .overlay(alignment: .bottom) {
            if let validationError {
                Text("Script error: \(validationError)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .background(.ultraThinMaterial, in: .rect(cornerRadius: 8))
                    .padding()
            }
        }
        .task {
            validationError = CanonicalRuntime.validationError(in: source)
        }
    }
}
