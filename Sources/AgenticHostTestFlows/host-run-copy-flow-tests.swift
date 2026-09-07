import Agentic
import AgenticExecution
import AgenticInterfaces
import AgenticCommandLine
import Foundation
import TestFlows

enum AgenticRuntimeHostRunCopyFlowTesting {
    enum Failure:
        Error
    {
        case missingInputCopy
        case missingPausedOutput
        case missingPausedPlanResult
        case missingCompletedOutput
        case missingCompletedPlanResult
    }

    static func runRetainedInputAndBridgeOutput()
        async throws -> [TestFlowDiagnostic]
    {
        let runID = "host-run-copy-run"
        let exactSource = "  {\n    \"action\": \"invoke\"\n  }\n"
        let call = AgentToolCall(
            id: "host-run-copy-call",
            name: "host_run_copy_fixture",
            input: try JSONToolBridge.encode(
                FixtureInput(
                    marker: "retained"
                )
            )
        )
        let plan = AgentToolPlan(
            id: "host-run-copy-plan",
            root: .call(
                call
            )
        )
        let pendingPlans = HostPendingPlans()
        let artifacts = HostRunArtifacts()

        await pendingPlans.insert(
            plan,
            runID: runID
        )
        await artifacts.retainInput(
            exactSource,
            runID: runID
        )

        guard let readyCopy = try await HostRunCopyMaterializer.materialize(
            .runInputCopyRequested(
                runID: runID
            ),
            inputs: artifacts,
            runs: []
        ) else {
            throw Failure.missingInputCopy
        }

        try Expect.equal(
            readyCopy.text,
            exactSource,
            "READY input copy preserves the exact submitted source"
        )

        let readyOutput = try await HostRunCopyMaterializer.materialize(
            .runOutputCopyRequested(
                runID: runID
            ),
            inputs: artifacts,
            runs: []
        )

        try Expect.equal(
            readyOutput,
            Optional<HostRunCopy>.none,
            "READY run does not manufacture a partial output envelope"
        )

        let consumedPlan = await pendingPlans.take(
            runID: runID
        )

        try Expect.equal(
            consumedPlan?.id,
            Optional(
                plan.id
            ),
            "READY plan is consumed for coordinator execution"
        )

        guard let retainedCopy = try await HostRunCopyMaterializer.materialize(
            .runInputCopyRequested(
                runID: runID
            ),
            inputs: artifacts,
            runs: []
        ) else {
            throw Failure.missingInputCopy
        }

        try Expect.equal(
            retainedCopy.text,
            exactSource,
            "input source survives pending-plan consumption"
        )

        let attempt = AgentToolPlanAttempt(
            number: 1,
            scope: .plan,
            result: AgentToolPlanResult(
                planID: plan.id,
                outcome: .succeeded,
                records: [
                    AgentToolPlanRecord(
                        path: "root",
                        call: call,
                        outcome: .succeeded
                    )
                ]
            )
        )
        let paused = AgentToolPlanRun(
            id: runID,
            plan: plan,
            relationship: .root,
            attempts: [
                attempt
            ],
            revision: 1,
            state: .paused(
                AgentToolPlanPause(
                    afterPath: "root",
                    afterCallID: call.id,
                    attemptNumber: 1,
                    reason: .single_step
                )
            )
        )

        guard let pausedCopy = try await HostRunCopyMaterializer.materialize(
            .runOutputCopyRequested(
                runID: runID
            ),
            inputs: artifacts,
            runs: [
                paused
            ]
        ) else {
            throw Failure.missingPausedOutput
        }

        let pausedEnvelope = try AgenticToolHostJSON.decodeEnvelope(
            Data(
                pausedCopy.text.utf8
            )
        )

        guard let pausedResult = pausedEnvelope.planResult else {
            throw Failure.missingPausedPlanResult
        }

        try Expect.equal(
            pausedEnvelope.action,
            .invoke,
            "paused output uses the bridge invoke envelope"
        )
        try Expect.equal(
            pausedResult.planID,
            plan.id,
            "paused output preserves the authored plan id"
        )
        try Expect.equal(
            pausedResult.outcome,
            .mixed,
            "paused output uses the bridge mixed outcome"
        )
        try Expect.equal(
            pausedResult.records.map(\.path),
            [
                "root"
            ],
            "paused output preserves projected records"
        )

        let completed = AgentToolPlanRun(
            id: runID,
            plan: plan,
            relationship: .root,
            attempts: [
                attempt
            ],
            revision: 2,
            state: .completed
        )

        guard let completedCopy = try await HostRunCopyMaterializer.materialize(
            .runOutputCopyRequested(
                runID: runID
            ),
            inputs: artifacts,
            runs: [
                completed
            ]
        ) else {
            throw Failure.missingCompletedOutput
        }

        let completedEnvelope = try AgenticToolHostJSON.decodeEnvelope(
            Data(
                completedCopy.text.utf8
            )
        )

        guard let completedResult = completedEnvelope.planResult else {
            throw Failure.missingCompletedPlanResult
        }

        try Expect.equal(
            completedResult.planID,
            plan.id,
            "completed output preserves the authored plan id"
        )
        try Expect.equal(
            completedResult.outcome,
            .succeeded,
            "completed output uses the bridge succeeded outcome"
        )
        try Expect.equal(
            completedResult.records.map(\.path),
            [
                "root"
            ],
            "completed output preserves projected records"
        )

        let finalInput = await artifacts.input(
            runID: runID
        )

        try Expect.equal(
            finalInput,
            Optional(
                exactSource
            ),
            "input source survives paused and completed run projections"
        )

        return [
            .field(
                "input-bytes",
                String(exactSource.utf8.count)
            ),
            .field(
                "paused-outcome",
                String(
                    describing: pausedResult.outcome
                )
            ),
            .field(
                "completed-outcome",
                String(
                    describing: completedResult.outcome
                )
            ),
            .field(
                "records",
                String(completedResult.records.count)
            )
        ]
    }
}

private extension AgenticRuntimeHostRunCopyFlowTesting {
    struct FixtureInput:
        Sendable,
        Codable,
        Hashable
    {
        let marker: String
    }
}
