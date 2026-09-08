import Agentic
import AgenticExecution
import AgenticInterfaces
import AgenticOllama
import AgenticRuntime
import AgenticCommandLine
import Foundation
import Terminal
import TestFlows

private struct ConversationLiveOllamaApplication:
    AgenticApplicationProviding
{
    static let application =
        Agentic.application(
            "conversation-live-ollama-diagnostic",
            title:
                "Conversation Live Ollama Diagnostic"
        ) {
            tools {
                CoreToolSet()
            }

            modelProvider(
                OllamaModelProvider()
            )
        }
}

enum AgenticRuntimeConversationLiveOllamaFlowTesting {
    static func run() async throws -> [TestFlowDiagnostic] {
        let runtime =
            try await AgenticRuntime.resolve(
                ConversationLiveOllamaApplication.self
            )

        let workspaceRoot =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "agentic-live-ollama-conversation-\(UUID().uuidString)",
                    isDirectory: true
                )

        try FileManager.default.createDirectory(
            at: workspaceRoot,
            withIntermediateDirectories: true
        )

        defer {
            try? FileManager.default.removeItem(
                at: workspaceRoot
            )
        }

        let conversation =
            try await makeLocalConversationSession(
                runtime: runtime,
                workspacePath: workspaceRoot.path,
                sessionID:
                    "conversation-live-ollama"
            )

        let submission =
            AgenticConversationSubmission(
                body:
                    "hi",
                contents: [],
                modelProfileID:
                    .ollama_qwen3_5_9b,
                skillIDs: [],
                toolExposure:
                    .discovery,
                responseDelivery:
                    .stream,
                autonomyMode:
                    .auto_observe
            )

        print("")
        print("LIVE OLLAMA CONVERSATION SESSION")
        print("================================")
        print("")
        print("boundary:")
        print("  AgenticConversationSession.submit")
        print("  exact session actor as AgentRunStateSink")
        print("  discovery")
        print("  stream")
        print("  same session, two consecutive turns")
        print("")

        let first =
            try await submit(
                turn: 1,
                conversation: conversation,
                submission: submission
            )

        guard first.failure == nil,
              first.response != nil
        else {
            throw ConversationLiveOllamaDiagnosticError
                .turnFailed(
                    1,
                    first.failure?.message
                        ?? "missing response"
                )
        }

        let second =
            try await submit(
                turn: 2,
                conversation: conversation,
                submission: submission
            )

        guard second.failure == nil,
              second.response != nil
        else {
            throw ConversationLiveOllamaDiagnosticError
                .turnFailed(
                    2,
                    second.failure?.message
                        ?? "missing response"
                )
        }

        let snapshot =
            await conversation.snapshot

        print("==================================================")
        print("DIAGNOSIS")
        print("==================================================")
        print("")
        print("turn 1: PASS")
        print("turn 2: PASS")
        print("")
        print("AGENTIC CONVERSATION SESSION PASSES.")
        print("")
        print("The exact package-scoped AgenticConversationSession")
        print("actor survives consecutive discovery streaming turns")
        print("against Ollama outside the real conversation console.")
        print("")

        return [
            .field(
                "turn_1",
                "pass"
            ),
            .field(
                "turn_2",
                "pass"
            ),
            .field(
                "messages",
                String(
                    snapshot.messages.count
                )
            ),
            .field(
                "activity",
                snapshot.activity ?? "<none>"
            ),
        ]
    }
}

extension AgenticRuntimeConversationLiveOllamaFlowTesting {
    static func runTaskBoundary() async throws -> [TestFlowDiagnostic] {
        let runtime =
            try await AgenticRuntime.resolve(
                ConversationLiveOllamaApplication.self
            )

        let workspaceRoot =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "agentic-live-ollama-task-boundary-\(UUID().uuidString)",
                    isDirectory: true
                )

        try FileManager.default.createDirectory(
            at: workspaceRoot,
            withIntermediateDirectories: true
        )

        defer {
            try? FileManager.default.removeItem(
                at: workspaceRoot
            )
        }

        let conversation =
            try await makeLocalConversationSession(
                runtime: runtime,
                workspacePath: workspaceRoot.path,
                sessionID:
                    "conversation-live-ollama-task-boundary"
            )

        let submission =
            AgenticConversationSubmission(
                body:
                    "hi",
                contents: [],
                modelProfileID:
                    .ollama_qwen3_5_9b,
                skillIDs: [],
                toolExposure:
                    .discovery,
                responseDelivery:
                    .stream,
                autonomyMode:
                    .auto_observe
            )

        func submitInFreshTask(
            turn: Int
        ) async throws -> AgentRunResult {
            print("--------------------------------------------------")
            print("TURN \(turn) — FRESH TASK")
            print("--------------------------------------------------")

            do {
                let task = Task {
                    try await conversation.submit(
                        submission
                    )
                }

                let result =
                    try await task.value

                printResult(
                    result
                )
                print("")

                return result
            } catch {
                print("THREW")
                print("  type: \(String(reflecting: type(of: error)))")
                print("  message: \(error.localizedDescription)")
                print("")

                let nsError =
                    error as NSError

                print("  NSError domain: \(nsError.domain)")
                print("  NSError code: \(nsError.code)")

                for key in nsError.userInfo.keys {
                    print(
                        "  \(String(describing: key)): \(String(describing: nsError.userInfo[key]!))"
                    )
                }

                print("")
                throw error
            }
        }

        print("")
        print("LIVE OLLAMA CONVERSATION TASK BOUNDARY")
        print("======================================")
        print("")
        print("boundary:")
        print("  same AgenticConversationSession actor")
        print("  discovery")
        print("  stream")
        print("  fresh Task for each submission")
        print("  two consecutive turns")
        print("")

        let first =
            try await submitInFreshTask(
                turn: 1
            )

        guard first.failure == nil,
              first.response != nil
        else {
            throw ConversationLiveOllamaDiagnosticError
                .turnFailed(
                    1,
                    first.failure?.message
                        ?? "missing response"
                )
        }

        let second =
            try await submitInFreshTask(
                turn: 2
            )

        guard second.failure == nil,
              second.response != nil
        else {
            throw ConversationLiveOllamaDiagnosticError
                .turnFailed(
                    2,
                    second.failure?.message
                        ?? "missing response"
                )
        }

        let snapshot =
            await conversation.snapshot

        print("==================================================")
        print("DIAGNOSIS")
        print("==================================================")
        print("")
        print("turn 1: PASS")
        print("turn 2: PASS")
        print("")
        print("FRESH TASK SUBMISSION BOUNDARY PASSES.")
        print("")

        return [
            .field(
                "turn_1",
                "pass"
            ),
            .field(
                "turn_2",
                "pass"
            ),
            .field(
                "boundary",
                "fresh_task_per_submission"
            ),
            .field(
                "messages",
                String(
                    snapshot.messages.count
                )
            ),
            .field(
                "activity",
                snapshot.activity ?? "<none>"
            ),
        ]
    }
}

extension AgenticRuntimeConversationLiveOllamaFlowTesting {
    static func runControlLifecycle() async throws -> [TestFlowDiagnostic] {
        let runtime =
            try await AgenticRuntime.resolve(
                ConversationLiveOllamaApplication.self
            )

        let workspaceRoot =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "agentic-live-ollama-control-lifecycle-\(UUID().uuidString)",
                    isDirectory: true
                )

        try FileManager.default.createDirectory(
            at: workspaceRoot,
            withIntermediateDirectories: true
        )

        defer {
            try? FileManager.default.removeItem(
                at: workspaceRoot
            )
        }

        let conversation =
            try await makeLocalConversationSession(
                runtime: runtime,
                workspacePath: workspaceRoot.path,
                sessionID:
                    "conversation-live-ollama-control-lifecycle"
            )

        var control =
            AgenticConversationControl(
                snapshot:
                    await conversation.presentationSnapshot()
            )

        func authorSubmission(
            turn: Int
        ) throws -> AgenticConversationSubmission {
            _ = control.handle(
                .char("h")
            )
            _ = control.handle(
                .char("i")
            )

            guard case .submissionRequested(let submission)? =
                control.handle(.enter)
            else {
                throw ConversationLiveOllamaDiagnosticError
                    .turnFailed(
                        turn,
                        "AgenticConversationControl did not produce a submission"
                    )
            }

            print("TURN \(turn) SUBMISSION")
            print("  body: \(submission.body)")
            print("  origin: \(String(describing: submission.origin))")
            print("  model: \(String(describing: submission.modelProfileID))")
            print("  skills: \(String(describing: submission.skillIDs))")
            print("  exposure: \(String(describing: submission.toolExposure))")
            print("  delivery: \(String(describing: submission.responseDelivery))")
            print("  autonomy: \(String(describing: submission.autonomyMode))")
            print("")

            return submission
        }

        func executeSubmission(
            turn: Int,
            submission: AgenticConversationSubmission
        ) async throws -> AgentRunResult {
            await conversation.setActivity(
                "invoking model"
            )

            control.beginPendingTurn(
                submission
            )
            control.update(
                await conversation.presentationSnapshot()
            )

            let task = Task {
                try await conversation.submit(
                    submission
                )
            }

            do {
                let result =
                    try await task.value

                control.update(
                    await conversation.presentationSnapshot()
                )
                control.endPendingTurn()
                control.update(
                    await conversation.presentationSnapshot()
                )

                printResult(
                    result
                )
                print("")

                return result
            } catch {
                control.update(
                    await conversation.presentationSnapshot()
                )
                control.endPendingTurn()
                control.update(
                    await conversation.presentationSnapshot()
                )

                print("TURN \(turn) THREW")
                print("  type: \(String(reflecting: type(of: error)))")
                print("  message: \(error.localizedDescription)")

                let nsError =
                    error as NSError

                print("  NSError domain: \(nsError.domain)")
                print("  NSError code: \(nsError.code)")
                print("")

                throw error
            }
        }

        print("")
        print("LIVE OLLAMA CONVERSATION CONTROL LIFECYCLE")
        print("==========================================")
        print("")
        print("boundary:")
        print("  real AgenticConversationControl")
        print("  control-authored submission")
        print("  beginPendingTurn")
        print("  refreshed presentation snapshots")
        print("  fresh Task per submission")
        print("  endPendingTurn")
        print("  two consecutive turns")
        print("")

        let firstSubmission =
            try authorSubmission(
                turn: 1
            )

        let first =
            try await executeSubmission(
                turn: 1,
                submission: firstSubmission
            )

        guard first.failure == nil,
              first.response != nil
        else {
            throw ConversationLiveOllamaDiagnosticError
                .turnFailed(
                    1,
                    first.failure?.message
                        ?? "missing response"
                )
        }

        let secondSubmission =
            try authorSubmission(
                turn: 2
            )

        guard secondSubmission == firstSubmission else {
            print("SUBMISSION DRIFT DETECTED")
            print("  turn 1: \(String(describing: firstSubmission))")
            print("  turn 2: \(String(describing: secondSubmission))")
            print("")

            throw ConversationLiveOllamaDiagnosticError
                .turnFailed(
                    2,
                    "AgenticConversationControl rebuilt a different submission after turn 1"
                )
        }

        print("submission equality: PASS")
        print("")

        let second =
            try await executeSubmission(
                turn: 2,
                submission: secondSubmission
            )

        guard second.failure == nil,
              second.response != nil
        else {
            throw ConversationLiveOllamaDiagnosticError
                .turnFailed(
                    2,
                    second.failure?.message
                        ?? "missing response"
                )
        }

        let snapshot =
            await conversation.snapshot

        print("==================================================")
        print("DIAGNOSIS")
        print("==================================================")
        print("")
        print("turn 1: PASS")
        print("turn 2 submission equality: PASS")
        print("turn 2: PASS")
        print("")
        print("CONVERSATION CONTROL LIFECYCLE PASSES.")
        print("")

        return [
            .field(
                "turn_1",
                "pass"
            ),
            .field(
                "turn_2",
                "pass"
            ),
            .field(
                "submission_equality",
                "pass"
            ),
            .field(
                "boundary",
                "conversation_control_lifecycle"
            ),
            .field(
                "messages",
                String(
                    snapshot.messages.count
                )
            ),
            .field(
                "activity",
                snapshot.activity ?? "<none>"
            ),
        ]
    }
}

extension AgenticRuntimeConversationLiveOllamaFlowTesting {
    static func runConsolePolling() async throws -> [TestFlowDiagnostic] {
        let runtime =
            try await AgenticRuntime.resolve(
                ConversationLiveOllamaApplication.self
            )

        let workspaceRoot =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "agentic-live-ollama-console-polling-\(UUID().uuidString)",
                    isDirectory: true
                )

        try FileManager.default.createDirectory(
            at: workspaceRoot,
            withIntermediateDirectories: true
        )

        defer {
            try? FileManager.default.removeItem(
                at: workspaceRoot
            )
        }

        let conversation =
            try await makeLocalConversationSession(
                runtime: runtime,
                workspacePath: workspaceRoot.path,
                sessionID:
                    "conversation-live-ollama-console-polling"
            )

        await conversation.setVoiceAvailability(
            .unconfigured
        )
        await conversation.setVoiceState(
            .idle
        )

        var control =
            AgenticConversationControl(
                snapshot:
                    await conversation.presentationSnapshot()
            )

        let submission =
            AgenticConversationSubmission(
                body:
                    "hi",
                contents: [],
                modelProfileID:
                    .ollama_qwen3_5_9b,
                skillIDs: [],
                toolExposure:
                    .discovery,
                responseDelivery:
                    .stream,
                autonomyMode:
                    .auto_observe
            )

        func runTurn(
            _ turn: Int
        ) async throws -> Int {
            let completion =
                ConversationLiveOllamaPollingCompletion()

            await conversation.setActivity(
                "invoking model"
            )
            control.beginPendingTurn(
                submission
            )
            control.update(
                await conversation.presentationSnapshot()
            )

            var initialFrame = TerminalFrame(
                rows: 32,
                columns: 120
            )
            control.render(
                into: &initialFrame,
                in: TerminalRegion(
                    rows: 32,
                    columns: 120
                )
            )

            let activeSubmission = Task {
                var failureMessage: String?

                do {
                    let result =
                        try await conversation.submit(
                            submission
                        )

                    printResult(
                        result
                    )

                    if let failure = result.failure {
                        failureMessage =
                            failure.message
                    }
                } catch is CancellationError {
                    failureMessage =
                        "submission cancelled"
                } catch {
                    let nsError =
                        error as NSError

                    failureMessage =
                        "\(nsError.domain) \(nsError.code): \(error.localizedDescription)"

                    print("TURN \(turn) THREW")
                    print("  type: \(String(reflecting: type(of: error)))")
                    print("  message: \(error.localizedDescription)")
                    print("  NSError domain: \(nsError.domain)")
                    print("  NSError code: \(nsError.code)")

                    for key in nsError.userInfo.keys {
                        print(
                            "  \(String(describing: key)): \(String(describing: nsError.userInfo[key]!))"
                        )
                    }

                    await conversation.recordFailure(
                        error
                    )
                }

                await completion.markCompleted(
                    failure: failureMessage
                )
            }

            var pollCount = 0

            while true {
                let state =
                    await completion.state()

                if state.completed {
                    control.endPendingTurn()
                    control.update(
                        await conversation.presentationSnapshot()
                    )

                    _ = await activeSubmission.result

                    if let failure = state.failure {
                        throw ConversationLiveOllamaDiagnosticError
                            .turnFailed(
                                turn,
                                failure
                            )
                    }

                    break
                }

                control.update(
                    await conversation.presentationSnapshot()
                )

                var frame = TerminalFrame(
                    rows: 32,
                    columns: 120
                )
                control.render(
                    into: &frame,
                    in: TerminalRegion(
                        rows: 32,
                        columns: 120
                    )
                )

                pollCount += 1

                try await Task.sleep(
                    for: .milliseconds(100)
                )
            }

            guard pollCount > 0 else {
                throw ConversationLiveOllamaDiagnosticError
                    .turnFailed(
                        turn,
                        "submission completed before the console polling loop observed an active turn"
                    )
            }

            let snapshot =
                await conversation.snapshot

            print("TURN \(turn) POLLING PASS")
            print("  polls: \(pollCount)")
            print("  messages: \(snapshot.messages.count)")
            print("")

            return pollCount
        }

        print("")
        print("LIVE OLLAMA CONVERSATION CONSOLE POLLING")
        print("========================================")
        print("")
        print("boundary:")
        print("  same AgenticConversationSession actor")
        print("  streaming discovery submission Task")
        print("  presentationSnapshot polling while active")
        print("  AgenticConversationControl.update while active")
        print("  AgenticConversationControl.render while active")
        print("  100 ms polling cadence")
        print("  two consecutive turns")
        print("")

        let firstPolls =
            try await runTurn(
                1
            )

        let secondPolls =
            try await runTurn(
                2
            )

        let snapshot =
            await conversation.snapshot

        print("==================================================")
        print("DIAGNOSIS")
        print("==================================================")
        print("")
        print("turn 1: PASS")
        print("turn 1 polls: \(firstPolls)")
        print("turn 2: PASS")
        print("turn 2 polls: \(secondPolls)")
        print("")
        print("CONCURRENT CONSOLE POLLING/RENDER PASSES.")
        print("")

        return [
            .field(
                "turn_1",
                "pass"
            ),
            .field(
                "turn_2",
                "pass"
            ),
            .field(
                "turn_1_polls",
                String(firstPolls)
            ),
            .field(
                "turn_2_polls",
                String(secondPolls)
            ),
            .field(
                "boundary",
                "concurrent_console_polling_render"
            ),
            .field(
                "messages",
                String(
                    snapshot.messages.count
                )
            ),
            .field(
                "activity",
                snapshot.activity ?? "<none>"
            ),
        ]
    }
}

private actor ConversationLiveOllamaPollingCompletion {
    private var completed = false
    private var failure: String?

    func markCompleted(
        failure: String?
    ) {
        self.failure = failure
        completed = true
    }

    func state() -> (
        completed: Bool,
        failure: String?
    ) {
        (
            completed,
            failure
        )
    }
}

private extension AgenticRuntimeConversationLiveOllamaFlowTesting {
    static func submit(
        turn: Int,
        conversation: AgenticConversationSession,
        submission: AgenticConversationSubmission
    ) async throws -> AgentRunResult {
        print("--------------------------------------------------")
        print("TURN \(turn)")
        print("--------------------------------------------------")

        do {
            let result =
                try await conversation.submit(
                    submission
                )

            printResult(
                result
            )
            print("")

            return result
        } catch {
            print("THREW")
            print("  type: \(String(reflecting: type(of: error)))")
            print("  message: \(error.localizedDescription)")
            print("")

            let nsError =
                error as NSError

            print("  NSError domain: \(nsError.domain)")
            print("  NSError code: \(nsError.code)")

            for key in nsError.userInfo.keys {
                print(
                    "  \(String(describing: key)): \(String(describing: nsError.userInfo[key]!))"
                )
            }

            print("")
            throw error
        }
    }

    static func printResult(
        _ result: AgentRunResult
    ) {
        if let failure = result.failure {
            print("FAIL")
            print(
                "  kind: \(failure.kind.rawValue)"
            )
            print(
                "  message: \(failure.message)"
            )

            if !failure.metadata.isEmpty {
                print("  metadata:")

                for key in failure.metadata.keys.sorted() {
                    print(
                        "    \(key): \(failure.metadata[key] ?? "")"
                    )
                }
            }

            return
        }

        print("PASS")
        print(
            "  response: \(result.response?.message.content.text ?? "<missing>")"
        )
    }
}

private enum ConversationLiveOllamaDiagnosticError:
    Error,
    LocalizedError
{
    case turnFailed(
        Int,
        String
    )

    var errorDescription: String? {
        switch self {
        case .turnFailed(
            let turn,
            let message
        ):
            return
                "Live Ollama AgenticConversationSession turn \(turn) failed: \(message)"
        }
    }
}
