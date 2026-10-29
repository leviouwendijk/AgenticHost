import Agentic
import AgenticHost
import AgenticRuntime
import SwiftUI

@MainActor
public struct DesktopView: View {
    @StateObject private var model: DesktopModel

    public init(
        makeHost: @escaping @Sendable () async throws -> any AgentHost.Service
    ) {
        _model = StateObject(
            wrappedValue: DesktopModel(makeHost: makeHost)
        )
    }

    public var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Sessions").font(.headline)
                    Spacer()
                    Button {
                        Task { await model.createSession() }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("New session")
                }
                .padding()
                List {
                    ForEach(model.sessions, id: \.id) { session in
                        Button {
                            Task { await model.select(session.id) }
                        } label: {
                            HStack {
                                Text(session.title ?? "Conversation")
                                Spacer()
                                if session.interaction != nil {
                                    Image(systemName: "exclamationmark.circle")
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .fontWeight(model.selectedSession == session.id ? .semibold : .regular)
                    }
                }
            }
            .frame(minWidth: 180)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    Text(model.activity).foregroundStyle(.secondary)
                    Spacer()
                    Picker("Model", selection: $model.selectedModelID) {
                        if model.models.isEmpty {
                            Text("Unavailable").tag("")
                        }
                        ForEach(model.models, id: \.id) { profile in
                            Text(profile.title).tag(profile.id.rawValue)
                        }
                    }
                    .frame(maxWidth: 280)
                    Button("Stop") {
                        Task { await model.cancel() }
                    }
                    .disabled(model.selectedSession == nil)
                }
                .padding(12)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(model.messages) { message in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(message.role.rawValue.capitalized)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(message.content.text)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(10)
                                .background(Color.secondary.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .id(message.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: model.messages.count) { _ in
                        if let last = model.messages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                if let request = model.pending {
                    interaction(request)
                    Divider()
                }
                HStack(alignment: .bottom) {
                    TextEditor(text: $model.prompt)
                        .frame(height: 72)
                        .border(Color.gray.opacity(0.3))
                    Button("Send") {
                        Task { await model.submit() }
                    }
                    .disabled(model.working || model.pending != nil || model.selectedSession == nil || model.selectedModelID.isEmpty || model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                }
                .padding(12)
            }
        }
        .task {
            await model.connect()
        }
    }

    @ViewBuilder
    private func interaction(_ request: Run.Interaction.Request) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch request.requirement {
            case .approval(let review):
                Text("Approval required").font(.headline)
                Text(String(describing: review)).font(.caption).textSelection(.enabled)
                HStack {
                    Button("Deny") {
                        Task { await model.resolve(.approval(.denied)) }
                    }
                    Button("Approve") {
                        Task { await model.resolve(.approval(.approved)) }
                    }
                }
            case .user_input(let input):
                Text(input.prompt).font(.headline)
                switch input.input {
                case .text:
                    TextField("Answer", text: $model.answer)
                    Button("Continue") {
                        Task { await model.resolve(.user_input(.text(model.answer))) }
                    }
                case .confirmation:
                    HStack {
                        Button("No") { Task { await model.resolve(.user_input(.confirmation(false))) } }
                        Button("Yes") { Task { await model.resolve(.user_input(.confirmation(true))) } }
                    }
                default:
                    Text("This structured input requires a future native control.")
                        .foregroundStyle(.secondary)
                }
            case .workspace_access:
                Text("Workspace access requested. No grant will be issued by this basic app.")
            case .run_limit:
                Text("Run limit reached. Resume policy controls are not installed in this basic app.")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }
}
