import Agentic
import AgenticHost
import AgenticPresentation
import SwiftUI

@MainActor
public struct DesktopView: View {
    @StateObject private var model: DesktopModel

    public init(
        makeLaunch: @escaping @Sendable () async throws -> AgentHost.Local.Launch
    ) {
        _model = StateObject(
            wrappedValue: DesktopModel(makeLaunch: makeLaunch)
        )
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                if let conversation = model.selected {
                    ForEach(conversation.presentation.notices, id: \.self) { notice in
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                    }
                    if let run = currentRun(conversation) {
                        DesktopRunStatusView(run: run)
                        Divider()
                    }
                }
                if let review = model.coordinatedReview {
                    coordinatedReview(review)
                    Divider()
                }
                transcript
                if let conversation = model.selected {
                    decisions(conversation)
                }
                composer
            }
        }
        .task {
            await model.connect()
        }
        .sheet(isPresented: $model.showingAgentPicker) {
            agentPicker
        }
    }

    // MARK: sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Conversations").font(.headline)
                Spacer()
                Button {
                    model.newConversation()
                } label: {
                    Image(systemName: "plus")
                }
                .help("New conversation")
            }
            .padding()
            List {
                ForEach(model.conversations) { conversation in
                    Button {
                        model.selectedID = conversation.id
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(conversation.title).lineLimit(1)
                                Text(conversation.agentTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if conversation.running {
                                ProgressView().controlSize(.small)
                            }
                            if conversation.needsAttention {
                                Image(systemName: "exclamationmark.circle")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .fontWeight(model.selectedID == conversation.id ? .semibold : .regular)
                }
            }
        }
        .frame(minWidth: 180)
    }

    // MARK: header

    private var header: some View {
        HStack {
            if model.selected?.running == true {
                ProgressView().controlSize(.small)
            }
            Text(model.activity)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let conversation = model.selected {
                Text(conversation.agentTitle)
                    .font(.subheadline.weight(.semibold))
            }
            Spacer()
            if let conversation = model.selected {
                Picker(
                    "Model",
                    selection: Binding(
                        get: { conversation.presentation.preferredModelProfileID },
                        set: { identifier in Task { await model.preferModel(identifier) } }
                    )
                ) {
                    ForEach(conversation.presentation.models, id: \.id) { profile in
                        Text(profile.title).tag(profile.id)
                    }
                }
                .disabled(conversation.running)
                .frame(maxWidth: 280)
            }
            Button("Review edits") {
                Task { await model.reviewMutations() }
            }
            Button("Stop") {
                Task { await model.stop() }
            }
            .disabled(model.selected?.running != true)
        }
        .padding(12)
    }

    /// The newest top-level run; delegated runs show as its agents.
    private func currentRun(
        _ conversation: DesktopConversation
    ) -> AgenticHostConsoleRunPresentation? {
        conversation.presentation.hostConsole.runs.last { $0.parentID == nil }
    }

    // MARK: transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.selected?.presentation.messages ?? [], id: \.id) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(message.role.rawValue.capitalized)
                                if let pending = message.pending {
                                    Text(pending)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Text(message.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if !message.attachments.isEmpty {
                                Text("\(message.attachments.count) attachment\(message.attachments.count == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(10)
                        .background(
                            message.role == .user
                                ? Color.accentColor.opacity(0.08)
                                : Color.secondary.opacity(0.08)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .id(message.id)
                    }
                }
                .padding()
            }
            .onChange(of: model.selected?.presentation.messages.last?.body) { _ in
                if let last = model.selected?.presentation.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    // MARK: decisions

    /// What the conversation waits on: its interruptions, each with the
    /// actions it offers and the documents of its step, and a question.
    @ViewBuilder
    private func decisions(
        _ conversation: DesktopConversation
    ) -> some View {
        let console = conversation.presentation.hostConsole
        ForEach(console.interruptions, id: \.id) { interruption in
            VStack(alignment: .leading, spacing: 8) {
                Text(interruption.title).font(.headline)
                Text(interruption.summary).textSelection(.enabled)
                let documents = console.documents.filter {
                    $0.runID == interruption.runID && $0.stepID == interruption.stepID
                }
                ForEach(documents, id: \.id) { document in
                    DisclosureGroup(document.title) {
                        ScrollView {
                            Text(document.body)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 240)
                    }
                }
                HStack {
                    ForEach(interruption.actions, id: \.self) { action in
                        Button(action.title) {
                            Task { await model.resolve(interruption, action: action) }
                        }
                    }
                }
                .disabled(conversation.running)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
            Divider()
        }
        if let pending = conversation.presentation.pendingUserInput {
            question(pending)
            Divider()
        }
    }

    @ViewBuilder
    private func question(
        _ pending: AgenticConversationUserInputPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(pending.request.prompt).font(.headline)
            switch pending.request.input {
            case .text:
                TextField("Answer", text: $model.answer)
                Button("Continue") {
                    Task { await model.reply(.answer(.text(model.answer))) }
                }
            case .confirmation:
                HStack {
                    Button("No") { Task { await model.reply(.answer(.confirmation(false))) } }
                    Button("Yes") { Task { await model.reply(.answer(.confirmation(true))) } }
                }
            default:
                Text("This question needs a control the app does not have yet; answer it in the terminal or skip it.")
                    .foregroundStyle(.secondary)
            }
            Button("Skip") {
                Task { await model.reply(.skip) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }

    // MARK: composer

    private var composer: some View {
        HStack(alignment: .bottom) {
            TextEditor(text: $model.prompt)
                .frame(height: 72)
                .border(Color.gray.opacity(0.3))
            Button("Send") {
                Task { await model.send() }
            }
            .disabled(
                model.selected == nil
                    || model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(12)
    }

    // MARK: sheets

    private func coordinatedReview(
        _ review: AgentHost.CoordinatedMutationReview
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Coordinated changes awaiting publication")
                .font(.headline)
            Text("\(review.submissionIDs.count) independent submissions")
                .font(.caption)
            ScrollView {
                ForEach(review.plan?.entries ?? [], id: \.id) { entry in
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
    }

    private var agentPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose an agent").font(.title2.weight(.semibold))
            Text("Each conversation belongs to one installed agent.")
                .foregroundStyle(.secondary)
            ForEach(model.agents) { agent in
                Button {
                    Task {
                        await model.createConversation(
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
