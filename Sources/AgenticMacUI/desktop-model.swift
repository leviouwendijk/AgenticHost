import Agentic
import AgenticHost
import AgenticRuntime
import Foundation
import SwiftUI

@MainActor
final class DesktopModel: ObservableObject {
    @Published var sessions: [AgentHost.Session.Summary] = []
    @Published var selectedSession: AgentHost.Session.ID?
    @Published var messages: [Message] = []
    @Published var models: [AgentHost.Capabilities.Model] = []
    @Published var agents: [AgentHost.Capabilities.CatalogEntry] = []
    @Published var showingAgentPicker = false
    @Published var selectedModelID = "" {
        didSet {
            guard let selectedSession else { return }
            if selectedModelID.isEmpty {
                modelOverrides.removeValue(forKey: selectedSession)
            } else {
                modelOverrides[selectedSession] = selectedModelID
            }
        }
    }
    @Published var prompt = ""
    @Published var answer = ""
    @Published var pending: Run.Interaction.Request?
    @Published var activity = "Starting…"
    @Published private(set) var busySessions: Set<AgentHost.Session.ID> = []

    var working: Bool {
        selectedSession.map { busySessions.contains($0) } ?? false
    }
    @Published var runState: AgentRunStateSnapshot?
    @Published var liveAssistantText = ""

    private let makeHost: @Sendable () async throws -> any AgentHost.Service
    private var host: (any AgentHost.Service)?
    private var observation: Task<Void, Never>?
    private var modelOverrides: [AgentHost.Session.ID: String] = [:]

    init(
        makeHost: @escaping @Sendable () async throws -> any AgentHost.Service
    ) {
        self.makeHost = makeHost
    }

    func connect() async {
        guard host == nil else { return }
        do {
            let service = try await makeHost()
            host = service
            let capabilities = try await service.capabilities()
            models = capabilities.models
            agents = capabilities.catalogEntries.filter { $0.kind == .agent }
            activity = agents.isEmpty ? "No agents installed" :
                (models.isEmpty ? "No model profiles configured" : "Ready")
            sessions = try await service.sessions()
            if let first = sessions.first {
                await select(first.id)
            } else {
                await createSession()
            }
        } catch {
            activity = "Startup failed: \(error.localizedDescription)"
        }
    }

    func createSession() async {
        guard host != nil else { return }
        if agents.count == 1 {
            await createSession(agent: AgentIdentifier(rawValue: agents[0].identifier))
        } else if agents.isEmpty {
            activity = "No agents installed"
        } else {
            showingAgentPicker = true
        }
    }

    func createSession(agent: AgentIdentifier) async {
        guard let host else { return }
        guard agents.contains(where: { $0.identifier == agent.rawValue }) else {
            activity = "Selected agent is not installed"
            return
        }
        do {
            let summary = try await host.start(
                .init(title: "Conversation", agent: agent)
            )
            sessions = try await host.sessions()
            showingAgentPicker = false
            await select(summary.id)
        } catch {
            activity = "Cannot create session: \(error.localizedDescription)"
        }
    }

    func agentTitle(_ agent: AgentIdentifier?) -> String {
        guard let agent else { return "Unassigned agent" }
        return agents.first(where: { $0.identifier == agent.rawValue })?.title
            ?? agent.rawValue
    }

    var currentAgentTitle: String {
        agentTitle(sessions.first(where: { $0.id == selectedSession })?.agent)
    }

    func select(_ id: AgentHost.Session.ID) async {
        observation?.cancel()
        selectedSession = id
        selectedModelID = modelOverrides[id] ?? ""
        activity = sessions.first(where: { $0.id == id })?.interaction != nil
            ? "Needs attention" : (busySessions.contains(id) ? "Running" : "Ready")
        runState = nil
        liveAssistantText = ""
        // A different conversation may finish or suspend while offscreen.
        // Reconcile host-owned summaries before restoring its interaction.
        if let host {
            do {
                let latest = try await host.sessions()
                guard selectedSession == id else { return }
                sessions = latest
            } catch {
                guard selectedSession == id else { return }
                activity = "Session list unavailable: \(error.localizedDescription)"
            }
        }
        pending = sessions.first(where: { $0.id == id })?.interaction
        if pending != nil { activity = "Needs attention" }
        await refreshTranscript()
        guard let host, selectedSession == id else { return }
        // Create the stream before launching the observer so registration
        // precedes a subsequent submit on the selected session.
        let stream = host.observeState(id)
        observation = Task { [weak self] in
            do {
                for try await state in stream {
                    guard !Task.isCancelled else { return }
                    guard let self, self.selectedSession == id else { return }
                    self.apply(state)
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled, let self, self.selectedSession == id {
                    self.activity = "Observation failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func refreshTranscript() async {
        guard let host, let selectedSession else { return }
        do {
            let transcript = try await host.transcript(selectedSession)
            guard self.selectedSession == selectedSession else { return }
            messages = transcript.messages.filter { $0.role != .system }
        } catch {
            activity = "Transcript unavailable: \(error.localizedDescription)"
        }
    }

    func submit() async {
        guard let host, let selectedSession,
              !busySessions.contains(selectedSession), pending == nil else { return }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let overrideID = selectedModelID
        busySessions.insert(selectedSession)
        prompt = ""
        runState = nil
        liveAssistantText = ""
        activity = "Invoking model"
        defer { busySessions.remove(selectedSession) }
        do {
            let selection: AgentModelSelection? = overrideID.isEmpty ? nil : .init(
                purpose: .executor,
                preferences: .init(preferredProfileIdentifier: .init(overrideID))
            )
            let execution = AgentHost.Session.Execution(modelSelection: selection)
            let result = try await host.submit(
                .init(session: selectedSession, prompt: text, execution: execution)
            )
            guard self.selectedSession == selectedSession else { return }
            pending = result.interactionRequest
            await refreshTranscript()
            liveAssistantText = ""
            activity = result.isSuspended ? "Needs attention" : "Ready"
        } catch {
            if self.selectedSession == selectedSession {
                activity = "Run failed: \(error.localizedDescription)"
                liveAssistantText = ""
                await refreshTranscript()
            }
        }
    }

    func resolve(_ resolution: Run.Interaction.Resolution) async {
        guard let host, let pending, let session = selectedSession,
              !busySessions.contains(session) else { return }
        busySessions.insert(session)
        defer { busySessions.remove(session) }
        do {
            let result = try await host.resume(.init(request: pending, resolution: resolution))
            guard selectedSession == session else { return }
            self.pending = result.interactionRequest
            await refreshTranscript()
            liveAssistantText = ""
            activity = result.isSuspended ? "Needs attention" : "Ready"
            answer = ""
        } catch {
            if selectedSession == session {
                activity = "Resume failed: \(error.localizedDescription)"
            }
        }
    }

    private func apply(_ state: AgentRunStateSnapshot) {
        runState = state
        // The checkpoint already carries the transcript. Do not refetch it
        // for every streamed token; a transcript read belongs to initial load
        // and terminal reconciliation only.
        messages = state.state.messages.filter { $0.role != .system }
        pending = state.interactionRequest

        let partial = state.partialResponse?.message.content.text ?? ""
        let partialID = state.partialResponse?.messageID
        let alreadyCommitted = partialID.map { id in
            messages.contains(where: { $0.id == id })
        } ?? false
        liveAssistantText = alreadyCommitted ? "" : partial

        if state.pendingUserInput != nil {
            activity = "Awaiting user input"
        } else if state.pendingApproval != nil {
            activity = "Awaiting approval"
        } else if state.pendingRunLimit != nil {
            activity = "Run limit reached"
        } else if state.suspension != nil {
            activity = "Suspended"
        } else {
            switch state.phase {
            case .ready_for_model: activity = "Invoking model"
            case .receiving_model_response: activity = "Streaming response"
            case .processing_tool_calls: activity = "Processing tools"
            case .awaiting_approval: activity = "Awaiting approval"
            case .suspended: activity = "Suspended"
            case .interrupted: activity = "Interrupted"
            case .failed: activity = "Failed"
            case .completed: activity = "Completed"
            }
        }
        if let failure = state.failure { activity = "Failed: \(failure.message)" }
    }

    func cancel() async {
        guard let host, let selectedSession else { return }
        do {
            try await host.cancel(selectedSession)
            pending = nil
            liveAssistantText = ""
            activity = "Cancelled"
            await refreshTranscript()
        } catch {
            activity = "Cancel failed: \(error.localizedDescription)"
        }
    }
}
