/// A small concurrency-safe boundary between the presentation feature and a
/// per-graph Foundation Models session.
public struct ScriptGraphAgentClient: Sendable {
    public var statuses: @MainActor @Sendable () async -> [ScriptGraphAgentProfileStatus]
    public var setProfile: @MainActor @Sendable (ScriptGraphAgentProfile) -> Void
    public var prewarm: @MainActor @Sendable () -> Void
    public var stream: @MainActor @Sendable (String) -> AsyncThrowingStream<ScriptGraphAgentStreamEvent, Error>
    public var cancel: @MainActor @Sendable () -> Void
    public var reset: @MainActor @Sendable () -> Void

    public init(
        statuses: @escaping @MainActor @Sendable () async -> [ScriptGraphAgentProfileStatus],
        setProfile: @escaping @MainActor @Sendable (ScriptGraphAgentProfile) -> Void,
        prewarm: @escaping @MainActor @Sendable () -> Void,
        stream: @escaping @MainActor @Sendable (String) -> AsyncThrowingStream<ScriptGraphAgentStreamEvent, Error>,
        cancel: @escaping @MainActor @Sendable () -> Void,
        reset: @escaping @MainActor @Sendable () -> Void
    ) {
        self.statuses = statuses
        self.setProfile = setProfile
        self.prewarm = prewarm
        self.stream = stream
        self.cancel = cancel
        self.reset = reset
    }

    @MainActor
    public static func live(session: ScriptGraphAgentSession) -> Self {
        Self(
            statuses: { await session.statuses() },
            setProfile: { session.setProfile($0) },
            prewarm: { session.prewarm() },
            stream: { session.stream(prompt: $0) },
            cancel: { session.cancel() },
            reset: { session.reset() }
        )
    }
}
