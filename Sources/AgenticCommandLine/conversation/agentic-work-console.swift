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
    package enum ConversationLifecycle: Sendable, Equatable {
        case active
        case closing
        case archived
    }

    private struct Conversation {
        let id: String
        let agent: AgentIdentifier
        let session: AgenticConversationSession
        let work: AgenticConversationWork
        var control: AgenticConversationControl
        var seenCompletedGeneration = 0
        var queuedSubmission: AgenticConversationSubmission?
        var lastWorkState: AgenticConversationWork.Snapshot?
        var lifecycle: ConversationLifecycle = .active
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
    private let keyConfiguration: AgenticConversationKeyConfiguration
    private var conversations: [Conversation] = []
    private var view: View = .dashboard
    // Dashboard index 0 is the New Conversation pad; conversations follow.
    private var dashboardIndex = 0
    private var pickerIndex = 0
    private var commandLine = TerminalCommandLine()
    private var quitConfirms = false
    private var viewBeforeExit: View?
    private var pendingPickerSessionID: String?
    private var notice: String?

    package init(
        runtime: AgenticRuntime,
        service: any AgentHost.Service,
        capabilities: AgentHost.Capabilities,
        workspace: String,
        voiceInput: (any VoiceInputProvider)? = nil,
        keyConfiguration: AgenticConversationKeyConfiguration = .init()
    ) {
        self.runtime = runtime
        self.service = service
        self.capabilities = capabilities
        self.workspace = workspace
        self.voiceInput = voiceInput
        self.keyConfiguration = keyConfiguration
    }

    package var installedAgents: [AgentDefinition] {
        runtime.agents.definitions.sorted {
            $0.identifier.rawValue < $1.identifier.rawValue
        }
    }

    package var sessionIDs: [String] {
        conversations.map(\.id)
    }

    package var archivedSessionIDs: [String] {
        conversations.filter { $0.lifecycle == .archived }.map(\.id)
    }

    package func lifecycle(for id: String) throws -> ConversationLifecycle {
        guard let item = conversations.first(where: { $0.id == id }) else {
            throw Failure.unknownSession(id)
        }
        return item.lifecycle
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
            snapshot: await session.presentationSnapshot(),
            keyConfiguration: keyConfiguration
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
        case closingSession(String)
    }

    package func select(_ id: String) throws {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else {
            throw Failure.unknownSession(id)
        }
        guard conversations[index].lifecycle != .closing else {
            throw Failure.closingSession(id)
        }
        // Reopen archived conversations without rebuilding the session or editor.
        conversations[index].lifecycle = .active
        view = .conversation(id)
    }

    /// Explicit close: retain transcript/control and the stable session ID.
    /// If a run is active, issue a runtime interruption and archive after it
    /// actually settles. Do not cancel the Task as a substitute.
    package func archive(_ id: String) async throws {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else {
            throw Failure.unknownSession(id)
        }
        guard conversations[index].lifecycle == .active else { return }
        let work = conversations[index].work
        let running = await work.snapshot().isRunning
        if running {
            try await work.interrupt(
                mode: .urgent,
                reason: "Conversation archived by the user."
            )
        }
        conversations[index].queuedSubmission = nil
        conversations[index].lifecycle = running ? .closing : .archived
        if selectedSessionID == id { showDashboard() }
    }

    package func showDashboard() {
        pendingPickerSessionID = nil
        commandLine = TerminalCommandLine()
        view = .dashboard
    }

    private func showAgentPicker(initialSessionID: String? = nil) {
        pickerIndex = 0
        pendingPickerSessionID = initialSessionID
        commandLine = TerminalCommandLine()
        view = .agentPicker
    }

    package var isExitConfirmationPresented: Bool {
        if case .exitConfirmation = view { return true }
        return false
    }

    /// A dashboard quit always requires an explicit confirmation, even when idle.
    @discardableResult
    package func requestExit() async -> Bool {
        viewBeforeExit = view
        quitConfirms = false
        view = .exitConfirmation
        return false
    }

    private func cancelExit() {
        view = viewBeforeExit ?? .dashboard
        viewBeforeExit = nil
        commandLine = TerminalCommandLine()
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
        let root = TerminalRegion(rows: rows, columns: columns)
        switch view {
        case .dashboard:
            let pads = [AgenticWorkSurface.Pad(
                title: "+  New conversation",
                primary: "Choose an installed Agent",
                secondary: "Create an independent session",
                hint: "Enter to select Agent",
                tone: .new
            )] + conversations.enumerated().map { number, item in
                let snapshot = item.control.snapshot
                let isRunning = item.lastWorkState?.isRunning == true
                let activity = isRunning
                    ? "● Running  ·  " + (snapshot.activity ?? "working")
                    : "○ " + (snapshot.messages.last?.body ?? "Ready for a message")
                        .replacingOccurrences(of: "\n", with: " ")
                let model = snapshot.models.first(where: {
                    $0.id == snapshot.preferredModelProfileID
                })?.title ?? snapshot.preferredModelProfileID.rawValue
                let lifecycle = item.lifecycle
                let headline = switch lifecycle {
                case .active: activity
                case .closing: "◐ Closing · interrupting current operation"
                case .archived: "◇ Archived · reopen to resume conversation"
                }
                return AgenticWorkSurface.Pad(
                    title: "\(number + 1).  \(item.agent.rawValue)",
                    primary: headline,
                    secondary: "\(snapshot.messages.count) messages  ·  \(model)",
                    hint: lifecycle == .closing
                        ? "Finishing interruption  ·  \(String(item.id.prefix(8)))"
                        : "Enter to \(lifecycle == .archived ? "reopen" : "open")  ·  \(String(item.id.prefix(8)))",
                    tone: lifecycle == .closing ? .attention : (isRunning ? .running : .neutral)
                )
            }
            AgenticWorkSurface.renderGallery(
                into: &frame,
                in: root,
                section: "Conversations",
                subtitle: "Independent sessions. Switching views does not interrupt work.",
                summary: "\(conversations.count) sessions  ·  \(conversations.filter { $0.lastWorkState?.isRunning == true }.count) active",
                pads: pads,
                selectedIndex: dashboardIndex,
                footer: "↑↓ navigate  Enter open/reopen  n new  :q quit application",
                commandLine: commandLine,
                notice: notice
            )
        case .agentPicker:
            let pads = installedAgents.map { agent in
                AgenticWorkSurface.Pad(
                    title: agent.identifier.rawValue,
                    primary: "Installed Agent",
                    secondary: "Available for a new conversation",
                    hint: "Enter to create a session",
                    tone: .neutral
                )
            }
            AgenticWorkSurface.renderGallery(
                into: &frame,
                in: root,
                section: "Choose an Agent",
                subtitle: "Each selection creates a separate conversation with its own execution state.",
                summary: "\(pads.count) installed",
                pads: pads,
                selectedIndex: pickerIndex,
                footer: "↑↓ navigate  ←→ select  Enter create  Esc back  :q quit",
                commandLine: commandLine,
                notice: notice
            )
        case .exitConfirmation:
            // Preserve the gallery behind the modal, with its own focus and command state.
            AgenticWorkSurface.renderGallery(
                into: &frame,
                in: root,
                section: "Conversations",
                subtitle: "Application exit requires confirmation.",
                summary: "\(conversations.count) sessions",
                pads: [],
                selectedIndex: 0,
                footer: "Esc cancel",
                commandLine: TerminalCommandLine()
            )
            AgenticWorkSurface.renderQuit(
                into: &frame,
                in: root,
                activeOperations: conversations.filter { $0.lastWorkState?.isRunning == true }.count,
                confirms: quitConfirms
            )
        case .conversation(let id):
            guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
            AgenticWorkSurface.renderConversationHeader(
                into: &frame,
                in: root,
                agent: conversations[index].agent.rawValue,
                position: index + 1,
                count: conversations.count
            )
            guard rows > 1 else { return }
            conversations[index].control.render(
                into: &frame,
                in: TerminalRegion(top: 1, leading: 0, rows: rows - 1, columns: columns)
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

    /// Terminal navigation never implies application termination.
    /// :q in Work requires confirmation; :q in a conversation uses its
    /// existing composer confirmation and emits .archiveRequested only afterward.
    package func handle(_ input: TerminalInputEvent) async throws -> Bool {
        let pressed = key(input)

        if case .exitConfirmation = view {
            switch pressed {
            case .escape, .control("C"), .char("n"):
                cancelExit()
            case .left, .right, .up, .down, .tab,
                 .char("h"), .char("j"), .char("k"), .char("l"):
                quitConfirms.toggle()
            case .char("y"):
                return true
            case .enter:
                if quitConfirms { return true }
                cancelExit()
            default:
                break
            }
            return false
        }

        // Keep the command line's keyboard focus before global navigation.
        if case .dashboard = view {
            if await handleWorkCommand(pressed) { return false }
        } else if case .agentPicker = view {
            if await handleWorkCommand(pressed) { return false }
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
                try? select(conversations[next].id)
            }
            return false
        }

        switch view {
        case .dashboard:
            switch pressed {
            case .char("n"), .char("a"):
                showAgentPicker()
            case .char("j"), .down, .char("l"), .right:
                dashboardIndex = min(conversations.count, dashboardIndex + 1)
            case .char("k"), .up, .char("h"), .left:
                dashboardIndex = max(0, dashboardIndex - 1)
            case .enter:
                if dashboardIndex == 0 {
                    showAgentPicker()
                } else if conversations.indices.contains(dashboardIndex - 1) {
                    try select(conversations[dashboardIndex - 1].id)
                }
            // Escape on the root surface is deliberately inert, never quit.
            default:
                break
            }
        case .agentPicker:
            let agents = installedAgents
            switch pressed {
            case .escape:
                showDashboard()
            case .char("j"), .down, .char("l"), .right:
                pickerIndex = min(max(agents.count - 1, 0), pickerIndex + 1)
            case .char("k"), .up, .char("h"), .left:
                pickerIndex = max(0, pickerIndex - 1)
            case .enter:
                if agents.indices.contains(pickerIndex) {
                    try await create(
                        agent: agents[pickerIndex].identifier,
                        sessionID: pendingPickerSessionID
                    )
                    pendingPickerSessionID = nil
                    notice = nil
                }
            default:
                break
            }
        case .conversation(let id):
            guard let index = conversations.firstIndex(where: { $0.id == id }) else { break }
            try await handleConversation(input, index: index)
        case .exitConfirmation:
            break
        }
        return false
    }

    /// The same TerminalCommandLine primitive used by the editor family.
    /// Bare q is not a command here and Escape only cancels the command entry.
    private func handleWorkCommand(_ pressed: TerminalKey?) async -> Bool {
        guard let pressed else { return commandLine.isActive }
        if commandLine.isActive {
            if let result = commandLine.handle(pressed) {
                switch result {
                case .submitted(let raw):
                    let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if command == "q" || command == "quit" {
                        _ = await requestExit()
                    } else {
                        commandLine.setStatus("Unknown Work command :\(command)")
                    }
                case .cancelled:
                    break
                case .changed:
                    break
                }
            }
            return true
        }
        if pressed == .char(":") {
            commandLine.begin()
            return true
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
            if conversations[index].lifecycle == .closing && !state.isRunning {
                conversations[index].lifecycle = .archived
            }
            if state.completedGeneration > conversations[index].seenCompletedGeneration {
                conversations[index].seenCompletedGeneration = state.completedGeneration
                conversations[index].control.endPendingTurn()
                conversations[index].control.endUserInputResolution()
                if conversations[index].lifecycle != .active {
                    conversations[index].queuedSubmission = nil
                }
                if conversations[index].lifecycle == .active,
                   let queued = conversations[index].queuedSubmission {
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
        case .archiveRequested:
            try await archive(item.id)

        case .showWorkRequested:
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
