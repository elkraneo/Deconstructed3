import SwiftUI
import RealityKit
import RealityKitScripting
import RCP3Document
import RCP3Runtime

/// The canonical **Play** view: it runs an RCP 3 script graph on Apple's *real*
/// `RealityKitScripting` runtime, in a `RealityView` we own, with Apple's own
/// debugging surfaced — a live **console** (the structured runtime log) and the
/// **JS debugger** (Safari Web Inspector).
///
/// The graph is compiled to the public-runtime JavaScript by
/// ``RCP3Runtime/CanonicalScriptGraphCompiler``, attached to the box via
/// `ScriptingComponent(source:)`, and executed once `.realityScripting()` is active.
/// The script installs the input-target + collision and registers the drag handler,
/// so a plain `ModelEntity` is enough — drag it and Apple's runtime moves it.
///
/// Self-contained (its own `RealityView` + orbit camera, not StageView's) so the
/// canonical runtime can be exercised without entangling StageView with a macOS-27
/// binary dependency. Designed to fill a view region INLINE (the document's center
/// column), so its console is a small collapsible OVERLAY rather than a fixed panel
/// that would dominate the viewport.
@MainActor
public struct CanonicalPlayView: View {
    /// The compiled JavaScript (computed once from the graph).
    private let source: String
    @State private var validationError: String?
    /// Whether the runtime-log console overlay is shown. Collapsed by default so the
    /// inline 3D viewport isn't dominated; a small toolbar button toggles it.
    @State private var showsConsole = false

    public init(graph: RCP3ScriptGraph) {
        self.source = CanonicalScriptGraphCompiler().compile(graph)
    }

    public var body: some View {
        RealityView { content in
            // Boot the runtime + install the log listener before mounting scripted
            // entities (idempotent).
            try? CanonicalRuntime.initializeOnce()

            let box = ModelEntity(
                mesh: .generateBox(size: 0.2),
                materials: [SimpleMaterial(color: .gray, isMetallic: false)]
            )
            box.name = "box"
            box.components.set(ScriptingComponent(source: source))
            content.add(box)

            // Apple's JS debugger: name + enable so this script's JavaScriptCore
            // context appears in Safari ▸ Develop ▸ this Mac ▸ the named context
            // (breakpoints, stepping, live console, evaluate).
            box.scene?.renameJSContext("Deconstructed 3 — Script Graph")
            box.scene?.enableDebugger(true)
        }
        .realityScripting()
        #if os(macOS) || os(iOS)
        .realityViewCameraControls(.orbit)
        #endif
        // Console as a small, collapsible OVERLAY pinned to the bottom — it doesn't
        // dominate the inline viewport, and a toggle in the top-right reveals it.
        .overlay(alignment: .topTrailing) {
            Button {
                showsConsole.toggle()
            } label: {
                Label("Console", systemImage: "terminal")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .padding(8)
            .help(showsConsole ? "Hide the runtime log" : "Show the runtime log")
        }
        .overlay(alignment: .bottom) {
            if showsConsole {
                ConsolePanel(log: CanonicalRuntime.log, validationError: validationError)
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: showsConsole)
        .task {
            validationError = CanonicalRuntime.validationError(in: source)
        }
    }
}

/// A live console showing Apple's structured runtime log — script `console` output
/// and uncaught exceptions — plus a pre-run validation error if the JS is invalid.
@MainActor
private struct ConsolePanel: View {
    let log: ScriptLog
    let validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Label("Runtime log", systemImage: "terminal")
                Spacer()
                Button("Clear") { log.clear() }
                    .buttonStyle(.borderless)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if let validationError {
                        Text("Script did not validate: \(validationError)")
                            .foregroundStyle(.red)
                    }
                    ForEach(log.entries) { entry in
                        Text(ScriptLog.line(entry))
                            .foregroundStyle(ScriptLog.isError(entry) ? Color.red : .secondary)
                            .textSelection(.enabled)
                    }
                    if log.entries.isEmpty && validationError == nil {
                        Text("No runtime output yet — drag the box.")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
        }
        .background(.black.opacity(0.85))
    }
}
