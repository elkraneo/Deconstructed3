import ComposableArchitecture
import Foundation
import RCP3Agent

@Reducer
public struct ScriptGraphAgentFeature: Sendable {
    @ObservableState
    public struct State: Equatable, Sendable {
        public var profile: ScriptGraphAgentProfile = .build
        public var statuses: [ScriptGraphAgentProfileStatus] = []
        public var messages: [ScriptGraphAgentMessage] = []
        public var activities: [ScriptGraphAgentActivity] = []
        public var input = ""
        public var isResponding = false
        public var activeAssistantID: UUID?
        public var contextFraction: Double?
        public var errorMessage: String?

        public init() {}
    }

    public enum Action: Sendable {
        case task
        case statusesLoaded([ScriptGraphAgentProfileStatus])
        case profileSelected(ScriptGraphAgentProfile)
        case inputChanged(String)
        case sendTapped
        case cancelTapped
        case resetTapped
        case streamEvent(ScriptGraphAgentStreamEvent)
        case responseFailed(String)
    }

    private enum CancelID { case response }
    private let client: ScriptGraphAgentClient

    public init(client: ScriptGraphAgentClient) {
        self.client = client
    }

    public var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .task:
                return .run { [client] send in
                    let statuses = await client.statuses()
                    await client.prewarm()
                    await send(.statusesLoaded(statuses))
                }

            case let .statusesLoaded(statuses):
                state.statuses = statuses
                return .none

            case let .profileSelected(profile):
                guard state.profile != profile else { return .none }
                state.profile = profile
                state.isResponding = false
                state.activeAssistantID = nil
                state.activities = []
                state.errorMessage = nil
                return .merge(
                    .cancel(id: CancelID.response),
                    .run { [client] _ in
                        await client.setProfile(profile)
                        await client.prewarm()
                    }
                )

            case let .inputChanged(input):
                state.input = input
                return .none

            case .sendTapped:
                let prompt = state.input.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !prompt.isEmpty, !state.isResponding else { return .none }
                let assistantID = UUID()
                state.messages.append(.init(role: .user, text: prompt))
                state.messages.append(.init(id: assistantID, role: .assistant, text: ""))
                state.activeAssistantID = assistantID
                state.input = ""
                state.activities = []
                state.isResponding = true
                state.errorMessage = nil
                return .run { [client] send in
                    do {
                        let stream = await client.stream(prompt)
                        for try await event in stream {
                            await send(.streamEvent(event))
                        }
                    } catch {
                        await send(.responseFailed(error.localizedDescription))
                    }
                }
                .cancellable(id: CancelID.response, cancelInFlight: true)

            case .cancelTapped:
                state.isResponding = false
                state.activeAssistantID = nil
                return .merge(
                    .cancel(id: CancelID.response),
                    .run { [client] _ in await client.cancel() }
                )

            case .resetTapped:
                state.messages = []
                state.activities = []
                state.isResponding = false
                state.activeAssistantID = nil
                state.contextFraction = nil
                state.errorMessage = nil
                return .merge(
                    .cancel(id: CancelID.response),
                    .run { [client] _ in
                        await client.reset()
                        await client.prewarm()
                    }
                )

            case let .streamEvent(event):
                switch event {
                case let .activity(activity):
                    if let index = state.activities.firstIndex(where: { $0.id == activity.id }) {
                        state.activities[index] = activity
                    } else {
                        state.activities.append(activity)
                    }
                case let .text(text):
                    guard let id = state.activeAssistantID,
                          let index = state.messages.firstIndex(where: { $0.id == id }) else { break }
                    state.messages[index].text = text
                case let .context(fraction):
                    state.contextFraction = fraction
                case .finished:
                    state.isResponding = false
                    state.activeAssistantID = nil
                }
                return .none

            case let .responseFailed(message):
                state.isResponding = false
                state.activeAssistantID = nil
                state.errorMessage = message
                return .none
            }
        }
    }
}
