import Agentic
import AgenticHost
import AgenticRuntime
import Foundation
import SwiftUI

@MainActor
public struct DesktopView: View {
    @StateObject private var model: DesktopModel
    @State private var showsWorkspaceDetails = true

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
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(session.title ?? "Conversation")
                                    Text(model.agentTitle(session.agent))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.busySessions.contains(session.id) {
                                    ProgressView().controlSize(.small)
                                }
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
                    if model.working {
                        ProgressView().controlSize(.small)
                    }
                    Text(model.activity).foregroundStyle(.secondary)
                    if model.selectedSession != nil {
                        Text(model.currentAgentTitle)
                            .font(.subheadline.weight(.semibold))
                    }
                    Spacer()
                    Picker("Model", selection: $model.selectedModelID) {
                        Text("Agent default").tag("")
                        ForEach(model.models, id: \.id) { profile in
                            Text(profile.title).tag(profile.id.rawValue)
                        }
                    }
                    .disabled(model.selectedSession == nil)
                    .frame(maxWidth: 280)
                    Button("Workers") {
                        Task { await model.refreshWorkers() }
                    }
                    .disabled(model.selectedSession == nil)
                    Button("Review edits") {
                        Task { await model.reviewMutations() }
                    }
                    Button("Stop") {
                        Task { await model.cancel() }
                    }
                    .disabled(model.selectedSession == nil)
                }
                .padding(12)
                Divider()
                if let state = model.runState {
                    DesktopRunStatusView(snapshot: state)
                    Divider()
                }
                if !model.delegatedWorkers.isEmpty {
                    DisclosureGroup("Delegated workers (\(model.delegatedWorkers.count))") {
                        ForEach(model.delegatedWorkers, id: \.session.id) { worker in
                            HStack(alignment: .firstTextBaseline) {
                                Text(worker.session.agent.rawValue)
                                Text(worker.requestedScope ?? "Unscoped")
                                    .font(.caption.monospaced())
                                Spacer()
                                Text(worker.phase?.rawValue ?? (worker.executing ? "running" : "queued"))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(10)
                    Divider()
                }
                if let review = model.coordinatedReview {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Coordinated changes awaiting publication")
                            .font(.headline)
                        Text("\(review.submissionIDs.count) independent submissions")
                            .font(.caption)
                        ScrollView {
                            ForEach(review.plan.entries, id: \.id) { entry in
                                DisclosureGroup(entry.target.path) {
                                    Text("Before:\n\(entry.before.textContent ?? "<not text>")\n\nAfter:\n\(entry.after.textContent ?? "<deleted>")")
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .frame(maxHeight: 240)
                        HStack {
                            Button("Close preview") { model.coordinatedReview = nil }
                            Spacer()
                            Button("Approve and publish") {
                                Task { await model.publishMutations() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(12)
                    Divider()
                }
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
                            if !model.liveAssistantText.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label("Assistant · streaming", systemImage: "waveform")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(model.liveAssistantText)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(10)
                                .background(Color.accentColor.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .id("live-response")
                            }
                        }
                        .padding()
                    }
                    .onChange(of: model.messages.count) { _ in
                        if let last = model.messages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                    .onChange(of: model.liveAssistantText) { text in
                        if !text.isEmpty {
                            proxy.scrollTo("live-response", anchor: .bottom)
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
                    .disabled(model.working || model.pending != nil || model.selectedSession == nil || model.models.isEmpty || model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                }
                .padding(12)
            }
        }
        .task {
            await model.connect()
        }
        .sheet(isPresented: $model.showingAgentPicker) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose an agent").font(.title2.weight(.semibold))
                Text("Each conversation belongs to one installed agent.")
                    .foregroundStyle(.secondary)
                ForEach(model.agents) { agent in
                    Button {
                        Task {
                            await model.createSession(
                                agent: AgentIdentifier(rawValue: agent.identifier)
                            )
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(agent.title).font(.headline)
                            if !agent.summary.isEmpty {
                                Text(agent.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { model.showingAgentPicker = false }
                }
            }
            .padding(20)
            .frame(minWidth: 420)
        }
    }

    private func encodedDetails<Value: Encodable>(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else {
            return String(describing: value)
        }
        return String(decoding: data, as: UTF8.self)
    }

    @ViewBuilder
    private func interaction(_ request: Run.Interaction.Request) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let lineage = request.metadata["delegation_path"]
                ?? request.metadata["delegated_child_session_id"] {
                Text("Worker request: \(lineage)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            switch request.requirement {
            case .approval(let review):
                Text("Approval required").font(.headline)
                Text(review.functionCall.name).font(.subheadline.monospaced())
                Text(review.preflight.summary).textSelection(.enabled)
                Text("Risk: \(review.preflight.risk.rawValue)")
                    .font(.caption).foregroundStyle(.secondary)
                if !review.preflight.access.targets.isEmpty {
                    Text(review.preflight.access.targets.joined(separator: "\n"))
                        .font(.caption.monospaced()).textSelection(.enabled)
                }
                DisclosureGroup("Full preflight") {
                    Text(encodedDetails(review.preflight))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Skip") { Task { await model.resolve(.approval(.skipped)) } }
                    Button("Deny") { Task { await model.resolve(.approval(.denied)) } }
                    Button("Approve") { Task { await model.resolve(.approval(.approved)) } }
                }
                .disabled(model.working)
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
            case .workspace_access(let access):
                Text("Workspace access requested").font(.headline)
                Text("Review the exact requested authority before granting access.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Request details", isExpanded: $showsWorkspaceDetails) {
                    Text(encodedDetails(access))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Deny") { Task { await model.resolve(.workspace_access(.deny)) } }
                    if request.metadata["delegated_child_session_id"] == nil {
                        Button("Grant for turn") {
                            Task { await model.resolve(.workspace_access(.grant_for_turn)) }
                        }
                        Button("Grant for session") {
                            Task { await model.resolve(.workspace_access(.grant_for_session)) }
                        }
                    } else {
                        Text("Child workspace expansion is disabled; reassign a broader scope from the orchestrator.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(model.working)
            case .run_limit(let exhaustion):
                Text("Run limit reached").font(.headline)
                Text(exhaustion.summary).textSelection(.enabled)
                switch exhaustion {
                case .iterations(_, let consumed):
                    HStack {
                        Button("Stop run") { Task { await model.resolve(.run_limit(.stop)) } }
                        Button("+4 iterations") {
                            Task { await model.resolve(.run_limit(.continue_with(.init(iterations: consumed + 4)))) }
                        }
                        Button("+12 iterations") {
                            Task { await model.resolve(.run_limit(.continue_with(.init(iterations: consumed + 12)))) }
                        }
                        Button("Unlimited") {
                            Task { await model.resolve(.run_limit(.continue_with(.unlimited))) }
                        }
                    }
                    .disabled(model.working)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }
}
