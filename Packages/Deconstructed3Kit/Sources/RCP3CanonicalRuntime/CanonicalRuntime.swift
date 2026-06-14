import Foundation
import RealityKitScripting

/// Thin wrapper over Apple's public `RealityKitScripting` runtime (`RKS`), the real
/// runtime RCP 3 script graphs execute on.
///
/// The runtime is booted once per process (before any scripted `RealityView` is
/// rendered). `initializeOnce()` is idempotent so the app, previews, and a
/// "Simulate (canonical)" view can all call it freely. The compiled JavaScript a
/// graph runs is produced by ``RCP3Runtime/CanonicalScriptGraphCompiler`` and
/// attached to an entity via `ScriptingComponent(source:)`.
@MainActor
public enum CanonicalRuntime {
    private static var didInitialize = false

    /// Boots the canonical Script Graph runtime once; subsequent calls are no-ops.
    /// Errors are propagated so a boot failure isn't silently swallowed.
    public static func initializeOnce() throws {
        guard !didInitialize else { return }
        try RKS.initialize()
        didInitialize = true
    }

    /// Validates compiled script `source` without running it — for surfacing a JS
    /// error in the editor before a run. Returns an error message, or `nil` if valid.
    public static func validationError(in source: String) -> String? {
        do {
            try RKS.validateScript(source)
            return nil
        } catch {
            return String(describing: error)
        }
    }
}
