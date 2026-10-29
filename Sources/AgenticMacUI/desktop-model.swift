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
        pending = sessions.first(where: { $0.id == id })?.interaction
        await refreshTranscript()
        guard let host else { return }
        observation = Task { [weak self] in
            do {
                for try await state in host.observeState(id) {
                    guard !Task.isCancelled else { break }
                    guard let self, self.selectedSession == id else { break }
                    self.pending = state.interactionRequest
                    self.activity = String(describing: state.phase)
                    await self.refreshTranscript()
                }
            } catch {
                if !Task.isCancelled { self?.activity = error.localizedDescription }
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
        activity = "Running"
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
            pending = result.interactionRequest
            await refreshTranscript()
            activity = result.isSuspended ? "Needs attention" : "Ready"
        } catch {
            activity = "Run failed: \(error.localizedDescription)"
            await refreshTranscript()
        }
    }

    func resolve(_ resolution: Run.Interaction.Resolution) async {
        guard let host, let pending, !working else { return }
        working = true
        defer { working = false }
        do {
            let result = try await host.resume(.init(request: pending, resolution: resolution))
            self.pending = result.interactionRequest
            await refreshTranscript()
            activity = result.isSuspended ? "Needs attention" : "Ready"
            answer = ""
        } catch {
            activity = "Resume failed: \(error.localizedDescription)"
        }
    }

    func cancel() async {
        guard let host, let selectedSession else { return }
        do {
            try await host.cancel(selectedSession)
            pending = nil
            working = false
            activity = "Cancelled"
            await refreshTranscript()
        } catch {
            activity = "Cancel failed: \(error.localizedDescription)"
        }
    }
}
