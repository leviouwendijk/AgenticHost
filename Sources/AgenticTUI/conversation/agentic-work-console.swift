import Agentic
import AgenticHost
import AgenticInterfaces
import AgenticRuntime
import Clipboard
import Foundation
import Primitives
import Terminal
import Writers

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
    // Netrw-like listings: conversations by Agent, installed Agents by namespace.
    private var dashboardList = TerminalTreeList<AgenticWorkEntry>(matcher: { AgenticTreeListMatcher.ranked($0, $1) })
    private var pickerList = TerminalTreeList<AgenticWorkEntry>(matcher: { AgenticTreeListMatcher.ranked($0, $1) })
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
        let session = try await AgenticConversationSession(
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
        var control = AgenticConversationControl(
            snapshot: await session.presentationSnapshot(),
            keyConfiguration: keyConfiguration
        )
        control.hostCommands = Set(Self.stagedCommands.map { String($0.dropFirst()) })
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
        pickerList.filter("")
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
        // Render the resolved workspace's absolute root path (never the raw
        // configuration string) so a "." launch renders an explicit path.
        let workspacePath = workspace
            .root(identifier: workspace.defaultRootIdentifier ?? workspace.roots[0].id)
            .map(\.rootPath)
            ?? configuration.path
        let serviceFactory = AgenticSessionServices.Factory(Application.self)
        let home = AgentHomeLocator().resolveHome()
        let service: any AgentHost.Service = AgentHost.Local(
            runtime: runtime,
            workspace: workspace,
            mutations: .coordinated(StandardMutationCoordinator()),
            logs: try .home(home),
            publication: try home.settings().mutations.publication,
            tasks: .home(home),
            services: { sessionID in
                try serviceFactory.resolve(sessionID: sessionID.rawValue)
            }
        )
        let capabilities = try await service.capabilities()
        let primary = startConversation
            ? try entryAgent(runtime: runtime, explicit: preferredAgent)
            : nil
        try await run(
            runtime: runtime,
            service: service,
            capabilities: capabilities,
            workspace: workspacePath,
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
                useMouseTracking: true,
                keyboardProtocol: .kitty,
                controlSignalBehavior: .input,
                restoreOnInterrupt: true,
                outputStream: stream
            )
        )
        defer { terminalSession.restore() }

        let reader = TerminalKeyReader()
        let progress = TerminalProgress(stream: stream)
        var progressActive = false
        var renderer = TerminalFrameRenderer(stream: stream)
        while true {
            await refreshConversations()
            let currentlyActive = conversations.contains {
                $0.lastWorkState?.isRunning == true
            }
            if currentlyActive != progressActive {
                progressActive = currentlyActive
                if currentlyActive {
                    await progress.start(.indeterminate)
                } else {
                    await progress.stop()
                }
            }
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
                    if try await handle(event) {
                        await progress.stop()
                        return
                    }
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

    package func render(into frame: inout TerminalFrame, rows: Int, columns: Int) {
        guard rows > 0, columns > 0 else { return }
        let root = TerminalRegion(rows: rows, columns: columns)
        switch view {
        case .dashboard:
            dashboardList.update(dashboardTree())
            AgenticWorkSurface.renderTree(
                into: &frame,
                in: root,
                section: "conversations",
                summary: "\(conversations.count) sessions  ·  \(conversations.filter { $0.lastWorkState?.isRunning == true }.count) active",
                list: &dashboardList,
                footer: "j/k move  h/l fold  Enter open  / filter  n new  :review  :q quit",
                commandLine: commandLine,
                notice: notice
            )
        case .agentPicker:
            pickerList.update(AgenticWorkTree.agents(installedAgents))
            AgenticWorkSurface.renderTree(
                into: &frame,
                in: root,
                section: "new conversation",
                summary: "\(installedAgents.count) installed Agents",
                list: &pickerList,
                footer: "j/k move  h/l fold  Enter create  / filter  Esc back  :q quit",
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
        case .paste, .mouse: return nil
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

        // A typed filter, then the command line, keep keyboard focus before
        // global navigation.
        if case .dashboard = view, dashboardList.capturesInput, let pressed {
            _ = dashboardList.handle(pressed)
            return false
        }
        if case .agentPicker = view, pickerList.capturesInput, let pressed {
            _ = pickerList.handle(pressed)
            return false
        }
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
            dashboardList.update(dashboardTree())
            switch pressed {
            case .char("n"), .char("a"):
                showAgentPicker()
            case .some(let key):
                switch dashboardList.handle(key) {
                case .activated(.newConversation):
                    showAgentPicker()
                case .activated(.conversation(let id)):
                    try select(id)
                default:
                    break
                }
            // Escape on the root surface is deliberately inert, never quit.
            case .none:
                break
            }
        case .agentPicker:
            pickerList.update(AgenticWorkTree.agents(installedAgents))
            guard let pressed else { break }
            if pressed == .escape, pickerList.query.isEmpty {
                showDashboard()
                break
            }
            if case .activated(.agent(let identifier)) = pickerList.handle(pressed) {
                try await create(
                    agent: .init(rawValue: identifier),
                    sessionID: pendingPickerSessionID
                )
                pendingPickerSessionID = nil
                notice = nil
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
                    } else if command.hasPrefix("s/") {
                        let query = String(command.dropFirst(2))
                            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        if case .agentPicker = view {
                            pickerList.filter(query)
                        } else {
                            dashboardList.filter(query)
                        }
                    } else if Self.stagedCommands.contains(":" + command) {
                        await runDashboardStagedCommand(":" + command)
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
            // A settled run changes the presentation once; idle ticks must not
            // re-project every conversation.
            let settled = state.completedGeneration
                > conversations[index].seenCompletedGeneration
            conversations[index].lastWorkState = state
            conversations[index].control.setWorkRunning(state.isRunning)
            if conversations[index].lifecycle == .closing && !state.isRunning {
                conversations[index].lifecycle = .archived
            }
            if state.completedGeneration > conversations[index].seenCompletedGeneration {
                conversations[index].seenCompletedGeneration = state.completedGeneration
                conversations[index].control.endPendingTurn()
                conversations[index].control.endUserInputResolution()
                // A settled turn is its unit's publication boundary; the
                // session has already put its staged changes up for review.
                conversations[index].control.update(
                    await conversations[index].session.presentationSnapshot()
                )
                if conversations[index].control.snapshot.hostConsole.interruptions
                    .contains(where: { $0.kind == .publication }) {
                    commandLine.setStatus(
                        "Staged changes not yet on disk · :review to inspect · :publish · :discard"
                    )
                }
                if conversations[index].lifecycle != .active {
                    conversations[index].queuedSubmission = nil
                }
                if conversations[index].lifecycle == .active,
                   let queued = conversations[index].queuedSubmission {
                    conversations[index].queuedSubmission = nil
                    do {
                        try await start(
                            .supersedingSubmission(
                                queued,
                                expectedRunID:
                                    await conversations[index].session.unsettledRunID()
                            ),
                            index: index,
                            pending: queued
                        )
                    } catch {
                        await conversations[index].session.recordFailure(error)
                    }
                }
            }
            if state.isRunning || settled {
                await conversations[index].session.refreshAgents()
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
        conversations[index].control.setWorkRunning(true)
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

        case .hostCommandRequested(let command):
            try await runStagedCommand(":" + command, index: index, running: running)

        case .submissionRequested(let submission):
            guard !running else {
                await conversation.setActivity("model response already pending")
                break
            }
            await conversation.setActivity("invoking model")
            try await start(.submission(submission), index: index, pending: submission)

        case .supersedingSubmissionRequested(let submission):
            // Host-owned supersession settles whatever occupies the session
            // (actively executing or suspended) before admitting the
            // replacement. The work coordinator simply routes the confirmed
            // replacement through the Host policy; it does not decide whether
            // an active or suspended run needs interruption.
            await conversation.setActivity(
                "Replacing current run · stopping previous work before next message"
            )
            try await start(
                .supersedingSubmission(
                    submission,
                    expectedRunID: await conversation.unsettledRunID()
                ),
                index: index,
                pending: submission
            )

        case .stopRequested:
            if running {
                await conversation.setActivity(
                    "Stop requested · finishing active effect if necessary, then stopping"
                )
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

        case .copyRequested(let text, let title):
            let copied = Clipboard.system.write(text)
            await conversation.setActivity(copied ? "Copied \(title)." : "Clipboard write failed.")

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

/// `:review`, `:publish` and `:discard` act on a conversation's staged
/// changes: the same review its run card offers, without typing an ID.
extension AgenticWorkConsole {
    static let stagedCommands: Set<String> = [":review", ":publish", ":discard"]

    func runStagedCommand(
        _ command: String,
        index: Int,
        running: Bool
    ) async throws {
        let conversation = conversations[index].session
        guard !running else {
            await conversation.setActivity("Staged changes are reviewable once the current run settles.")
            return
        }
        guard let staged = await conversation.stagedReview() else {
            await conversation.setActivity("No staged changes to review.")
            conversations[index].control.update(await conversation.presentationSnapshot())
            return
        }
        conversations[index].control.update(await conversation.presentationSnapshot())

        switch command {
        case ":review":
            _ = conversations[index].control.openStagedReview()
        case ":publish", ":discard":
            // Every staged unit at once; the review menu decides them one by one.
            try await start(
                .action(
                    interruptionID: AgenticConversationSession.wholeStagedReviewID(of: staged.id),
                    runID: staged.runID,
                    stepID: staged.stepID,
                    action: command == ":publish" ? .publish : .discard
                ),
                index: index
            )
        default:
            break
        }
    }

    /// On the dashboard: `:review` opens the conversation that has staged
    /// changes; `:publish` and `:discard` act when exactly one has them.
    func runDashboardStagedCommand(
        _ command: String
    ) async {
        var staged: [Int] = []
        for index in conversations.indices where conversations[index].lifecycle != .closing {
            if await conversations[index].session.stagedReview() != nil {
                staged.append(index)
            }
        }
        guard let first = staged.first else {
            commandLine.setStatus("No staged changes to review.")
            return
        }
        guard command == ":review" || staged.count == 1 else {
            commandLine.setStatus(
                "\(staged.count) conversations have staged changes; :review opens one, then :publish or :discard there."
            )
            return
        }
        do {
            try select(conversations[first].id)
            if command == ":review" {
                conversations[first].control.update(
                    await conversations[first].session.presentationSnapshot()
                )
                _ = conversations[first].control.openStagedReview()
            } else {
                try await runStagedCommand(
                    command,
                    index: first,
                    running: await conversations[first].work.snapshot().isRunning
                )
            }
        } catch {
            commandLine.setStatus("Staged changes unavailable: \(error.localizedDescription)")
        }
    }
}

extension AgenticWorkConsole {
    /// Conversations by Agent, each a row with its state, latest activity
    /// and model.
    func dashboardTree() -> Tree<TerminalTreeListItem<AgenticWorkEntry>> {
        AgenticWorkTree.conversations(
            conversations.enumerated().map { number, item in
                let snapshot = item.control.snapshot
                let isRunning = item.lastWorkState?.isRunning == true
                let model = snapshot.models.first(where: {
                    $0.id == snapshot.preferredModelProfileID
                })?.title ?? snapshot.preferredModelProfileID.rawValue
                let latest = (snapshot.messages.last?.body ?? "ready for a message")
                    .split(whereSeparator: \.isNewline).joined(separator: " ")
                let mark: String
                let headline: String
                let tone: TerminalStyle
                switch item.lifecycle {
                case .active:
                    mark = isRunning ? "●" : "○"
                    headline = isRunning ? (snapshot.activity ?? "working") : latest
                    tone = isRunning ? TerminalStyle(.green) : .none
                case .closing:
                    mark = "◐"
                    headline = "closing · interrupting current operation"
                    tone = TerminalStyle(.yellow)
                case .archived:
                    mark = "◇"
                    headline = "archived · Enter reopens"
                    tone = .dim
                }
                return .init(
                    id: item.id,
                    agent: item.agent.rawValue,
                    number: number + 1,
                    mark: mark,
                    headline: headline,
                    detail: "\(snapshot.messages.count) msgs · \(model)",
                    tone: tone
                )
            }
        )
    }
}

