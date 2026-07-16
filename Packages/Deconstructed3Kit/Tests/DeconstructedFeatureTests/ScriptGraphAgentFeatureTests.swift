import ComposableArchitecture
import RCP3Agent
import Testing
@testable import DeconstructedFeature

@MainActor
@Suite struct ScriptGraphAgentFeatureTests {
    @Test func inputIsReducerOwned() async {
        let store = TestStore(initialState: ScriptGraphAgentFeature.State()) {
            ScriptGraphAgentFeature(client: .testValue)
        }

        await store.send(.inputChanged("Add a tap interaction")) {
            $0.input = "Add a tap interaction"
        }
    }

    @Test func profileSelectionChangesRealCapabilityState() async {
        let store = TestStore(initialState: ScriptGraphAgentFeature.State()) {
            ScriptGraphAgentFeature(client: .testValue)
        }

        await store.send(.profileSelected(.review)) {
            $0.profile = .review
        }
        await store.finish()
        #expect(!store.state.profile.permitsMutation)
    }

    @Test func taskLoadsProfileAvailability() async {
        let expected = ScriptGraphAgentProfileStatus(
            profile: .build,
            isAvailable: true,
            detail: "Ready",
            contextSize: 4_096
        )
        var client = ScriptGraphAgentClient.testValue
        client.statuses = { [expected] }
        let store = TestStore(initialState: ScriptGraphAgentFeature.State()) {
            ScriptGraphAgentFeature(client: client)
        }

        await store.send(.task)
        await store.receive(\.statusesLoaded) {
            $0.statuses = [expected]
        }
    }
}

private extension ScriptGraphAgentClient {
    static var testValue: Self {
        Self(
            statuses: { [] },
            setProfile: { _ in },
            prewarm: {},
            stream: { _ in AsyncThrowingStream { $0.finish() } },
            cancel: {},
            reset: {}
        )
    }
}
