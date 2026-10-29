import Agentic
import AgenticHost
import AgenticInterfaces
import AgenticRuntime
import Clipboard
import Foundation
import Terminal

/// The single terminal owner for one or many independent Agent conversations.
/// View selection never owns, cancels, or reconfigures a conversation's work.
@MainActor
package final class AgenticWorkConsole {
    private struct Conversation {
        let id: String
        let agent: AgentIdentifier
        let session: AgenticConversationSession
        let work: AgenticConversationWork
        var control: AgenticConversationControl
        var seenCompletedGeneration = 0
        var queuedSubmission: AgenticConversationSubmission?
        var lastWorkState: AgenticConversationWork.Snapshot?
    }

    private enum View {
        case dashboard
        case agentPicker
        case conversation(String)
        case exitConfirmation
    }

    private let runtime: AgenticRuntime
    private let service: any AgentHost.Service
    private let capabilities: AgentHost.Capabilities
    private let workspace: String
    private let voiceInput: (any VoiceInputProvider)?
    private var conversations: [Conversation] = []
    private var view: View = .dashboard
    private var dashboardIndex = 0
    private var pickerIndex = 0
    private var pendingPickerSessionID: String?
    private var notice: String?

    package init(
        runtime: AgenticRuntime,
        service: any AgentHost.Service,
        capabilities: AgentHost.Capabilities,
        workspace: String,
        voiceInput: (any VoiceInputProvider)? = nil
    ) {
        self.runtime = runtime
        self.service = service
        self.capabilities = capabilities
        self.workspace = workspace
        self.voiceInput = voiceInput
    }

    package var installedAgents: [AgentDefinition] {
        runtime.agents.definitions.sorted {
            $0.identifier.rawValue < $1.identifier.rawValue
        }
    }

    package var sessionIDs: [String] {
        conversations.map(\.id)
    }

    package var selectedSessionID: String? {
        if case .conversation(let id) = view { return id }
        return nil
    }

    /// Creates a session using an installed Agent's actual realization, not a
    /// launch entry or a second registry of Agent declarations.
    @discardableResult
    package func create(
        agent identifier: AgentIdentifier,
        sessionID: String? = nil
    ) async throws -> String {
        let realization = try runtime.realizeAgent(identifiedBy: identifier)
        let id = sessionID ?? UUID().uuidString
        guard !conversations.contains(where: { $0.id == id }) else {
            throw Failure.duplicateSession(id)
        }
        let session = try AgenticConversationSession(
            workspace: workspace,
            service: service,
            capabilities: capabilities,
            sessionID: id,
            primaryAgent: realization
        )
        await session.setVoiceAvailability(
            await voiceInput?.availability() ?? .unconfigured
        )
        let work = AgenticConversationWork(conversation: session)
        let control = AgenticConversationControl(
            snapshot: await session.presentationSnapshot()
        )
        conversations.append(.init(
            id: id,
            agent: identifier,
            session: session,
            work: work,
            control: control
        ))
        view = .conversation(id)
        return id
    }

    package enum Failure: Error {
        case duplicateSession(String)
        case unknownSession(String)
        case noInstalledAgents
    }

    package func select(_ id: String) throws {
        guard conversations.contains(where: { $0.id == id }) else {
            throw Failure.unknownSession(id)
        }
        view = .conversation(id)
    }

    package func showDashboard() {
        pendingPickerSessionID = nil
        view = .dashboard
    }

    private func showAgentPicker(initialSessionID: String? = nil) {
        pickerIndex = 0
        pendingPickerSessionID = initialSessionID
        view = .agentPicker
    }

    package var isExitConfirmationPresented: Bool {
        if case .exitConfirmation = view { return true }
        return false
    }

    /// Only an explicit quit confirmation can terminate a foreground console
    /// while one or more conversations still have in-flight work.
    package func requestExit() async -> Bool {
        for item in conversations {
            if await item.work.snapshot().isRunning {
                view = .exitConfirmation
                return false
            }
        }
        return true
    }

    package func work(for id: String) throws -> AgenticConversationWork {
        guard let conversation = conversations.first(where: { $0.id == id }) else {
            throw Failure.unknownSession(id)
        }
        return conversation.work
    }

    package func session(for id: String) throws -> AgenticConversationSession {
        guard let conversation = conversations.first(where: { $0.id == id }) else {
            throw Failure.unknownSession(id)
        }
        return conversation.session
    }

    /// Both CLI commands enter this exact implementation. `work` is empty;
    /// `conversation` preselects an installed primary Agent, then remains free
    /// to return to the dashboard and create more conversations.
    package static func launch<Application: AgenticApplicationProviding>(
        _ application: Application.Type,
        workspace configuration: AgenticRuntimeWorkspaceConfiguration,
        voiceInput: (any VoiceInputProvider)?,
        startConversation: Bool,
        preferredAgent: AgentIdentifier? = nil,
        sessionID: String? = nil
    ) async throws {
        let runtime = try await AgenticRuntime.resolve(application)
        let workspace = try AgenticRuntimeWorkspace.resolve(configuration)
        let service: any AgentHost.Service = AgentHost.Local(
            runtime: runtime,
            workspace: workspace
        )
        let capabilities = try await service.capabilities()
        let primary = startConversation
            ? try entryAgent(runtime: runtime, explicit: preferredAgent)
            : nil
        try await run(
            runtime: runtime,
            service: service,
            capabilities: capabilities,
            workspace: configuration.path,
            voiceInput: voiceInput,
            initialAgent: primary,
            initialSessionID: sessionID,
            selectAgentOnEntry: startConversation && primary == nil
        )
    }

    /// A shortcut must not silently bind a conversation to an unrelated Agent.
    /// A unique installation is unambiguous; multiple Agents require selection.
    package static func entryAgent(
        runtime: AgenticRuntime,
        explicit identifier: AgentIdentifier? = nil
    ) throws -> AgentIdentifier? {
        if let identifier {
            _ = try runtime.realizeAgent(identifiedBy: identifier)
            return identifier
        }
        let installed = runtime.agents.definitions
        guard !installed.isEmpty else { throw Failure.noInstalledAgents }
        return installed.count == 1 ? installed[0].identifier : nil
    }

    package static func run(
        runtime: AgenticRuntime,
        service: any AgentHost.Service,
        capabilities: AgentHost.Capabilities,
        workspace: String,
        voiceInput: (any VoiceInputProvider)?,
        initialAgent: AgentIdentifier? = nil,
        initialSessionID: String? = nil,
        selectAgentOnEntry: Bool = false
    ) async throws {
        let console = Self(
            runtime: runtime,
            service: service,
            capabilities: capabilities,
            workspace: workspace,
            voiceInput: voiceInput
        )
        if let initialAgent {
            try await console.create(agent: initialAgent, sessionID: initialSessionID)
        } else if selectAgentOnEntry {
            console.showAgentPicker(initialSessionID: initialSessionID)
        }
        try await console.run()
    }

    private func run() async throws {
        let stream = TerminalStream.standardError
        let terminalSession = try TerminalSession(
            options: TerminalSession.Options(
                useAlternateScreen: true,
                hideCursor: true,
                useRawMode: true,
                useBracketedPaste: true,
                keyboardProtocol: .kitty,
                controlSignalBehavior: .input,
                restoreOnInterrupt: true,
                outputStream: stream
            )
        )
        defer { terminalSession.restore() }

        let reader = TerminalKeyReader()
        var renderer = TerminalFrameRenderer(stream: stream)
        while true {
            await refreshConversations()
            let size = Terminal.size(for: stream)
            var frame = TerminalFrame(rows: size.rows, columns: size.columns)
            render(into: &frame, rows: size.rows, columns: size.columns)
            renderer.render(frame)

            let events = reader.readEvents(
                timeoutMilliseconds: 100,
                maximumCount: 128
            )
            for event in events {
                do {
                    if try await handle(event) { return }
                } catch {
                    let message = "Operation failed: \(error.localizedDescription)"
                    notice = message
                    if case .conversation(let id) = view,
                       let index = conversations.firstIndex(where: { $0.id == id }) {
                        await conversations[index].session.setActivity(message)
                        conversations[index].control.update(
                            await conversations[index].session.presentationSnapshot()
                        )
                    }
                }
            }
        }
    }

    private func render(into frame: inout TerminalFrame, rows: Int, columns: Int) {
        guard rows > 0, columns > 0 else { return }
        switch view {
        case .dashboard:
            var lines = [
                "Agentic Work · sessions \(conversations.count)",
                "n new conversation · j/k select · Enter open · q quit",
                "",
            ]
            if conversations.isEmpty {
                lines.append("No conversations yet. Press n to select an installed Agent.")
            }
            for (index, item) in conversations.enumerated() {
                let marker = index == dashboardIndex ? ">" : " "
                let activity = item.lastWorkState?.isRunning == true
                    ? "running"
                    : (item.control.snapshot.activity ?? "idle")
                lines.append("\(marker) \(index + 1). \(item.agent.rawValue) · \(item.id) · \(activity)")
            }
            if let notice { lines.append(""); lines.append(notice) }
            frame.write(lines.joined(separator: "\n"), in: .init(rows: rows, columns: columns))

        case .agentPicker:
            var lines = [
                "New conversation · installed Agents",
                "j/k select · Enter create · Esc dashboard",
                "",
            ]
            if installedAgents.isEmpty {
                lines.append("No installed Agents. Install an Agent in the application first.")
            }
            for (index, agent) in installedAgents.enumerated() {
                let marker = index == pickerIndex ? ">" : " "
                lines.append("\(marker) \(agent.identifier.rawValue)")
            }
            if let notice { lines.append(""); lines.append(notice) }
            frame.write(lines.joined(separator: "\n"), in: .init(rows: rows, columns: columns))

        case .exitConfirmation:
            let running = conversations.filter { $0.lastWorkState?.isRunning == true }.count
            let lines = [
                "Exit Agentic Work?",
                "\(running) conversation operation(s) may still be running.",
                "q or Enter: exit process · Esc: return to dashboard",
                "Exiting the process is NOT equivalent to switching views.",
            ]
            frame.write(lines.joined(separator: "\n"), in: .init(rows: rows, columns: columns))

        case .conversation(let id):
            guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
            let item = conversations[index]
            let heading = "Agentic Work · \(item.agent.rawValue) · \(index + 1)/\(conversations.count) · Ctrl-W sessions · Ctrl-N new · Ctrl-P next"
            frame.write(heading, in: .init(rows: 1, columns: columns))
            guard rows > 1 else { return }
            conversations[index].control.render(
                into: &frame,
                in: TerminalRegion(
                    top: 1,
                    leading: 0,
                    rows: rows - 1,
                    columns: columns
                )
            )
        }
    }

    private func key(_ input: TerminalInputEvent) -> TerminalKey? {
        switch input {
        case .key(let key): return key
        case .keyStroke(let stroke): return stroke.key
        case .paste: return nil
        }
    }

    /// Returns true only when the terminal application itself should exit.
    private func handle(_ input: TerminalInputEvent) async throws -> Bool {
        let pressed = key(input)
        if case .exitConfirmation = view {
            switch pressed {
            case .char("q"), .enter: return true
            case .escape: showDashboard()
            default: break
            }
            return false
        }
        if pressed == .control("W") {
            if await canNavigate() { showDashboard() }
            return false
        }
        if pressed == .control("N") {
            if await canNavigate() { showAgentPicker() }
            return false
        }
        if pressed == .control("P") {
            if await canNavigate(), !conversations.isEmpty {
                let current = selectedSessionID.flatMap { id in
                    conversations.firstIndex(where: { $0.id == id })
                } ?? -1
                let next = (current + 1) % conversations.count
                view = .conversation(conversations[next].id)
            }
            return false
        }

        switch view {
        case .dashboard:
            switch pressed {
            case .char("q"), .escape: return await requestExit()
            case .char("n"), .char("a"): showAgentPicker()
            case .char("j"), .down:
                dashboardIndex = min(max(conversations.count - 1, 0), dashboardIndex + 1)
            case .char("k"), .up:
                dashboardIndex = max(0, dashboardIndex - 1)
            case .enter:
                if conversations.indices.contains(dashboardIndex) {
                    view = .conversation(conversations[dashboardIndex].id)
                }
            default: break
            }
        case .agentPicker:
            let agents = installedAgents
            switch pressed {
            case .escape: showDashboard()
            case .char("j"), .down:
                pickerIndex = min(max(agents.count - 1, 0), pickerIndex + 1)
            case .char("k"), .up: pickerIndex = max(0, pickerIndex - 1)
            case .enter:
                if agents.indices.contains(pickerIndex) {
                    try await create(
                        agent: agents[pickerIndex].identifier,
                        sessionID: pendingPickerSessionID
                    )
                    pendingPickerSessionID = nil
                    notice = nil
                }
            default: break
            }
        case .conversation(let id):
            guard let index = conversations.firstIndex(where: { $0.id == id }) else { break }
            try await handleConversation(input, index: index)
        case .exitConfirmation:
            break
        }
        return false
    }

    private func canNavigate() async -> Bool {
        guard let id = selectedSessionID,
              let item = conversations.first(where: { $0.id == id }) else { return true }
        if (await item.session.snapshot).voiceState == .recording {
            await item.session.setActivity("Stop voice recording before switching conversations.")
            return false
        }
        return true
    }

    private func refreshConversations() async {
        for index in conversations.indices {
            let work = conversations[index].work
            let state = await work.snapshot()
            conversations[index].lastWorkState = state
            if state.completedGeneration > conversations[index].seenCompletedGeneration {
                conversations[index].seenCompletedGeneration = state.completedGeneration
                conversations[index].control.endPendingTurn()
                conversations[index].control.endUserInputResolution()
                if let queued = conversations[index].queuedSubmission {
                    conversations[index].queuedSubmission = nil
                    do {
                        try await start(.submission(queued), index: index, pending: queued)
                    } catch {
                        await conversations[index].session.recordFailure(error)
                    }
                }
            }
            if state.isRunning || state.completedGeneration > 0 {
                conversations[index].control.update(
                    await conversations[index].session.presentationSnapshot()
                )
            }
            if (await conversations[index].session.snapshot).voiceState == .recording,
               let voiceInput, case .conversation(let selected) = view,
               selected == conversations[index].id {
                await conversations[index].session.setVoiceStatus(
                    await voiceInput.status()
                )
                conversations[index].control.update(
                    await conversations[index].session.presentationSnapshot()
                )
            }
        }
    }

    private func start(
        _ operation: AgenticConversationWork.Operation,
        index: Int,
        pending: AgenticConversationSubmission? = nil,
        userInputID: String? = nil
    ) async throws {
        let item = conversations[index]
        _ = try await item.work.start(operation)
        if let pending { conversations[index].control.beginPendingTurn(pending) }
        if let userInputID {
            conversations[index].control.beginUserInputResolution(interactionID: userInputID)
        }
        conversations[index].control.update(await item.session.presentationSnapshot())
    }

    private func handleConversation(
        _ input: TerminalInputEvent,
        index: Int
    ) async throws {
        let item = conversations[index]
        guard let event = conversations[index].control.handle(input) else { return }
        let conversation = item.session
        let work = item.work
        let running = await work.snapshot().isRunning
        switch event {
        case .exitRequested:
            if await canNavigate() { showDashboard() }

        case .submissionRequested(let submission):
            guard !running else {
                await conversation.setActivity("model response already pending")
                break
            }
            await conversation.setActivity("invoking model")
            try await start(.submission(submission), index: index, pending: submission)

        case .supersedingSubmissionRequested(let submission):
            if running {
                conversations[index].queuedSubmission = submission
                do {
                    try await work.interrupt(
                        mode: .urgent,
                        reason: "Superseded by a new user message."
                    )
                } catch {
                    conversations[index].queuedSubmission = nil
                    await conversation.setActivity("Could not stop current run: \(error.localizedDescription)")
                }
            } else {
                try await start(.submission(submission), index: index, pending: submission)
            }

        case .stopRequested:
            if running {
                do {
                    try await work.interrupt(
                        mode: .urgent,
                        reason: "Stopped from the conversation (Ctrl-G)."
                    )
                } catch {
                    await conversation.setActivity("Stop failed: \(error.localizedDescription)")
                }
            } else {
                await conversation.setActivity("No active response to stop.")
            }

        case .programInvocationRequested(let invocation, let submission):
            guard !running else {
                await conversation.setActivity("conversation work already pending")
                break
            }
            await conversation.setActivity("invoking program")
            try await start(.program(invocation, submission), index: index, pending: submission)

        case .userInputReplyRequested(let interactionID, let runID, let reply):
            guard !running else {
                await conversation.setActivity("conversation work already pending")
                break
            }
            await conversation.setActivity("submitting user input")
            try await start(
                .userInput(interactionID: interactionID, runID: runID, reply: reply),
                index: index,
                userInputID: interactionID
            )

        case .modelPreferenceChanged(let identifier):
            if !running { await conversation.preferModel(identifier) }
        case .responseDeliverySelectionChanged(let delivery):
            if !running { await conversation.selectResponseDelivery(delivery) }
        case .invocationOptionsSelectionChanged(let options):
            if !running { await conversation.selectInvocationOptions(options) }
        case .autonomySelectionChanged(let mode):
            if !running { await conversation.selectAutonomy(mode) }
        case .capabilitySelectionChanged(let available, let visible):
            if !running {
                await conversation.selectCapabilities(available: available, visible: visible)
            }
        case .instructionSelectionChanged(let identifiers):
            if !running { await conversation.selectInstructions(identifiers) }
        case .feedbackRequested(let message):
            await conversation.setActivity(message)

        case .voiceStartRequested:
            guard let voiceInput else {
                await conversation.setVoiceAvailability(.unconfigured)
                await conversation.setVoiceState(.idle)
                await conversation.setActivity("Voice input unavailable — no transcription provider configured.")
                break
            }
            do {
                try await voiceInput.start()
                await conversation.setVoiceStatus(await voiceInput.status())
                await conversation.setVoiceState(.recording)
                await conversation.setActivity("recording voice input")
            } catch {
                let message = String(describing: error)
                await conversation.setVoiceState(.failed(message))
                await conversation.setActivity("Voice input failed: \(message)")
            }

        case .voiceStopRequested:
            guard let voiceInput else {
                await conversation.setVoiceAvailability(.unconfigured)
                await conversation.setVoiceState(.idle)
                await conversation.setActivity("Voice input unavailable — no transcription provider configured.")
                break
            }
            await conversation.setVoiceStatus(nil)
            await conversation.setVoiceState(.transcribing)
            await conversation.setActivity("transcribing voice input")
            do {
                let transcription = try await voiceInput.stop()
                await conversation.setVoiceState(.idle)
                await conversation.setActivity("transcription ready")
                _ = conversations[index].control.applyTranscription(transcription)
            } catch {
                let message = String(describing: error)
                await conversation.setVoiceState(.failed(message))
                await conversation.setActivity("Voice input failed: \(message)")
            }

        case .voiceCancelRequested:
            if let voiceInput { await voiceInput.cancel() }
            await conversation.setVoiceStatus(nil)
            await conversation.setVoiceState(.idle)
            await conversation.setActivity("voice input cancelled")

        case .run(let workflowEvent):
            if case .runControlRequested(
                runID: let runID,
                control: let runControl
            ) = workflowEvent {
                let mode: Run.Interruption.Mode?
                switch runControl {
                case .stop_after_iteration: mode = .graceful
                case .stop_urgent: mode = .urgent
                case .execute_run, .execute_step_and_wait, .pause: mode = nil
                }
                if let mode {
                    do {
                        try await work.interrupt(
                            runID: runID,
                            mode: mode,
                            reason: "Requested from the conversation Run Actions panel."
                        )
                    } catch {
                        await conversation.setActivity("Stop failed: \(error.localizedDescription)")
                    }
                    break
                }
            }
            if case .actionRequested(
                interruptionID: let interruptionID,
                runID: let runID,
                stepID: let stepID,
                action: let action
            ) = workflowEvent {
                guard !running else {
                    await conversation.setActivity("model response already pending")
                    break
                }
                await conversation.setActivity("applying \(action.title.lowercased())")
                try await start(
                    .action(
                        interruptionID: interruptionID,
                        runID: runID,
                        stepID: stepID,
                        action: action
                    ),
                    index: index
                )
                break
            }
            await serviceWorkflow(workflowEvent, conversation: conversation)

        case .contentPinned, .attachmentOpened, .attachmentClosed,
             .runOpened, .runClosed:
            break
        }
        conversations[index].control.update(await conversation.presentationSnapshot())
    }

    private func serviceWorkflow(
        _ event: AgenticHostConsoleWorkflowEvent,
        conversation: AgenticConversationSession
    ) async {
        let copied: Bool
        let success: String
        let failure: String
        switch event {
        case .copyRequested(text: let text, title: let title):
            copied = Clipboard.system.write(text)
            success = "Copied \(title.lowercased())."
            failure = "Clipboard write failed."
        case .runInputCopyRequested(runID: let runID):
            guard let text = await conversation.input(for: runID) else {
                await conversation.setActivity("Run input is not available.")
                return
            }
            copied = Clipboard.system.write(text)
            success = "Copied run input."
            failure = "Could not copy run input."
        case .runOutputCopyRequested(runID: let runID):
            guard let text = await conversation.output(for: runID) else {
                await conversation.setActivity("Run output is not available.")
                return
            }
            copied = Clipboard.system.write(text)
            success = "Copied run output."
            failure = "Could not copy run output."
        case .feedbackRequested(message: let message):
            await conversation.setActivity(message)
            return
        default:
            return
        }
        await conversation.setActivity(copied ? success : failure)
    }
}
