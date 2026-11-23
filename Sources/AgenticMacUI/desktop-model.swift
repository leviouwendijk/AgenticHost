import Agentic
import AgenticConversation
import AgenticHost
import AgenticPresentation
import AgenticRuntime
import Foundation
import SwiftUI

/// One open conversation: the engine's session and work, and the latest
/// presentation the session published.
struct DesktopConversation: Identifiable {
    let id: String
    let agentTitle: String
    let session: AgenticConversationSession
    let work: AgenticConversationWork
    var presentation: AgenticConversationSnapshot
    var running = false

    /// The first thing asked, or the agent while nothing has been.
    var title: String {
        let asked = presentation.messages
            .first { $0.role == .user }?
            .body
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let asked, !asked.isEmpty else { return "New conversation" }
        return String(asked.prefix(60))
    }

    var needsAttention: Bool {
        presentation.pendingUserInput != nil
            || !presentation.hostConsole.interruptions.isEmpty
    }
}

/// The app's state: the conversations of this launch, each driven by the
/// same engine the terminal uses. The model keeps no transcript or run
/// logic of its own; it shows what the session publishes and sends intents.
@MainActor
final class DesktopModel: ObservableObject {
    @Published private(set) var conversations: [DesktopConversation] = []
    @Published var selectedID: String?
    @Published private(set) var agents: [AgentHost.Capabilities.CatalogEntry] = []
    @Published var showingAgentPicker = false
    @Published var prompt = ""
    @Published var answer = ""
    @Published var coordinatedReview: AgentHost.CoordinatedMutationReview?
    /// Application status: startup, and failures no session reported.
    @Published private(set) var status = "Starting…"

    private let makeLaunch: @Sendable () async throws -> AgentHost.Local.Launch
    private var launch: AgentHost.Local.Launch?
    private var capabilities: AgentHost.Capabilities?
    private var observations: [String: [Task<Void, Never>]] = [:]

    init(
        makeLaunch: @escaping @Sendable () async throws -> AgentHost.Local.Launch
    ) {
        self.makeLaunch = makeLaunch
    }

    var selected: DesktopConversation? {
        conversations.first { $0.id == selectedID }
    }

    /// The selected conversation's activity, else the application's status.
    var activity: String {
        selected?.presentation.activity ?? status
    }

    func connect() async {
        guard launch == nil else { return }
        do {
            let launch = try await makeLaunch()
            self.launch = launch
            let capabilities = try await launch.host.capabilities()
            self.capabilities = capabilities
            agents = capabilities.catalogEntries.filter { $0.kind == .agent }
            guard !capabilities.models.isEmpty else {
                status = "No model profiles configured"
                return
            }
            status = "Ready"
            newConversation()
        } catch {
            status = "Startup failed: \(error.localizedDescription)"
        }
    }

    func newConversation() {
        switch agents.count {
        case 0:
            status = "No agents installed"
        case 1:
            let agent = AgentIdentifier(rawValue: agents[0].identifier)
            Task { await createConversation(agent: agent) }
        default:
            showingAgentPicker = true
        }
    }

    func agentTitle(_ agent: AgentIdentifier) -> String {
        agents.first { $0.identifier == agent.rawValue }?.title ?? agent.rawValue
    }

    func createConversation(agent: AgentIdentifier) async {
        guard let launch, let capabilities else { return }
        do {
            let id = UUID().uuidString
            let session = try await AgenticConversationSession(
                workspace: launch.workspacePath,
                service: launch.host,
                capabilities: capabilities,
                sessionID: id,
                primaryAgent: try launch.runtime.realizeAgent(identifiedBy: agent),
                textRendering: PlainConversationTextRendering()
            )
            let work = AgenticConversationWork(conversation: session)
            conversations.append(
                .init(
                    id: id,
                    agentTitle: agentTitle(agent),
                    session: session,
                    work: work,
                    presentation: await session.presentationSnapshot()
                )
            )
            selectedID = id
            showingAgentPicker = false
            observe(id, session: session, work: work)
        } catch {
            status = "Cannot start a conversation: \(error.localizedDescription)"
        }
    }

    /// Follows the session's publications, and re-reads each second so the
    /// elapsed time and the work's running state stay current.
    private func observe(
        _ id: String,
        session: AgenticConversationSession,
        work: AgenticConversationWork
    ) {
        let updates = Task { [weak self] in
            for await presentation in await session.snapshots() {
                let running = await work.snapshot().isRunning
                self?.update(id, presentation: presentation, running: running)
            }
        }
        let clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self,
                      let current = self.conversations.first(where: { $0.id == id })
                else { return }
                let running = await work.snapshot().isRunning
                guard running || current.running else { continue }
                self.update(id, presentation: await session.presentationSnapshot(), running: running)
            }
        }
        observations[id] = [updates, clock]
    }

    private func update(
        _ id: String,
        presentation: AgenticConversationSnapshot,
        running: Bool
    ) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].presentation = presentation
        conversations[index].running = running
    }

    private func refresh(_ conversation: DesktopConversation) async {
        update(
            conversation.id,
            presentation: await conversation.session.presentationSnapshot(),
            running: await conversation.work.snapshot().isRunning
        )
    }

    /// The composer: `:` runs a command, anything else is a message. A
    /// message sent during a run, or while the run waits for a decision,
    /// is queued behind it, as in the terminal.
    func send() async {
        guard let conversation = selected else { return }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        prompt = ""

        if text.hasPrefix(":") {
            do {
                _ = try await conversation.work.runCommand(String(text.dropFirst()))
            } catch {
                await conversation.session.setActivity("Command failed: \(error.localizedDescription)")
            }
            await refresh(conversation)
            return
        }

        let presentation = conversation.presentation
        let submission = AgenticConversationSubmission(
            body: text,
            contents: [],
            preferredModelProfileID: presentation.preferredModelProfileID,
            instructionIDs: presentation.selectedInstructionIDs,
            availableCapabilities: presentation.availableCapabilities,
            visibleCapabilities: presentation.visibleCapabilities,
            responseDelivery: presentation.selectedResponseDelivery,
            invocationoptions: presentation.selectedInvocationOptions,
            autonomyMode: presentation.selectedAutonomyMode
        )
        do {
            let running = await conversation.work.snapshot().isRunning
            let awaitsOperator = await conversation.session.awaitsOperator()
            if running || awaitsOperator {
                await conversation.session.notePending(submission, policy: .await)
                try await conversation.work.start(.queuedSubmission(submission))
            } else {
                await conversation.session.setActivity("invoking model")
                try await conversation.work.start(.submission(submission))
            }
        } catch {
            await conversation.session.returnUnstarted(submission, reason: error.localizedDescription)
            prompt = text
        }
        await refresh(conversation)
    }

    /// An approval, workspace access, run limit, recovery or publication
    /// decision, with one of the actions the interruption offers.
    func resolve(
        _ interruption: AgenticHostConsoleInterruptionPresentation,
        action: AgenticHostConsoleAction
    ) async {
        guard let conversation = selected else { return }
        do {
            try await conversation.work.start(
                .action(
                    interruptionID: interruption.id,
                    runID: interruption.runID,
                    stepID: interruption.stepID,
                    action: action
                )
            )
        } catch {
            await conversation.session.setActivity("Cannot \(action.title.lowercased()) now: \(error.localizedDescription)")
        }
        await refresh(conversation)
    }

    func reply(_ reply: UserInputReply) async {
        guard let conversation = selected,
              let pending = conversation.presentation.pendingUserInput
        else { return }
        do {
            try await conversation.work.start(
                .userInput(
                    interactionID: pending.interactionID,
                    runID: pending.runID,
                    reply: reply
                )
            )
            answer = ""
        } catch {
            await conversation.session.setActivity("Cannot answer now: \(error.localizedDescription)")
        }
        await refresh(conversation)
    }

    func preferModel(_ identifier: AgentModelProfileIdentifier) async {
        guard let conversation = selected, !conversation.running else { return }
        await conversation.session.preferModel(identifier)
        await refresh(conversation)
    }

    func stop() async {
        guard let conversation = selected else { return }
        guard conversation.running else {
            await conversation.session.setActivity("No active response to stop.")
            await refresh(conversation)
            return
        }
        await conversation.session.setActivity(
            "Stop requested · finishing active effect if necessary, then stopping"
        )
        do {
            try await conversation.work.interrupt(
                mode: .urgent,
                reason: "Stopped from the app."
            )
        } catch {
            await conversation.session.setActivity("Stop failed: \(error.localizedDescription)")
        }
        await refresh(conversation)
    }

    func reviewMutations() async {
        guard let launch else { return }
        do {
            coordinatedReview = try await launch.host.reviewCoordinatedMutations()
            if coordinatedReview == nil { status = "No staged changes" }
        } catch {
            status = "Review unavailable: \(error.localizedDescription)"
        }
    }

    func publishMutations() async {
        guard let launch, let coordinatedReview else { return }
        do {
            _ = try await launch.host.publishCoordinatedMutations(
                reviewID: coordinatedReview.id,
                decision: .approved
            )
            self.coordinatedReview = nil
            status = "Approved aggregate changes published"
        } catch {
            self.coordinatedReview = nil
            status = "Publication rejected; review again: \(error.localizedDescription)"
        }
    }
}
