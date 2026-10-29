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
    @Published var selectedModelID = ""
    @Published var prompt = ""
    @Published var answer = ""
    @Published var pending: Run.Interaction.Request?
    @Published var activity = "Starting…"
    @Published var working = false
    @Published var runState: AgentRunStateSnapshot?
    @Published var liveAssistantText = ""

    private let makeHost: @Sendable () async throws -> any AgentHost.Service
    private var host: (any AgentHost.Service)?
    private var observation: Task<Void, Never>?

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
            selectedModelID = capabilities.defaultExecution.modelSelection?
                .preferences.preferredProfileIdentifier?.rawValue
                ?? capabilities.models.first?.id.rawValue
                ?? ""
            sessions = try await service.sessions()
            if let first = sessions.first {
                await select(first.id)
            } else {
                await createSession()
            }
            activity = models.isEmpty ? "No model profiles configured" : "Ready"
        } catch {
            activity = "Startup failed: \(error.localizedDescription)"
        }
    }

    func createSession() async {
        guard let host else { return }
        do {
            let summary = try await host.start(.init(title: "Conversation"))
            sessions = try await host.sessions()
            await select(summary.id)
        } catch {
            activity = "Cannot create session: \(error.localizedDescription)"
        }
    }

    func select(_ id: AgentHost.Session.ID) async {
        observation?.cancel()
        selectedSession = id
        runState = nil
        liveAssistantText = ""
        pending = sessions.first(where: { $0.id == id })?.interaction
        await refreshTranscript()
        guard let host else { return }
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
        guard let host, let selectedSession, !working, pending == nil else { return }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !selectedModelID.isEmpty else { return }
        working = true
        prompt = ""
        runState = nil
        liveAssistantText = ""
        activity = "Invoking model"
        defer { working = false }
        do {
            let selection = AgentModelSelection(
                purpose: .executor,
                preferences: .init(preferredProfileIdentifier: .init(selectedModelID))
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
        guard let host, let pending, !working else { return }
        let session = selectedSession
        working = true
        defer { working = false }
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
            working = false
            liveAssistantText = ""
            activity = "Cancelled"
            await refreshTranscript()
        } catch {
            activity = "Cancel failed: \(error.localizedDescription)"
        }
    }
}
