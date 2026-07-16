import ComposableArchitecture
import RCP3Agent
import RCP3GraphEditor
import SwiftUI

/// Lazily creates one agent session for one live canvas model.
public struct ScriptGraphAgentWorkspaceHost: View {
    private let model: ScriptGraphEditorModel
    private let hostActions: ScriptGraphAgentHostActions
    @State private var store: StoreOf<ScriptGraphAgentFeature>?

    public init(
        model: ScriptGraphEditorModel,
        hostActions: ScriptGraphAgentHostActions
    ) {
        self.model = model
        self.hostActions = hostActions
    }

    public var body: some View {
        Group {
            if let store {
                ScriptGraphAgentWorkspaceView(store: store)
            } else {
                ProgressView("Preparing Script Graph agent…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            guard store == nil else { return }
            let executor = ScriptGraphAgentExecutor(model: model, hostActions: hostActions)
            let session = ScriptGraphAgentSession(executor: executor)
            let client = ScriptGraphAgentClient.live(session: session)
            store = Store(initialState: ScriptGraphAgentFeature.State()) {
                ScriptGraphAgentFeature(client: client)
            }
        }
    }
}

public struct ScriptGraphAgentWorkspaceView: View {
    @Bindable var store: StoreOf<ScriptGraphAgentFeature>

    public init(store: StoreOf<ScriptGraphAgentFeature>) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            AgentProfileHeader(store: store)
            Divider()
            AgentConversation(store: store)
            Divider()
            AgentComposer(store: store)
        }
        .navigationTitle("Script Graph Agent")
        .task { store.send(.task) }
    }
}

private struct AgentProfileHeader: View {
    let store: StoreOf<ScriptGraphAgentFeature>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Agent", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Menu {
                    ForEach(ScriptGraphAgentProfile.allCases) { profile in
                        Button {
                            store.send(.profileSelected(profile))
                        } label: {
                            Label(
                                profile.displayName,
                                systemImage: store.profile == profile ? "checkmark" : profileSymbol(profile)
                            )
                        }
                        .disabled(status(for: profile)?.isAvailable == false)
                    }
                } label: {
                    Label(store.profile.displayName, systemImage: profileSymbol(store.profile))
                }
                .menuStyle(.borderlessButton)

                Button("Reset", systemImage: "arrow.counterclockwise") {
                    store.send(.resetTapped)
                }
                .labelStyle(.iconOnly)
                .help("Start a new agent conversation")
            }

            Text(store.profile.summary)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                ForEach(Array(store.profile.toolIDs).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { tool in
                    Text(toolLabel(tool))
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if let fraction = store.contextFraction {
                    Text("Context \(Int(fraction * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(fraction > 0.8 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
            }

            if let status = status(for: store.profile) {
                Label(status.detail, systemImage: status.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(status.isAvailable ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            }
        }
        .padding(12)
    }

    private func status(for profile: ScriptGraphAgentProfile) -> ScriptGraphAgentProfileStatus? {
        store.statuses.first { $0.profile == profile }
    }

    private func profileSymbol(_ profile: ScriptGraphAgentProfile) -> String {
        switch profile {
        case .review: "eye"
        case .build: "hammer"
        case .deepBuild: "cloud"
        }
    }

    private func toolLabel(_ tool: ScriptGraphAgentToolID) -> String {
        switch tool {
        case .inspect: "Inspect"
        case .edit: "Edit"
        case .compile: "Validate"
        case .workspace: "Run"
        }
    }
}

private struct AgentConversation: View {
    let store: StoreOf<ScriptGraphAgentFeature>

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if store.messages.isEmpty {
                    AgentEmptyState(store: store)
                } else {
                    ForEach(store.messages) { message in
                        AgentMessageRow(message: message)
                    }
                }

                ForEach(store.activities) { activity in
                    AgentActivityRow(activity: activity)
                }

                if let error = store.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AgentEmptyState: View {
    let store: StoreOf<ScriptGraphAgentFeature>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Author the live graph", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)
            Text("The agent inspects and edits the same unsaved canvas you see. Start with a concrete outcome or ask it to review the current graph.")
                .font(.caption)
                .foregroundStyle(.secondary)

            suggestion("Review this graph and list concrete problems.")
            suggestion("Add a tap interaction, connect it, then validate the graph.")
            suggestion("Explain what this graph compiles to without changing it.")
        }
        .padding(.vertical, 8)
    }

    private func suggestion(_ prompt: String) -> some View {
        Button(prompt) {
            store.send(.inputChanged(prompt))
        }
        .buttonStyle(.link)
        .font(.caption)
    }
}

private struct AgentMessageRow: View {
    let message: ScriptGraphAgentMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 28) }
            VStack(alignment: .leading, spacing: 4) {
                Text(message.role == .user ? "You" : "Agent")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                if message.text.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(message.text)
                        .textSelection(.enabled)
                }
            }
            .padding(9)
            .background(message.role == .user ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
            if message.role != .user { Spacer(minLength: 28) }
        }
    }
}

private struct AgentActivityRow: View {
    let activity: ScriptGraphAgentActivity

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.summary)
                    .font(.caption.weight(.medium))
                if let detail = activity.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var symbol: String {
        switch activity.phase {
        case .started: "circle.dotted"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch activity.phase {
        case .started: .secondary
        case .completed: .green
        case .failed: .red
        }
    }
}

private struct AgentComposer: View {
    @Bindable var store: StoreOf<ScriptGraphAgentFeature>

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                "Describe a graph change or ask for a review…",
                text: $store.input.sending(\.inputChanged),
                axis: .vertical
            )
            .lineLimit(1...5)
            .textFieldStyle(.roundedBorder)
            .disabled(store.isResponding)

            if store.isResponding {
                Button("Stop", systemImage: "stop.fill") {
                    store.send(.cancelTapped)
                }
                .labelStyle(.iconOnly)
                .help("Stop the response")
            } else {
                Button("Send", systemImage: "arrow.up.circle.fill") {
                    store.send(.sendTapped)
                }
                .labelStyle(.iconOnly)
                .disabled(store.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(12)
    }
}
