import Agentic
import AgenticExecution
import AgenticRuntime
import Foundation
import Primitives
import Schema
import TestFlows

enum AgenticRuntimePreparedIntentFailureFlowTesting {
    static func run() async throws -> [TestFlowDiagnostic] {
        let ordinaryPhase = try await proveOrdinaryFailurePersistence()
        let reportedStatus = try await proveReportedFailurePersistence()

        return [
            .field(
                "ordinary-phase",
                ordinaryPhase.rawValue
            ),
            .field(
                "reported-status",
                reportedStatus.rawValue
            ),
        ]
    }
}

private extension AgenticRuntimePreparedIntentFailureFlowTesting {
    static func proveOrdinaryFailurePersistence() async throws
        -> AgentToolCallPhase
    {
        let fixture = try RuntimePreparedIntentFailureFixture.make(
            mode: .ordinary
        )
        defer {
            fixture.remove()
        }

        let intent = try await fixture.approvedIntent()
        let executeTool = ExecutePreparedIntentTool(
            manager: fixture.manager,
            registry: fixture.registry,
            sessionID: "prepared-intent-failure-session"
        )
        let registry = try ToolRegistry {
            executeTool
        }
        let call = try executeCall(
            id: "execute-prepared-intent-ordinary-failure",
            intentID: intent.id
        )
        let failure: AgentToolCallFailure

        do {
            _ = try await registry.execute(
                call,
                context: .init(
                    sessionID: "prepared-intent-failure-session"
                )
            )
            throw RuntimePreparedIntentFailureFlowError
                .expectedOrdinaryFailure
        } catch let error as AgentToolCallError {
            failure = error.failure
        }

        let persisted = try await fixture.manager.get(
            intent.id
        )
        let record = try Expect.notNil(
            persisted.executionRecord,
            "ordinary replay failure persists an execution record"
        )
        let persistedFailure = try Expect.notNil(
            record.toolFailure,
            "ordinary replay failure persists its typed tool failure"
        )

        try Expect.equal(
            failure.phase,
            .call,
            "ordinary replay failure leaves the inner registered call phase intact"
        )
        try Expect.equal(
            persisted.status,
            .execution_failed,
            "ordinary replay failure moves the prepared intent to execution_failed"
        )
        try Expect.equal(
            record.status,
            .failed,
            "ordinary replay failure records failed execution status"
        )
        try Expect.equal(
            persistedFailure,
            failure,
            "prepared intent execution record preserves the structured failure envelope"
        )
        try Expect.equal(
            persistedFailure.toolCallID,
            "prepared-\(intent.id.rawValue)",
            "prepared intent record retains the exact replay call id"
        )

        return persistedFailure.phase
    }

    static func proveReportedFailurePersistence() async throws
        -> PreparedIntentExecutionStatus
    {
        let fixture = try RuntimePreparedIntentFailureFixture.make(
            mode: .reported
        )
        defer {
            fixture.remove()
        }

        let intent = try await fixture.approvedIntent()
        let executeTool = ExecutePreparedIntentTool(
            manager: fixture.manager,
            registry: fixture.registry,
            sessionID: "prepared-intent-reported-session"
        )
        let registry = try ToolRegistry {
            executeTool
        }
        let result = try await registry.execute(
            try executeCall(
                id: "execute-prepared-intent-reported-failure",
                intentID: intent.id
            ),
            context: .init(
                sessionID: "prepared-intent-reported-session"
            )
        )
        let output = try JSONToolBridge.decode(
            ExecutePreparedIntentToolOutput.self,
            from: result.output
        )
        let persisted = try await fixture.manager.get(
            intent.id
        )
        let record = try Expect.notNil(
            persisted.executionRecord,
            "reported replay failure persists an execution record"
        )

        try Expect.true(
            result.isError,
            "execute_prepared_intent propagates a replayed reported failure as a reported failure"
        )
        try Expect.true(
            output.toolResult.isError,
            "execute_prepared_intent output retains the inner reported failure result"
        )
        try Expect.equal(
            output.intent.status,
            .execution_failed,
            "reported replay failure returns the terminal failed prepared intent"
        )
        try Expect.equal(
            persisted.status,
            .execution_failed,
            "reported replay failure persists execution_failed"
        )
        try Expect.equal(
            record.status,
            .failed,
            "reported replay failure records failed execution status"
        )
        try Expect.true(
            record.toolFailure == nil,
            "reported failure remains a result and is not misclassified as an execution exception"
        )
        try Expect.true(
            record.result != nil,
            "reported failure preserves the replayed semantic result"
        )

        return record.status
    }

    static func executeCall(
        id: String,
        intentID: PreparedIntentIdentifier
    ) throws -> AgentToolCall {
        AgentToolCall(
            id: id,
            name: AgentToolIdentifier.execute_prepared_intent.rawValue,
            input: try JSONToolBridge.encode(
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
    let registry: ToolRegistry
    let tool: RuntimePreparedIntentFailureProbeTool

    static func make(
        mode: RuntimePreparedIntentFailureMode
    ) throws -> Self {
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
        let tool = RuntimePreparedIntentFailureProbeTool(
            mode: mode
        )

        return .init(
            root: root,
            manager: manager,
            registry: try ToolRegistry {
                tool
            },
            tool: tool
        )
    }

    func approvedIntent() async throws -> PreparedIntent {
        let input = RuntimePreparedIntentFailureInput(
            value: "fixture"
        )
        let intent = try await manager.create(
            PreparedIntentDraft(
                sessionID: "prepared-intent-failure-session",
                actionType: "fixture_action",
                reviewPayload: .init(
                    title: "Fixture prepared intent",
                    summary: "Exercise prepared-intent replay failure persistence.",
                    actionType: "fixture_action",
                    risk: .observe,
                    exactInputs: try JSONToolBridge.encode(
                        input
                    )
                ),
                executionToolName: tool.identifier.rawValue
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

private enum RuntimePreparedIntentFailureMode:
    Sendable
{
    case ordinary
    case reported
}

private struct RuntimePreparedIntentFailureInput:
    Sendable,
    Codable,
    Hashable,
    JSONSchemaProviding
{
    let value: String

    static var jsonschema: JSONSchema {
        .any
    }
}

private struct RuntimePreparedIntentFailureOutput:
    Sendable,
    Codable,
    Hashable
{
    let value: String
}

private struct RuntimePreparedIntentFailureProbeTool:
    AgentTool
{
    typealias Input =
        RuntimePreparedIntentFailureInput

    typealias Output =
        RuntimePreparedIntentFailureOutput

    let identifier: AgentToolIdentifier =
        "runtime_prepared_intent_failure_probe"

    let description =
        "Exercises prepared-intent replay failure persistence."

    let risk: ActionRisk =
        .observe

    let mode: RuntimePreparedIntentFailureMode

    func call(
        _ input: Input,
        context _: AgentToolExecutionContext
    ) async throws -> Output {
        switch mode {
        case .ordinary:
            throw RuntimePreparedIntentFailureProbeError.ordinary

        case .reported:
            throw AgentToolReportedFailure(
                output: Output(
                    value: "reported:\(input.value)"
                )
            )
        }
    }
}

private enum RuntimePreparedIntentFailureProbeError:
    Error,
    LocalizedError
{
    case ordinary

    var errorDescription: String? {
        "fixture ordinary failure"
    }
}

private enum RuntimePreparedIntentFailureFlowError:
    Error
{
    case expectedOrdinaryFailure
}
