import Agentic
import AgenticRuntime
import Foundation
import Primitives
import TestFlows

enum AgenticRuntimePreparedIntentFailureFlowTesting {
    static func run() async throws -> [TestDiagnostic] {
        let fixture = try RuntimePreparedIntentFailureFixture.make()
        defer {
            fixture.remove()
        }

        let intent = try await fixture.approvedIntent()
        let executor = PreparedIntentExecutor(
            manager: fixture.manager,
            registry: fixture.registry,
            sessionID: "prepared-intent-failure-session"
        )
        let executeTool = ExecutePreparedIntentTool(
            executor: executor
        )
        let registry = try ToolRegistry {
            executeTool
        }
        let call = try executeCall(
            id: "execute-prepared-intent-failure",
            intentID: intent.id
        )
        let failure: ToolCall.Failure

        do {
            _ = try await registry.execute(
                call
            )
            throw RuntimePreparedIntentFailureFlowError
                .expectedFailure
        } catch let error as ToolCall.Error {
            failure = error.failure
        }

        let persisted = try await fixture.manager.get(
            intent.id
        )
        let record = try Expect.notNil(
            persisted.executionRecord,
            "prepared-operation failure persists an execution record"
        )

        try Expect.equal(
            failure.phase,
            .call,
            "prepared-operation execution failure surfaces from the execute_prepared_intent call phase"
        )
        try Expect.equal(
            persisted.status,
            .execution_failed,
            "prepared-operation failure moves the prepared intent to execution_failed"
        )
        try Expect.equal(
            record.status,
            .failed,
            "prepared-operation failure records failed execution status"
        )
        try Expect.equal(
            record.operation,
            RuntimePreparedIntentFailureOperation.schema,
            "prepared-intent execution record preserves the exact operation schema"
        )
        try Expect.true(
            record.result == nil,
            "prepared-operation failure does not fabricate a result envelope"
        )
        try Expect.equal(
            record.errorMessage,
            "fixture prepared operation failure",
            "prepared-operation failure persists its localized error message"
        )
        try Expect.equal(
            record.metadata["execution_mode"],
            "prepared_operation",
            "prepared-operation failure records canonical execution mode"
        )
        try Expect.equal(
            record.metadata["operation_identifier"],
            RuntimePreparedIntentFailureOperation
                .schema
                .identifier
                .rawValue,
            "prepared-operation failure records canonical operation identity"
        )

        return [
            .field(
                "phase",
                failure.phase.rawValue
            ),
            .field(
                "status",
                record.status.rawValue
            ),
            .field(
                "operation",
                record.operation.identifier.rawValue
            ),
            .field(
                "error",
                record.errorMessage ?? "<nil>"
            ),
        ]
    }

    private static func executeCall(
        id: String,
        intentID: PreparedIntentIdentifier
    ) throws -> ToolCall {
        ToolCall(
            id: id,
            tool: .execute_prepared_intent,
            input: try JSONValue.encoding(
                ExecutePreparedIntentToolInput(
                    id: intentID
                )
            )
        )
    }
}

private struct RuntimePreparedIntentFailureFixture {
    let root: URL
    let manager: PreparedIntentManager
    let registry: PreparedOperationRegistry

    static func make() throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "agentic-runtime-prepared-intent-failure-\(UUID().uuidString)",
                isDirectory: true
            )
        let manager = PreparedIntentManager(
            store: FilePreparedIntentStore(
                preparedIntentsdir: root
            )
        )
        var registry = PreparedOperationRegistry()

        try registry.register(
            RuntimePreparedIntentFailureOperation()
        )

        return .init(
            root: root,
            manager: manager,
            registry: registry
        )
    }

    func approvedIntent() async throws -> PreparedIntent {
        let operation = try RuntimePreparedIntentFailureOperation.envelope(
            .init(
                value: "fixture"
            )
        )
        let tool = ToolIdentifier(
            rawValue: "runtime_prepared_intent_failure_fixture"
        )
        let preflight = ToolPreflight(
            tool: tool,
            risk: .observe,
            summary: "Exercise canonical prepared-operation failure persistence."
        )
        let prepared = ToolInvocation.Prepared(
            review: .init(
                call: .init(
                    id: "runtime-prepared-intent-failure-call",
                    tool: tool,
                    input: .object([:])
                ),
                preflight: preflight,
                requirement: .needs_human_review
            ),
            operation: operation
        )
        let intent = try await manager.create(
            PreparedIntentDraft(
                sessionID: "prepared-intent-failure-session",
                invocation: prepared
            )
        )

        return try await manager.review(
            id: intent.id,
            decision: .approve,
            reviewer: "runtime-test"
        )
    }

    func remove() {
        try? FileManager.default.removeItem(
            at: root
        )
    }
}

private struct RuntimePreparedIntentFailureOperation:
    AgentPreparedOperation,
    Sendable
{
    struct Plan:
        Sendable,
        Codable,
        Hashable
    {
        let value: String
    }

    struct Result:
        Sendable,
        Codable,
        Hashable
    {
        let value: String
    }

    static let schema = PreparedOperation.Schema(
        identifier: "runtime_prepared_intent_failure_fixture",
        version: .init(
            major: 0,
            minor: 1,
            patch: 0
        )
    )

    func execute(
        _ plan: Plan,
        context _: PreparedOperation.Context
    ) async throws -> Result {
        _ = plan

        throw RuntimePreparedIntentFailureOperationError.failed
    }
}

private enum RuntimePreparedIntentFailureOperationError:
    Error,
    LocalizedError
{
    case failed

    var errorDescription: String? {
        "fixture prepared operation failure"
    }
}

private enum RuntimePreparedIntentFailureFlowError:
    Error
{
    case expectedFailure
}