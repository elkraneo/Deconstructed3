import ComposableArchitecture
import Foundation
import RCP3Document

/// The disk-I/O seam for the document feature: open and save are the only two
/// operations that touch the file system, so they live behind a controllable
/// `@Dependency`. Everything else (rename, selection, dirty tracking) is pure
/// value-type editing on the `RCP3Editor` the feature holds in state.
///
/// Following the AGENTS.md **shell-runtime dependency-install pattern**, the live
/// value here is a *throwing stub*: a missing install fails loudly rather than
/// silently returning empty data. The real implementation is installed at app
/// startup via `prepareDependencies` (see `DocumentClient+Live`). Tests override
/// it with an in-memory or temp-backed value through `TestStore`/`withDependencies`.
@DependencyClient
public struct DocumentClient: Sendable {
    /// Opens the bundle at `url` for editing, returning a fresh `RCP3Editor`
    /// session (`hasUnsavedChanges == false`).
    public var open: @Sendable (_ url: URL) throws -> RCP3Editor

    /// Persists `editor`'s current root to disk and returns the editor with its
    /// dirty flag cleared (`RCP3Editor.save()` is `mutating`, so we take the value
    /// in and hand the saved value back out — no C++/reference state crosses here).
    public var save: @Sendable (_ editor: RCP3Editor) throws -> RCP3Editor
}

extension DocumentClient: TestDependencyKey {
    /// Throwing stub. Per the shell-runtime pattern, the *live* value is also a
    /// throwing stub installed at startup (`DocumentClient+Live`), so a forgotten
    /// install surfaces immediately instead of silently no-op'ing.
    public static let testValue = DocumentClient()
}

public extension DependencyValues {
    var documentClient: DocumentClient {
        get { self[DocumentClient.self] }
        set { self[DocumentClient.self] = newValue }
    }
}
