import Foundation
import FoundationModels

/// The real macOS 27 Dynamic Profile installed in a `LanguageModelSession`.
///
/// Tools are part of the profile itself. Switching from Review to Build therefore
/// changes the model's executable capability set, rather than merely changing a
/// prompt or hiding controls in the UI.
public struct ScriptGraphDynamicProfile: LanguageModelSession.DynamicProfile {
    let selection: ScriptGraphAgentProfile
    let tools: [any Tool]

    public var body: some LanguageModelSession.DynamicProfile {
        if selection == .deepBuild {
            LanguageModelSession.Profile {
                Instructions(Self.instructions(for: selection))
                tools
            }
            .model(PrivateCloudComputeLanguageModel())
            .reasoningLevel(.deep)
            .toolCallingMode(.allowed)
        } else {
            LanguageModelSession.Profile {
                Instructions(Self.instructions(for: selection))
                tools
            }
            .model(SystemLanguageModel.default)
            .reasoningLevel(selection == .review ? .moderate : .deep)
            .toolCallingMode(.allowed)
        }
    }

    private static func instructions(for profile: ScriptGraphAgentProfile) -> String {
        let permission = profile.permitsMutation
            ? "You may edit the live graph and invoke workspace actions."
            : "You are in read-only review mode. Never claim that you changed the graph."
        return """
        You are the Script Graph authoring agent inside Deconstructed 3. Work against the open, live RCP3 Script Graph.
        \(permission)
        Inspect the graph and catalog before editing. Use exact node and pin identifiers returned by tools. Prefer small,
        verifiable changes. After editing, validate the graph and clearly report any unsupported behavior. A successful
        tool call is evidence about the live canvas; do not invent nodes, connections, compiler results, saves, or runs.
        """
    }
}

/// Owns one conversational Foundation Models session for an open Script Graph.
/// Profile changes retain conversation/tool history while replacing old instructions.
@MainActor
public final class ScriptGraphAgentSession: Sendable {
    public private(set) var profile: ScriptGraphAgentProfile

    private let executor: ScriptGraphAgentExecutor
    private var modelSession: LanguageModelSession?
    private var activeTask: Task<Void, Never>?
    private var activeContinuation: AsyncThrowingStream<ScriptGraphAgentStreamEvent, Error>.Continuation?
    private var cloudContextSize: Int?

    public init(
        executor: ScriptGraphAgentExecutor,
        profile: ScriptGraphAgentProfile = .build
    ) {
        self.executor = executor
        self.profile = profile
        rebuildSession(history: [])
    }

    public func setProfile(_ newProfile: ScriptGraphAgentProfile) {
        guard profile != newProfile else { return }
        cancel()
        let history = modelSession?.transcript.filter { entry in
            if case .instructions = entry { return false }
            return true
        } ?? []
        profile = newProfile
        rebuildSession(history: history)
    }

    public func reset() {
        cancel()
        rebuildSession(history: [])
    }

    public func prewarm() {
        modelSession?.prewarm(promptPrefix: nil)
    }

    public func cancel() {
        activeTask?.cancel()
        activeTask = nil
        activeContinuation?.finish()
        activeContinuation = nil
    }

    public func statuses() async -> [ScriptGraphAgentProfileStatus] {
        let local = SystemLanguageModel.default
        let localDetail = Self.localAvailabilityDetail(local.availability)
        let localContext = local.isAvailable ? local.contextSize : nil

        let cloud = PrivateCloudComputeLanguageModel()
        let cloudDetail = Self.cloudAvailabilityDetail(cloud.availability)
        if cloud.isAvailable, cloudContextSize == nil {
            cloudContextSize = try? await cloud.contextSize
        }

        return ScriptGraphAgentProfile.allCases.map { candidate in
            if candidate == .deepBuild {
                ScriptGraphAgentProfileStatus(
                    profile: candidate,
                    isAvailable: cloud.isAvailable,
                    detail: cloudDetail,
                    contextSize: cloudContextSize
                )
            } else {
                ScriptGraphAgentProfileStatus(
                    profile: candidate,
                    isAvailable: local.isAvailable,
                    detail: localDetail,
                    contextSize: localContext
                )
            }
        }
    }

    /// Streams cumulative response snapshots. Consumers should replace the current
    /// assistant text for each `.text` event instead of appending it.
    public func stream(
        prompt: String
    ) -> AsyncThrowingStream<ScriptGraphAgentStreamEvent, Error> {
        cancel()
        return AsyncThrowingStream { continuation in
            activeContinuation = continuation
            activeTask = Task { [weak self] in
                await self?.respond(to: prompt, continuation: continuation)
            }
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in
                    self?.activeTask?.cancel()
                    self?.activeTask = nil
                    self?.activeContinuation = nil
                }
            }
        }
    }

    private func rebuildSession(history: some Collection<Transcript.Entry>) {
        let environment = ScriptGraphAgentToolEnvironment(
            executor: executor,
            permitsMutation: profile.permitsMutation,
            activity: { [weak self] activity in
                self?.activeContinuation?.yield(.activity(activity))
            }
        )
        let tools = ScriptGraphAgentToolset.tools(for: profile, environment: environment)
        modelSession = LanguageModelSession(
            profile: ScriptGraphDynamicProfile(selection: profile, tools: tools),
            history: history
        )
    }

    private func respond(
        to prompt: String,
        continuation: AsyncThrowingStream<ScriptGraphAgentStreamEvent, Error>.Continuation
    ) async {
        do {
            try await requireAvailability(for: profile)
            guard let modelSession else {
                throw ScriptGraphAgentError.modelUnavailable("The model session could not be created.")
            }
            let contextSize = await contextSize(for: profile)
            for try await snapshot in modelSession.streamResponse(to: prompt) {
                try Task.checkCancellation()
                continuation.yield(.text(snapshot.content))
                let used = snapshot.usage.input.totalTokenCount + snapshot.usage.output.totalTokenCount
                let fraction = contextSize.map { min(1, Double(used) / Double(max($0, 1))) }
                continuation.yield(.context(fraction))
            }
            let usage = modelSession.usage
            let used = usage.input.totalTokenCount + usage.output.totalTokenCount
            let fraction = contextSize.map { min(1, Double(used) / Double(max($0, 1))) }
            continuation.yield(.context(fraction))
            continuation.yield(.finished)
            continuation.finish()
        } catch is CancellationError {
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func requireAvailability(for profile: ScriptGraphAgentProfile) async throws {
        if profile == .deepBuild {
            let model = PrivateCloudComputeLanguageModel()
            guard model.isAvailable else {
                throw ScriptGraphAgentError.modelUnavailable(Self.cloudAvailabilityDetail(model.availability))
            }
        } else {
            let model = SystemLanguageModel.default
            guard model.isAvailable else {
                throw ScriptGraphAgentError.modelUnavailable(Self.localAvailabilityDetail(model.availability))
            }
        }
    }

    private func contextSize(for profile: ScriptGraphAgentProfile) async -> Int? {
        if profile == .deepBuild {
            if let cloudContextSize { return cloudContextSize }
            cloudContextSize = try? await PrivateCloudComputeLanguageModel().contextSize
            return cloudContextSize
        }
        return SystemLanguageModel.default.contextSize
    }

    private static func localAvailabilityDetail(
        _ availability: SystemLanguageModel.Availability
    ) -> String {
        switch availability {
        case .available: "On-device model ready."
        case .unavailable(.deviceNotEligible): "This Mac is not eligible for the on-device model."
        case .unavailable(.appleIntelligenceNotEnabled): "Apple Intelligence is not enabled."
        case .unavailable(.modelNotReady): "The on-device model is not ready yet."
        @unknown default: "The on-device model is unavailable."
        }
    }

    private static func cloudAvailabilityDetail(
        _ availability: PrivateCloudComputeLanguageModel.Availability
    ) -> String {
        switch availability {
        case .available: "Private Cloud Compute ready."
        case .unavailable(.deviceNotEligible): "This Mac is not eligible for Private Cloud Compute."
        case .unavailable(.systemNotReady): "Private Cloud Compute is not ready yet."
        @unknown default: "Private Cloud Compute is unavailable."
        }
    }
}
