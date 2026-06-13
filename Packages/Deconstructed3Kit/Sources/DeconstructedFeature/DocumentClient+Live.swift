import ComposableArchitecture
import Foundation
import RCP3Document

extension DocumentClient: DependencyKey {
    /// The `liveValue` is a **throwing stub**, not the real implementation.
    ///
    /// AGENTS.md's shell-runtime pattern: a `@Dependency` whose real work needs
    /// host capabilities defines a throwing stub here and is installed for real at
    /// startup via `prepareDependencies`. Shipping a throwing stub (rather than a
    /// no-op) means a forgotten install crashes loudly instead of silently doing
    /// nothing. Install the working client with `DocumentClient.installLive()`.
    public static let liveValue = DocumentClient(
        open: { _ in throw DocumentClientError.notInstalled },
        save: { _ in throw DocumentClientError.notInstalled }
    )

    /// The real disk-backed client: `RCP3Editor.open` / `.save`. Self-contained and
    /// value-typed (no C++ types cross the boundary), so it can be the `liveValue`
    /// directly — the throwing-stub indirection above exists only to honor the
    /// shell-runtime install discipline shared with heavier (USD/Cxx) clients.
    public static let live = DocumentClient(
        open: { url in try RCP3Editor.open(url) },
        save: { editor in
            var editor = editor
            try editor.save()
            return editor
        }
    )

    /// Installs the real disk-backed `DocumentClient` as the live dependency.
    /// Call once at app startup, e.g.
    /// `prepareDependencies { $0.documentClient = .live }`.
    public static func installLive() {
        prepareDependencies { $0.documentClient = .live }
    }
}

/// Failures surfaced by `DocumentClient` itself (the live stub before install).
public enum DocumentClientError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The live `DocumentClient` was used before `installLive()` ran.
    case notInstalled

    public var description: String {
        switch self {
        case .notInstalled:
            "DocumentClient was not installed. Call DocumentClient.installLive() at startup."
        }
    }
}
