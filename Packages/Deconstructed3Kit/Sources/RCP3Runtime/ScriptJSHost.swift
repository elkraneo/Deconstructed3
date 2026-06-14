import Foundation
import JavaScriptCore
import simd

/// A public-JavaScriptCore host that runs an RCP 3 script graph (compiled to JS)
/// against a `RuntimeEntityState`.
///
/// This replicates RCP 3's observed runtime model honestly with our own pieces: a
/// public `JSContext`, an `entity` object exposed to the script, and an event API.
/// A compiled graph is JS that registers handlers (`entity.on("drag", fn)`); the
/// Swift side drives them with `dispatch(event:payload:)`. Handlers read and write
/// `entity.transform.translation` / `.rotation` / `.scale`, which are bridged to
/// the bound `RuntimeEntityState`.
///
/// ## Concurrency
///
/// `JSContext` / `JSValue` are not `Sendable`, so the whole host is `@MainActor`
/// isolated and never crosses actor boundaries. The bridge closures capture the
/// state on the main actor; the `@convention(block)` blocks JavaScriptCore invokes
/// run synchronously on the calling (main) thread, so the captured state is only
/// ever touched on the main actor.
@MainActor
public final class ScriptJSHost {
    /// The entity the script mutates.
    public let state: RuntimeEntityState

    /// The underlying JavaScriptCore context. Exposed for advanced callers; most
    /// use goes through `load` / `dispatch`.
    public let context: JSContext

    /// Registered event handlers, keyed by event name (`"drag"`, `"tap"`, …). A
    /// script may register more than one handler for the same event; all fire, in
    /// registration order. Stored as `JSValue` so they keep their JS closure
    /// identity and captured scope.
    private var handlers: [String: [JSValue]] = [:]

    /// The most recent uncaught JS exception, if any (cleared on each `load` /
    /// `dispatch`). Useful for tests and diagnostics.
    public private(set) var lastException: String?

    /// Lines the running script emitted via `console.log(...)`, in order, across the
    /// host's lifetime (not cleared per `dispatch`). Surfaced in the preview so a
    /// graph's diagnostics are visible.
    public private(set) var consoleMessages: [String] = []

    public init(state: RuntimeEntityState) {
        self.state = state
        guard let context = JSContext() else {
            // JSContext() only returns nil if the VM can't be created, which does
            // not happen on a supported platform. Fail loudly rather than mask it.
            fatalError("RCP3Runtime: could not create a JSContext")
        }
        self.context = context
        installBridge()
    }

    // MARK: Public API

    /// Evaluates `js` in the context. A compiled graph typically registers handlers;
    /// a bare statement (e.g. `entity.transform.translation = [1,2,3]`) takes effect
    /// immediately. Any uncaught exception is recorded in `lastException`.
    public func load(_ js: String) {
        lastException = nil
        context.evaluateScript(js)
    }

    /// Invokes every handler registered for `event`, passing `payload` as a JS
    /// object (the event `e`). Numeric arrays in `payload` (e.g. `["delta": [dx,
    /// dy, dz]]`) become JS arrays the handler can index. Mutations the handler
    /// makes to `entity.transform` land in `state`.
    public func dispatch(event: String, payload: [String: Any] = [:]) {
        lastException = nil
        guard let handlers = handlers[event], !handlers.isEmpty else { return }
        let jsPayload = JSValue(object: payload, in: context)
        for handler in handlers {
            handler.call(withArguments: jsPayload.map { [$0] } ?? [])
        }
    }

    /// Whether any handler is registered for `event` (used by tests/inspectors).
    public func hasHandler(for event: String) -> Bool {
        !(handlers[event]?.isEmpty ?? true)
    }

    // MARK: Bridge installation

    /// Builds the `entity` object and the `transform` accessors, and wires the
    /// `entity.on(...)` registration plus the exception sink.
    private func installBridge() {
        // Record uncaught exceptions instead of swallowing them silently.
        context.exceptionHandler = { [weak self] _, exception in
            self?.lastException = exception?.toString()
        }

        let state = self.state

        // entity.transform.translation — get/set bridged to RuntimeEntityState.
        let getTranslation: @convention(block) () -> [Double] = {
            let t = state.translation
            return [t.x, t.y, t.z]
        }
        let setTranslation: @convention(block) ([Double]) -> Void = { value in
            state.translation = Self.simd3(value, default: state.translation)
        }

        // entity.transform.scale — get/set.
        let getScale: @convention(block) () -> [Double] = {
            let s = state.scale
            return [s.x, s.y, s.z]
        }
        let setScale: @convention(block) ([Double]) -> Void = { value in
            state.scale = Self.simd3(value, default: state.scale)
        }

        // entity.transform.rotation — get/set as a 4-component quaternion
        // [ix, iy, iz, r] (imaginary parts then real, matching simd_quatd.vector).
        let getRotation: @convention(block) () -> [Double] = {
            let q = state.rotation
            return [q.imag.x, q.imag.y, q.imag.z, q.real]
        }
        let setRotation: @convention(block) ([Double]) -> Void = { value in
            guard value.count == 4 else { return }
            state.rotation = simd_quatd(ix: value[0], iy: value[1], iz: value[2], r: value[3])
        }

        // entity.on(event, fn) — register a handler.
        let on: @convention(block) (String, JSValue) -> Void = { [weak self] event, fn in
            guard let self, fn.isObject else { return }
            self.handlers[event, default: []].append(fn)
        }

        // console.log(...args) — collect into `consoleMessages` for diagnostics.
        let log: @convention(block) (JSValue) -> Void = { [weak self] args in
            guard let self else { return }
            // `arguments` arrives as a JS array (see prelude); join its parts.
            let parts = (args.toArray() ?? []).map { String(describing: $0) }
            self.consoleMessages.append(parts.joined(separator: " "))
        }

        // Define `entity` with a `transform` whose components are JS accessor
        // properties bridging to the blocks above. Building the object in JS (with
        // Object.defineProperty getters/setters) keeps the natural
        // `entity.transform.translation = [...]` assignment syntax working.
        let bridge = context.objectForKeyedSubscript("globalThis")
        bridge?.setObject(getTranslation, forKeyedSubscript: "__getTranslation" as NSString)
        bridge?.setObject(setTranslation, forKeyedSubscript: "__setTranslation" as NSString)
        bridge?.setObject(getRotation, forKeyedSubscript: "__getRotation" as NSString)
        bridge?.setObject(setRotation, forKeyedSubscript: "__setRotation" as NSString)
        bridge?.setObject(getScale, forKeyedSubscript: "__getScale" as NSString)
        bridge?.setObject(setScale, forKeyedSubscript: "__setScale" as NSString)
        bridge?.setObject(on, forKeyedSubscript: "__on" as NSString)
        bridge?.setObject(log, forKeyedSubscript: "__log" as NSString)

        context.evaluateScript(Self.bridgePrelude)
    }

    /// JS that assembles the `entity` object from the installed native blocks. The
    /// transform components are defined as accessor properties so reads and writes
    /// flow straight to `RuntimeEntityState`.
    static let bridgePrelude = """
    var entity = {
        on: function(event, fn) { __on(event, fn); }
    };
    entity.transform = {};
    Object.defineProperty(entity.transform, "translation", {
        get: function() { return __getTranslation(); },
        set: function(v) { __setTranslation(v); }
    });
    Object.defineProperty(entity.transform, "rotation", {
        get: function() { return __getRotation(); },
        set: function(v) { __setRotation(v); }
    });
    Object.defineProperty(entity.transform, "scale", {
        get: function() { return __getScale(); },
        set: function(v) { __setScale(v); }
    });
    var console = {
        log: function() { __log(Array.prototype.slice.call(arguments)); }
    };
    """

    /// Builds a `SIMD3<Double>` from a JS array, keeping `default` for missing or
    /// malformed input (a handler that returns a non-3 array is a no-op write).
    private static func simd3(_ value: [Double], default fallback: SIMD3<Double>) -> SIMD3<Double> {
        guard value.count == 3 else { return fallback }
        return SIMD3(value[0], value[1], value[2])
    }
}
