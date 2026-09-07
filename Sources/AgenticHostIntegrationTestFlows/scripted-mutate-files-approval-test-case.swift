import AgenticExecution
import AgenticIO
import AgenticRuntime
import AgenticWorkspace
import Agentic
import AgenticInterfaces
import Foundation

enum ScriptedMutateFilesApprovalTestCase {
    static func makeDeny() -> AgenticInterfaceTestCase {
        .init(
            id: "scripted-mutate-deny",
            summary: "Script mutate_files approval, deny it, and assert both files remain unchanged."
        ) { _ in
            try await run(
                scenario: .deny
            )
        }
    }

    static func makeApprove() -> AgenticInterfaceTestCase {
        .init(
            id: "scripted-mutate-approve",
            summary: "Script mutate_files approval, approve it, and assert both files are updated after resume."
        ) { _ in
            try await run(
                scenario: .approve
            )
        }
    }

    static func makeInvalidPayload() -> AgenticInterfaceTestCase {
        .init(
            id: "scripted-mutate-invalid-payload",
            summary: "Script an invalid mutate_files line payload and assert it never reaches approval."
        ) { _ in
            try await run(
                scenario: .invalidPayload
            )
        }
    }

    static func makeRollbackMetadata() -> AgenticInterfaceTestCase {
        .init(
            id: "scripted-mutate-rollback-metadata",
            summary: "Approve mutate_files and assert the tool result exposes rollback availability."
        ) { _ in
            try await run(
                scenario: .rollbackMetadata
            )
        }
    }

    static func run(
        scenario: ScriptedMutateFilesScenario
    ) async throws {
        let workspaceRoot = try AgenticInterfaceTestEnvironment.workspaceRoot()
        let workspace = try AgentWorkspace(
            root: workspaceRoot
        )

        try ScriptedMutateFilesFixture.reset(
            workspaceRoot: workspaceRoot
        )

        let originalSnapshot = try ScriptedMutateFilesFixture.snapshot(
            workspaceRoot: workspaceRoot
        )

        var registry = ToolRegistry()
        try registry.register(
            MutateFilesTool()
        )

        let historyStore = FileHistoryStore(
            sessionsdir: FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "agentic-interface-scripted-mutate-files-\(scenario.rawValue)-\(UUID().uuidString)",
                    isDirectory: true
                )
        )

        let presenter = TerminalAgenticRunPresenter()

        let runner = AgentRunner(
            adapter: ScriptedMutateFilesModelAdapter(
                scenario: scenario
            ),
            configuration: .init(
                maximumIterations: 6,
                autonomyMode: .auto_observe,
                historyPersistenceMode: .checkpointmutation
            ),
            toolRegistry: registry,
            workspace: workspace,
            historyStore: historyStore
        )

        try await presenter.present(
            .runStarted(
                prompt: scenario.prompt
            )
        )

        switch scenario {
        case .deny:
            try await runApprovalFlow(
                runner: runner,
                presenter: presenter,
                workspaceRoot: workspaceRoot,
                originalSnapshot: originalSnapshot,
                decision: .denied,
                scenario: scenario
            )

        case .approve,
             .rollbackMetadata:
            try await runApprovalFlow(
                runner: runner,
                presenter: presenter,
                workspaceRoot: workspaceRoot,
                originalSnapshot: originalSnapshot,
                decision: .approved,
                scenario: scenario
            )

        case .invalidPayload:
            try await runInvalidPayloadFlow(
                runner: runner,
                presenter: presenter,
                workspaceRoot: workspaceRoot,
                originalSnapshot: originalSnapshot,
                scenario: scenario
            )
        }
    }
}

internal extension ScriptedMutateFilesApprovalTestCase {
    static func runApprovalFlow(
        runner: AgentRunner,
        presenter: TerminalAgenticRunPresenter,
        workspaceRoot: URL,
        originalSnapshot: ScriptedMutateFilesSnapshot,
        decision: ApprovalDecision,
        scenario: ScriptedMutateFilesScenario
    ) async throws {
        let initialResult = try await runner.run(
            AgentRequest(
                messages: [
                    .init(
                        role: .user,
                        text: scenario.prompt
                    )
                ]
            )
        )

        guard let pendingApproval = initialResult.pendingApproval else {
            try await presenter.present(
                initialResult
            )

            throw ScriptedMutateFilesApprovalTestError.expectedApproval
        }

        guard pendingApproval.toolCall.name == MutateFilesTool.identifier.rawValue else {
            try await presenter.present(
                initialResult
            )

            throw ScriptedMutateFilesApprovalTestError.expectedMutateApproval(
                pendingApproval.toolCall.name
            )
        }

        try await presenter.present(
            .toolCallProposed(
                pendingApproval.toolCall
            )
        )

        try await presenter.present(
            .toolPreflight(
                pendingApproval.preflight
            )
        )

        try await presenter.present(
            initialResult
        )

        try await presenter.present(
            .approvalDecision(
                decision
            )
        )

        let resumed = try await runner.resume(
            sessionID: initialResult.sessionID,
            approvalDecision: decision,
            metadata: [
                "summary": "scripted \(decision.rawValue) for mutate_files interface flow"
            ]
        )

        try await presenter.present(
            resumed
        )

        guard resumed.isCompleted else {
            throw ScriptedMutateFilesApprovalTestError.expectedCompletion
        }

        let responseText = resumed.response?.message.content.text ?? ""

        switch scenario {
        case .deny:
            try ScriptedMutateFilesFixture.assertUnchanged(
                workspaceRoot: workspaceRoot,
                originalSnapshot: originalSnapshot
            )

            guard responseText.contains("denied") else {
                throw ScriptedMutateFilesApprovalTestError.expectedResponse(
                    "Expected final response to mention denial, got: \(responseText)"
                )
            }

        case .approve:
            try ScriptedMutateFilesFixture.assertApprovedMutation(
                workspaceRoot: workspaceRoot
            )

            guard responseText.contains("completed") else {
                throw ScriptedMutateFilesApprovalTestError.expectedResponse(
                    "Expected final response to mention completion, got: \(responseText)"
                )
            }

        case .rollbackMetadata:
            try ScriptedMutateFilesFixture.assertApprovedMutation(
                workspaceRoot: workspaceRoot
            )

            guard responseText.contains("rollback metadata observed") else {
                throw ScriptedMutateFilesApprovalTestError.expectedResponse(
                    "Expected final response to mention rollback metadata, got: \(responseText)"
                )
            }

        case .invalidPayload:
            throw ScriptedMutateFilesApprovalTestError.unexpectedScenario(
                scenario.rawValue
            )
        }
    }

    static func runInvalidPayloadFlow(
        runner: AgentRunner,
        presenter: TerminalAgenticRunPresenter,
        workspaceRoot: URL,
        originalSnapshot: ScriptedMutateFilesSnapshot,
        scenario: ScriptedMutateFilesScenario
    ) async throws {
        do {
            let result = try await runner.run(
                AgentRequest(
                    messages: [
                        .init(
                            role: .user,
                            text: scenario.prompt
                        )
                    ]
                )
            )

            try await presenter.present(
                result
            )

            if let pendingApproval = result.pendingApproval {
                throw ScriptedMutateFilesApprovalTestError.unexpectedApprovalForInvalidPayload(
                    pendingApproval.toolCall.name
                )
            }

            try ScriptedMutateFilesFixture.assertUnchanged(
                workspaceRoot: workspaceRoot,
                originalSnapshot: originalSnapshot
            )

            let responseText = result.response?.message.content.text ?? ""

            guard responseText.contains("invalid")
                    || responseText.contains("rejected")
                    || responseText.contains("failed") else {
                throw ScriptedMutateFilesApprovalTestError.expectedResponse(
                    "Expected invalid payload response to mention rejection or failure, got: \(responseText)"
                )
            }
        } catch let error as ScriptedMutateFilesApprovalTestError {
            throw error
        } catch {
            try ScriptedMutateFilesFixture.assertUnchanged(
                workspaceRoot: workspaceRoot,
                originalSnapshot: originalSnapshot
            )

            let description = error.localizedDescription.lowercased()

            guard description.contains("newline")
                    || description.contains("line_payload")
                    || description.contains("line payload")
                    || description.contains("payload") else {
                throw error
            }

            print(
                "invalid payload rejected before approval: \(error.localizedDescription)"
            )
        }
    }
}

internal enum ScriptedMutateFilesScenario: String, Sendable, Hashable {
    case deny
    case approve
    case invalidPayload = "invalid-payload"
    case rollbackMetadata = "rollback-metadata"

    var prompt: String {
        switch self {
        case .deny:
            return "Script a multi-file mutate_files call, suspend for approval, then deny it."

        case .approve:
            return "Script a multi-file mutate_files call, suspend for approval, then approve it."

        case .invalidPayload:
            return "Script an invalid mutate_files call whose lines payload contains an embedded newline."

        case .rollbackMetadata:
            return "Script a multi-file mutate_files call and verify rollback metadata after approval."
        }
    }
}

internal struct ScriptedMutateFilesModelAdapter: AgentModelAdapter {
    let scenario: ScriptedMutateFilesScenario

    var response: AgentModelResponseProviding {
        ScriptedMutateFilesModelResponseProvider(
            scenario: scenario
        )
    }
}

internal struct ScriptedMutateFilesModelResponseProvider: AgentModelResponseProviding {
    let scenario: ScriptedMutateFilesScenario

    func buffered(
        request: AgentRequest
    ) async throws -> AgentResponse {
        if let toolResult = latestToolResult(
            in: request
        ) {
            return .init(
                message: .init(
                    role: .assistant,
                    text: finalMessage(
                        from: toolResult
                    )
                ),
                stopReason: .end_turn
            )
        }

        let toolCall = AgentToolCall(
            id: "tool-call-scripted-mutate-files-\(scenario.rawValue)",
            name: MutateFilesTool.identifier.rawValue,
            input: try JSONToolBridge.encode(
                scenario.toolInput
            )
        )

        return .init(
            message: .init(
                role: .assistant,
                content: .init(
                    blocks: [
                        .tool_call(
                            toolCall
                        )
                    ]
                )
            ),
            stopReason: .tool_use
        )
    }

    func stream(
        request: AgentRequest
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await buffered(
                        request: request
                    )

                    continuation.yield(
                        .completed(
                            response
                        )
                    )

                    continuation.finish()
                } catch {
                    continuation.finish(
                        throwing: error
                    )
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

internal extension ScriptedMutateFilesModelResponseProvider {
    func latestToolResult(
        in request: AgentRequest
    ) -> AgentToolResult? {
        for message in request.messages.reversed() {
            for block in message.content.blocks.reversed() {
                guard case .tool_result(let result) = block else {
                    continue
                }

                return result
            }
        }

        return nil
    }

    func finalMessage(
        from toolResult: AgentToolResult
    ) -> String {
        let outputText = encodedOutputText(
            from: toolResult
        )

        switch scenario {
        case .deny:
            if toolResult.isError {
                return "mutate_files denied as expected."
            }

            return "mutate_files unexpectedly completed after a denial decision. Output: \(outputText)"

        case .approve:
            if toolResult.isError {
                return "mutate_files failed unexpectedly. Output: \(outputText)"
            }

            return "mutate_files completed through scripted approval."

        case .invalidPayload:
            if toolResult.isError {
                return "invalid mutate_files payload rejected before approval."
            }

            return "invalid mutate_files payload unexpectedly completed. Output: \(outputText)"

        case .rollbackMetadata:
            if toolResult.isError {
                return "mutate_files failed before rollback metadata could be observed. Output: \(outputText)"
            }

            if outputText.contains("\"rollbackAvailable\":true")
                || outputText.contains("\"rollbackAvailable\" : true") {
                return "mutate_files completed and rollback metadata observed."
            }

            return "mutate_files completed, but rollback metadata was missing. Output: \(outputText)"
        }
    }

    func encodedOutputText(
        from toolResult: AgentToolResult
    ) -> String {
        do {
            let data = try JSONEncoder().encode(
                toolResult.output
            )

            return String(
                decoding: data,
                as: UTF8.self
            )
        } catch {
            return String(
                describing: toolResult.output
            )
        }
    }
}

internal extension ScriptedMutateFilesScenario {
    var toolInput: ScriptedMutateFilesToolInput {
        switch self {
        case .deny,
             .approve,
             .rollbackMetadata:
            return .valid

        case .invalidPayload:
            return .invalidLinePayload
        }
    }
}

internal struct ScriptedMutateFilesToolInput: Sendable, Codable, Hashable {
    var entries: [ScriptedMutateFileEntry]
    var failurePolicy: String?
    var reason: String?

    static let valid = ScriptedMutateFilesToolInput(
        entries: [
            .init(
                kind: "edit_text",
                path: ScriptedMutateFilesFixture.userFormatterPath,
                operations: [
                    .insertLines(
                        position: 5,
                        lines: [
                            "    internal func trimString(_ string: String) -> String {",
                            "        return string.trimmingCharacters(in: .whitespacesAndNewlines)",
                            "    }"
                        ]
                    ),
                    .replaceLines(
                        start: 11,
                        end: 16,
                        lines: [
                            "        let trimmedName = trimString(name)",
                            "        let trimmedCity = trimString(city)"
                        ]
                    )
                ]
            ),
            .init(
                kind: "edit_text",
                path: ScriptedMutateFilesFixture.dogFormatterPath,
                operations: [
                    .insertLines(
                        position: 5,
                        lines: [
                            "    internal func trimString(_ string: String) -> String {",
                            "        return string.trimmingCharacters(in: .whitespacesAndNewlines)",
                            "    }"
                        ]
                    ),
                    .replaceLines(
                        start: 11,
                        end: 16,
                        lines: [
                            "        let trimmedName = trimString(name)",
                            "        let trimmedBreed = trimString(breed)"
                        ]
                    ),
                    .replaceLines(
                        start: 26,
                        end: 31,
                        lines: [
                            "        let trimmedClient = trimString(client)",
                            "        let trimmedTopic = trimString(topic)"
                        ]
                    ),
                    .replaceLines(
                        start: 41,
                        end: 46,
                        lines: [
                            "        let trimmedStreet = trimString(street)",
                            "        let trimmedCity = trimString(city)"
                        ]
                    )
                ]
            )
        ],
        failurePolicy: "rollback_applied",
        reason: "Scripted multi-file mutation approval flow."
    )

    static let invalidLinePayload = ScriptedMutateFilesToolInput(
        entries: [
            .init(
                kind: "edit_text",
                path: ScriptedMutateFilesFixture.userFormatterPath,
                operations: [
                    .insertLines(
                        position: 5,
                        lines: [
                            "    internal func trimString(_ string: String) -> String {",
                            "        return string.trimmingCharacters(in: .whitespacesAndNewlines)\n    }"
                        ]
                    )
                ]
            )
        ],
        failurePolicy: "rollback_applied",
        reason: "Scripted invalid line payload rejection flow."
    )
}

internal struct ScriptedMutateFileEntry: Sendable, Codable, Hashable {
    var kind: String
    var path: String
    var operations: [ScriptedEditOperation]
}

internal struct ScriptedEditOperation: Sendable, Codable, Hashable {
    var kind: String
    var position: Int?
    var range: ScriptedLineRange?
    var lines: [String]?

    static func insertLines(
        position: Int,
        lines: [String]
    ) -> Self {
        .init(
            kind: "insert_lines",
            position: position,
            range: nil,
            lines: lines
        )
    }

    static func replaceLines(
        start: Int,
        end: Int,
        lines: [String]
    ) -> Self {
        .init(
            kind: "replace_lines",
            position: nil,
            range: .init(
                start: start,
                end: end
            ),
            lines: lines
        )
    }
}

internal struct ScriptedLineRange: Sendable, Codable, Hashable {
    var start: Int
    var end: Int
}

internal enum ScriptedMutateFilesFixture {
    static let userFormatterPath = "scripted-user-formatter.swift"
    static let dogFormatterPath = "scripted-dog-formatter.swift"

    static func reset(
        workspaceRoot: URL
    ) throws {
        try userFormatterContent.write(
            to: workspaceRoot.appendingPathComponent(
                userFormatterPath,
                isDirectory: false
            ),
            atomically: true,
            encoding: .utf8
        )

        try dogFormatterContent.write(
            to: workspaceRoot.appendingPathComponent(
                dogFormatterPath,
                isDirectory: false
            ),
            atomically: true,
            encoding: .utf8
        )
    }

    static func snapshot(
        workspaceRoot: URL
    ) throws -> ScriptedMutateFilesSnapshot {
        try .init(
            user: read(
                userFormatterPath,
                workspaceRoot: workspaceRoot
            ),
            dog: read(
                dogFormatterPath,
                workspaceRoot: workspaceRoot
            )
        )
    }

    static func assertUnchanged(
        workspaceRoot: URL,
        originalSnapshot: ScriptedMutateFilesSnapshot
    ) throws {
        let current = try snapshot(
            workspaceRoot: workspaceRoot
        )

        guard current == originalSnapshot else {
            throw ScriptedMutateFilesApprovalTestError.expectedUnchangedFiles
        }
    }

    static func assertApprovedMutation(
        workspaceRoot: URL
    ) throws {
        let user = try read(
            userFormatterPath,
            workspaceRoot: workspaceRoot
        )
        let dog = try read(
            dogFormatterPath,
            workspaceRoot: workspaceRoot
        )

        try assertContains(
            user,
            "    internal func trimString(_ string: String) -> String {",
            path: userFormatterPath
        )

        try assertContains(
            dog,
            "    internal func trimString(_ string: String) -> String {",
            path: dogFormatterPath
        )

        try assertContains(
            user,
            "        let trimmedName = trimString(name)",
            path: userFormatterPath
        )

        try assertContains(
            user,
            "        let trimmedCity = trimString(city)",
            path: userFormatterPath
        )

        try assertContains(
            dog,
            "        let trimmedName = trimString(name)",
            path: dogFormatterPath
        )

        try assertContains(
            dog,
            "        let trimmedBreed = trimString(breed)",
            path: dogFormatterPath
        )

        try assertContains(
            dog,
            "        let trimmedClient = trimString(client)",
            path: dogFormatterPath
        )

        try assertContains(
            dog,
            "        let trimmedTopic = trimString(topic)",
            path: dogFormatterPath
        )

        try assertContains(
            dog,
            "        let trimmedStreet = trimString(street)",
            path: dogFormatterPath
        )

        try assertContains(
            dog,
            "        let trimmedCity = trimString(city)",
            path: dogFormatterPath
        )

        guard !user.contains("let trimmedName = name.trimmingCharacters(") else {
            throw ScriptedMutateFilesApprovalTestError.expectedMutation(
                "Expected \(userFormatterPath) to stop using direct name trimming."
            )
        }

        guard !dog.contains("let trimmedBreed = breed.trimmingCharacters(") else {
            throw ScriptedMutateFilesApprovalTestError.expectedMutation(
                "Expected \(dogFormatterPath) to stop using direct breed trimming."
            )
        }
    }

    static func read(
        _ path: String,
        workspaceRoot: URL
    ) throws -> String {
        try String(
            contentsOf: workspaceRoot.appendingPathComponent(
                path,
                isDirectory: false
            ),
            encoding: .utf8
        )
    }

    static func assertContains(
        _ content: String,
        _ needle: String,
        path: String
    ) throws {
        guard content.contains(
            needle
        ) else {
            throw ScriptedMutateFilesApprovalTestError.expectedMutation(
                "Expected \(path) to contain \(String(reflecting: needle))."
            )
        }
    }

    static let userFormatterContent = """
    import Foundation

    public struct ScriptedUserFormatter {
        public init() {}

        public func renderUser(
            name: String,
            city: String,
            score: Int
        ) -> String {
            let trimmedName = name.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let trimmedCity = city.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

            return "user=\\(trimmedName); city=\\(trimmedCity); score=\\(score)"
        }

        public func renderStatus(
            label: String,
            owner: String
        ) -> String {
            return "status=\\(label); owner=\\(owner)"
        }
    }

    """

    static let dogFormatterContent = """
    import Foundation

    public struct ScriptedDogFormatter {
        public init() {}

        public func renderDog(
            name: String,
            breed: String,
            age: Int
        ) -> String {
            let trimmedName = name.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let trimmedBreed = breed.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

            return "dog=\\(trimmedName); breed=\\(trimmedBreed); age=\\(age)"
        }

        public func renderClient(
            client: String,
            topic: String,
            hour: Int
        ) -> String {
            let trimmedClient = client.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let trimmedTopic = topic.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

            return "client=\\(trimmedClient); topic=\\(trimmedTopic); hour=\\(hour)"
        }

        public func renderLocation(
            street: String,
            city: String,
            zip: String
        ) -> String {
            let trimmedStreet = street.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let trimmedCity = city.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

            return "street=\\(trimmedStreet); city=\\(trimmedCity); zip=\\(zip)"
        }
    }

    """
}

internal struct ScriptedMutateFilesSnapshot: Sendable, Hashable {
    var user: String
    var dog: String
}

internal enum ScriptedMutateFilesApprovalTestError: Error, Sendable, LocalizedError {
    case expectedApproval
    case expectedMutateApproval(String)
    case unexpectedApprovalForInvalidPayload(String)
    case expectedCompletion
    case expectedUnchangedFiles
    case expectedMutation(String)
    case expectedResponse(String)
    case unexpectedScenario(String)

    var errorDescription: String? {
        switch self {
        case .expectedApproval:
            return "Expected scripted mutate_files flow to suspend for approval, but it did not."

        case .expectedMutateApproval(let toolName):
            return "Expected approval for mutate_files, but the pending tool was '\(toolName)'."

        case .unexpectedApprovalForInvalidPayload(let toolName):
            return "Invalid mutate_files payload unexpectedly reached approval for '\(toolName)'."

        case .expectedCompletion:
            return "Expected resumed scripted mutate_files flow to complete."

        case .expectedUnchangedFiles:
            return "Expected scripted fixture files to remain unchanged."

        case .expectedMutation(let message):
            return message

        case .expectedResponse(let message):
            return message

        case .unexpectedScenario(let scenario):
            return "Unexpected scripted mutate_files scenario '\(scenario)'."
        }
    }
}
