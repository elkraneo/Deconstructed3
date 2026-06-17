import Foundation
import Observation
import RealityKitScripting

/// A live capture of Apple's **structured** `RealityKitScripting` log stream — the
/// real debug channel the runtime uses, not a generic `console.log` of our own.
///
/// It receives `console.log`/`warn`/`error` from scripts AND **uncaught exceptions**
/// (which arrive as `LogEntry`s with `origin == .exception(...)`). Each entry carries
/// the message, `level`, source `file`/`line`, and the entity/scene id — so a script
/// error like *"Can't find variable: RealityKit"* surfaces here directly instead of
/// being buried in the system log.
@MainActor
@Observable
public final class ScriptLog {
    public private(set) var entries: [LogEntry] = []

    /// Upper bound on retained entries. The process-global logger forwards every
    /// scene's `console.*` + exceptions here for the whole session, so without a
    /// cap the array grows unbounded. The console only shows the tail, so we keep
    /// a rolling window of the most recent entries.
    static let maxEntries = 2000

    func append(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }
    public func clear() { entries.removeAll() }

    /// A one-line rendering of an entry for a console panel.
    public static func line(_ e: LogEntry) -> String {
        switch e.origin {
        case .exception: return "✗ exception: \(e.message)"
        case .console: return "[\(e.level.rawValue)] \(e.message)"
        @unknown default: return e.message
        }
    }

    /// Whether an entry is an error/exception (for highlighting).
    public static func isError(_ e: LogEntry) -> Bool {
        if case .exception = e.origin { return true }
        return e.level == .error
    }
}

/// Thin wrapper over Apple's public `RealityKitScripting` runtime (`RKS`), the real
/// runtime RCP 3 script graphs execute on.
///
/// `initializeOnce()` boots the runtime once and installs a logger so its structured
/// log (``log``) is captured for display. The compiled JavaScript a graph runs is
/// produced by ``RCP3Runtime/CanonicalScriptGraphCompiler`` and attached to an entity
/// via `ScriptingComponent(source:)`.
@MainActor
public enum CanonicalRuntime {
    private static var didInitialize = false

    /// The live capture of the runtime's structured log (script `console` output +
    /// uncaught exceptions). Observe it to show a console panel.
    public static let log = ScriptLog()

    /// Boots the canonical Script Graph runtime once — installing the log listener —
    /// and is idempotent afterward. Errors are propagated.
    public static func initializeOnce() throws {
        guard !didInitialize else { return }
        let configuration = RKS.Configuration(id: "com.deconstructed3.canonical")
            .addLogger("deconstructed3") { entry in
                CanonicalRuntime.log.append(entry)
            }
        try RKS.initialize(with: configuration)
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
