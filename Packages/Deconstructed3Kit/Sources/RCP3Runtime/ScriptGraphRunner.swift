import Foundation
import RCP3Document

/// Compiles a script graph and runs it against a `RuntimeEntityState`.
///
/// One call wires the whole path-2 pipeline: `RCP3ScriptGraph` → JS
/// (`ScriptGraphCompiler`) → a loaded `ScriptJSHost` bound to `state`. The graph's
/// scripts register their handlers during `run`; the caller then drives them with
/// `host.dispatch(event:payload:)`, and the resulting transform lands in `state`.
@MainActor
public enum ScriptGraphRunner {
    /// Compiles `graph`, loads it into a fresh host bound to `state`, and returns
    /// the host ready to receive events.
    @discardableResult
    public static func run(
        _ graph: RCP3ScriptGraph,
        into state: RuntimeEntityState
    ) -> ScriptJSHost {
        let js = ScriptGraphCompiler().compile(graph)
        let host = ScriptJSHost(state: state)
        host.load(js)
        return host
    }
}
