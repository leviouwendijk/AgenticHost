import Agentic
import AgenticHost
import AgenticRuntime
import Dispatch
import Foundation

/// Holds one in-process Host for the lifetime of the command shell.
actor AgenticRunShell {
    private let service: any AgentHost.Service
    private let agents: [AgentIdentifier]
    private let workspace: String
    private var selected: AgentHost.Session.ID?
    private var running: [AgentHost.Session.ID: Task<Void, Never>] = [:]
    private var observations: [AgentHost.Session.ID: Task<Void, Never>] = [:]
    private var recentPhase: [AgentHost.Session.ID: AgentExecutor.Phase] = [:]
    private var recentToolCount: [AgentHost.Session.ID: Int] = [:]
    private var reviewedApprovals: [AgentHost.Session.ID: String] = [:]
    private var feedback: AgenticRunShellFeedback = .normal

    init(service: any AgentHost.Service, agents: [AgentIdentifier], workspace: String) {
        self.service = service
        self.agents = agents.sorted { $0.rawValue < $1.rawValue }
        self.workspace = workspace
    }

    func run() async {
        print("Agentic command shell · workspace: \(workspace)")
        print("Type help for commands. No Agent or session is selected by default.")
        prompt()
        for await line in Self.lines() {
            do {
                if let command = try AgenticRunShellParser.parse(line) {
                    if case .quit(let force) = command {
                        guard await quit(force: force) else { prompt(); continue }
                        return
                    }
                    try await execute(command)
                }
            } catch {
                print("error: \(error.localizedDescription)")
            }
            prompt()
        }
        print("\nstdin closed; closing local shell.")
        _ = await quit(force: true)
    }

    private static func lines() -> AsyncStream<String> {
        AsyncStream { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                while let line = readLine() {
                    continuation.yield(line)
                }
                continuation.finish()
            }
        }
    }

    private func execute(_ command: AgenticRunShellInstruction) async throws {
        switch command {
        case .help:
            print("""
                agents                         List installed Agents
                session start <agent-id>       Start an isolated session
                sessions                       List sessions in this shell
                session use <session-id>       Select a session
                session detach                Deselect without stopping the session
                ls agents|sessions|workers     List resources (alias)
                send <prompt>                  Submit asynchronously
                feedback quiet|normal|verbose Change live event output
                status                         Inspect selected session
                workers                        List delegated workers
                worker interrupt <id> [mode]   Interrupt one worker
                worker continue <id>           Continue parent after worker interruption
                interrupt [graceful|urgent]    Request root interruption
                interaction show               Inspect current suspension and request
                interaction respond <id> <text> Answer a text clarification
                interaction approve <id>       Approve identified tool suspension
                interaction deny|skip <id>     Deny or skip suspension
                interaction continue <id> <n> Continue run limit with total limit n
                interaction stop <id>          Stop run-limit suspension
                mutations                      List staged mutation submissions
                quit                           Exit when no work is pending
                quit --force                   Interrupt work and discard local state
                """)
        case .agents:
            for agent in agents { print(agent.rawValue) }
        case .sessions:
            for summary in try await service.sessions() {
                let mark = summary.id == selected ? "*" : " "
                print("\(mark) \(summary.id.rawValue) agent=\(summary.agent?.rawValue ?? "-") \(summary.interaction == nil ? "" : "suspended")")
            }
        case .start(let raw):
            guard agents.contains(where: { $0.rawValue == raw }) else {
                throw AgenticRunShellParseError.usage("Agent '\(raw)' is not installed. Run agents to list identifiers.")
            }
            let session = try await service.start(.init(agent: .init(rawValue: raw)))
            selected = session.id
            observe(session.id)
            print("session \(session.id.rawValue) started · agent \(raw)")
        case .use(let raw):
            guard let existing = try await service.sessions().first(where: { $0.id.rawValue == raw }) else {
                throw AgenticRunShellParseError.usage("Unknown session '\(raw)'.")
            }
            selected = existing.id
            print("selected session \(raw)")
        case .detach:
            guard let id = selected else {
                print("No session selected.")
                return
            }
            selected = nil
            print("detached from \(id.rawValue) · session remains in this shell; use session use \(id.rawValue) to reattach")
        case .feedback(let mode):
            feedback = mode
            print("live feedback: \(mode.rawValue)")
        case .send(let prompt):
            let id = try selectedSession()
            guard running[id] == nil else {
                throw AgenticRunShellParseError.usage("Session \(id.rawValue) is executing. Use status or interrupt.")
            }
            print("[\(id.rawValue)] submission accepted; awaiting Host execution")
            running[id] = Task { [service] in
                do {
                    let result = try await service.submit(.init(session: id, prompt: prompt))
                    self.finished(id, result: result)
                } catch {
                    self.failed(id, error: error)
                }
            }
        case .status:
            let id = try selectedSession()
            guard let session = try await service.sessions().first(where: { $0.id == id }) else {
                throw AgenticRunShellParseError.usage("Selected session no longer exists.")
            }
            print("session \(id.rawValue) · agent \(session.agent?.rawValue ?? "-")")
            print("active command: \(running[id] == nil ? "no" : "yes")")
            if let phase = recentPhase[id] { print("latest observed phase: \(phase.rawValue)") }
            if let pending = session.interaction {
                showInteraction(pending, session: id)
            } else {
                print("no pending interaction")
            }
        case .workers:
            let id = try selectedSession()
            let workers = try await service.delegatedWorkers(id)
                .filter { $0.session.parentSessionID != nil }
            if workers.isEmpty { print("no delegated workers") }
            for worker in workers {
                let state = worker.executing ? "running" : (worker.phase?.rawValue ?? "admitted")
                print("\(worker.session.id) · \(worker.session.agent.rawValue) · \(state) · scope \(worker.requestedScope ?? "-")")
            }
        case .interrupt(let mode):
            let id = try selectedSession()
            try await service.interrupt(.init(session: id, mode: mode, reason: "command-shell user request"))
            print("[\(id.rawValue)] \(mode.rawValue) interruption requested; not yet confirmed terminal")
        case .interruptWorker(let workerID, let mode):
            let id = try selectedSession()
            let result = try await service.interruptWorker(id, workerID: workerID, mode: mode, reason: "command-shell user request")
            print("[\(workerID)] \(result.map { "phase \($0.phase.rawValue)" } ?? "interruption requested; awaiting settlement")")
        case .continueWorker(let workerID):
            let id = try selectedSession()
            guard running[id] == nil else {
                throw AgenticRunShellParseError.usage("Parent session is already executing.")
            }
            print("[\(id.rawValue)] continuing after worker \(workerID)")
            running[id] = Task { [service] in
                do {
                    let result = try await service.continueAfterWorkerInterruption(id, workerID: workerID)
                    self.finished(id, result: result)
                } catch {
                    self.failed(id, error: error)
                }
            }
        case .interactionShow:
            let id = try selectedSession()
            guard let pending = try await service.sessions().first(where: { $0.id == id })?.interaction else {
                print("no pending interaction")
                return
            }
            showInteraction(pending, session: id)
        case .interactionRespond(let requestID, let text):
            let id = try selectedSession()
            let request = try await pendingInteraction(
                session: id,
                kind: .user_input,
                expectedID: requestID
            )
            guard let userInput = request.suspension.pendingUserInput else {
                throw AgenticRunShellParseError.usage("The interaction has no user-input request.")
            }
            guard case .text = userInput.input else {
                throw AgenticRunShellParseError.usage("Only text responses are supported by this command shell. The interaction is unchanged.")
            }
            let reply = try UserInputResponse(
                .text(text),
                for: userInput
            ).reply
            try scheduleResolution(
                session: id,
                request: request,
                resolution: .user_input(reply)
            )
        case .interactionApproval(let decision, let requestID):
            let id = try selectedSession()
            let request = try await pendingInteraction(session: id, kind: .approval, expectedID: requestID)
            if decision == .approved && reviewedApprovals[id] != requestID {
                throw AgenticRunShellParseError.usage("Inspect the full approval payload using status before approving.")
            }
            try scheduleResolution(session: id, request: request, resolution: .approval(decision))
            reviewedApprovals.removeValue(forKey: id)
        case .interactionContinue(let requestID, let iterations):
            let id = try selectedSession()
            let request = try await pendingInteraction(session: id, kind: .run_limit, expectedID: requestID)
            try scheduleResolution(session: id, request: request, resolution: .run_limit(.continue_with(.init(iterations: iterations))))
        case .interactionStop(let requestID):
            let id = try selectedSession()
            let request = try await pendingInteraction(session: id, kind: .run_limit, expectedID: requestID)
            try scheduleResolution(session: id, request: request, resolution: .run_limit(.stop))
        case .mutations:
            if let local = service as? AgentHost.Local {
                let ids = await local.pendingCoordinatedMutationIDs()
                if ids.isEmpty { print("no staged mutation submissions") }
                for id in ids { print("staged submission: \(id.uuidString)") }
            } else {
                print("mutation queue inspection unavailable for this Host service")
            }
        case .quit:
            break
        }
    }

    private func showInteraction(
        _ request: Run.Interaction.Request,
        session: AgentHost.Session.ID
    ) {
        print("suspended: \(request.kind.rawValue) · interaction \(request.id)")
        switch request.kind {
        case .approval:
            if let approval = request.suspension.pendingApproval {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let data = try? encoder.encode(approval) {
                    print("Pending approval payload:")
                    print(String(decoding: data, as: UTF8.self))
                    reviewedApprovals[session] = request.id
                } else {
                    print("Unable to display approval payload; do not approve blindly.")
                }
            }
            print("resolve with: interaction approve|deny|skip \(request.id)")
        case .user_input:
            guard let input = request.suspension.pendingUserInput else {
                print("User-input suspension missing its request payload.")
                return
            }
            if let title = input.presentation?.title { print("title: \(title)") }
            print("question: \(input.prompt)")
            if let help = input.presentation?.help { print("help: \(help)") }
            switch input.input {
            case .text(let config):
                if let placeholder = config.placeholder { print("placeholder: \(placeholder)") }
                if let constraint = config.constraint {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    if let data = try? encoder.encode(constraint) {
                        print("constraints: \(String(decoding: data, as: UTF8.self))")
                    }
                }
                print("respond with: interaction respond \(request.id) <text>")
            default:
                print("This input format is not supported in the basic shell; leave the interaction suspended.")
            }
        case .run_limit:
            print("resolve with: interaction continue \(request.id) <total-limit> | stop \(request.id)")
        case .workspace_access:
            print("Workspace access resolution is not supported by the basic shell.")
        }
    }

    private func pendingInteraction(
        session: AgentHost.Session.ID,
        kind: Run.Interaction.Kind,
        expectedID: String
    ) async throws -> Run.Interaction.Request {
        guard let request = try await service.sessions().first(where: { $0.id == session })?.interaction else {
            throw AgenticRunShellParseError.usage("Selected session has no pending interaction.")
        }
        guard request.id == expectedID else {
            throw AgenticRunShellParseError.usage("Stale interaction ID; inspect status again.")
        }
        guard request.kind == kind else {
            throw AgenticRunShellParseError.usage("Pending interaction is \(request.kind.rawValue), not \(kind.rawValue).")
        }
        return request
    }

    private func scheduleResolution(
        session id: AgentHost.Session.ID,
        request: Run.Interaction.Request,
        resolution: Run.Interaction.Resolution
    ) throws {
        guard running[id] == nil else {
            throw AgenticRunShellParseError.usage("Session is already executing.")
        }
        print("[\(id.rawValue)] resolving interaction \(request.id); awaiting Host result")
        running[id] = Task { [service] in
            do {
                let result = try await service.resume(.init(request: request, resolution: resolution))
                self.finished(id, result: result)
            } catch {
                self.failed(id, error: error)
            }
        }
    }

    private func selectedSession() throws -> AgentHost.Session.ID {
        guard let selected else {
            throw AgenticRunShellParseError.usage("No session selected. Use session start <agent-id> or session use <session-id>.")
        }
        return selected
    }

    private func observe(_ session: AgentHost.Session.ID) {
        observations[session] = Task { [service] in
            do {
                for try await snapshot in service.observeState(session) {
                    self.record(snapshot, session: session)
                }
            } catch {
                print("[\(session.rawValue)] state observation ended: \(error.localizedDescription)")
            }
        }
    }

    private func record(_ snapshot: AgentRunStateSnapshot, session: AgentHost.Session.ID) {
        let previous = recentPhase[session]
        let oldCount = recentToolCount[session] ?? 0
        recentPhase[session] = snapshot.phase
        recentToolCount[session] = snapshot.toolUses.count

        switch feedback {
        case .quiet:
            return
        case .normal:
            guard snapshot.toolUses.count > oldCount else { return }
            for record in snapshot.toolUses.dropFirst(oldCount) {
                print("\n[\(session.rawValue)] tool \(record.functionCall.name) · \(record.functionCall.id)")
            }
            prompt()
        case .verbose:
            guard previous != snapshot.phase || snapshot.toolUses.count != oldCount else { return }
            print("\n[\(session.rawValue)] \(snapshot.phase.rawValue) · tool uses \(snapshot.toolUses.count)")
            prompt()
        }
    }

    private func finished(_ session: AgentHost.Session.ID, result: AgentExecutor.Result) {
        running.removeValue(forKey: session)
        recentPhase[session] = result.phase
        print("\n[\(session.rawValue)] \(result.phase.rawValue) · run \(result.sessionID)")
        if let text = result.response?.message.content.text, !text.isEmpty { print(text) }
        if let suspension = result.suspension {
            print("suspended · interaction \(suspension.id) · use interaction show to inspect")
        }
        if let failure = result.failure { print("failure: \(failure.message)") }
        prompt()
    }

    private func failed(_ session: AgentHost.Session.ID, error: Error) {
        running.removeValue(forKey: session)
        print("\n[\(session.rawValue)] command failed: \(error.localizedDescription)")
        prompt()
    }

    private func prompt() {
        let label = selected.map { String($0.rawValue.prefix(8)) } ?? "-"
        FileHandle.standardOutput.write(Data("agentic[\(label)]> ".utf8))
    }

    private func quit(force: Bool) async -> Bool {
        let suspended = (try? await service.sessions())?.filter { $0.interaction != nil } ?? []
        let staged = await (service as? AgentHost.Local)?.pendingCoordinatedMutationIDs() ?? []
        if !force && (!running.isEmpty || !suspended.isEmpty || !staged.isEmpty) {
            print("Active runs, suspensions, or staged mutations remain. Resolve them or use quit --force to abandon local state without publishing.")
            return false
        }
        if force && !staged.isEmpty {
            print("Leaving with \(staged.count) staged submission(s). None will be published.")
        }
        if force && !suspended.isEmpty {
            print("Leaving with \(suspended.count) suspended session(s). Their in-memory checkpoints will be lost.")
        }
        if force {
            for id in Array(running.keys) {
                do {
                    try await service.interrupt(.init(session: id, mode: .urgent, reason: "shell exit"))
                } catch {
                    print("[\(id.rawValue)] interrupt request failed: \(error.localizedDescription)")
                }
            }
            for task in Array(running.values) { await task.value }
        }
        for observation in observations.values { observation.cancel() }
        return true
    }
}
