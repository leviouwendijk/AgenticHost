import Agentic
import AgenticExecution
import AgenticInterfaces
import AgenticRuntime
import AgenticCommandLine
import Schema
import SchemaMacros
import TestFlows

enum AgenticRuntimeHostAuthoredResumeFlowTesting {
    enum Failure:
        Error
    {
        case unexpectedRunState
        case missingRun
    }

    static func runResumeNextAuthoredOperation()
        async throws -> [TestFlowDiagnostic]
    {
        let probe = HostAuthoredResumeProbe()
        let tool = HostAuthoredResumeProbeTool(
            probe: probe
        )
        let coordinator = AgentToolPlanRunCoordinator(
            invoker: ToolInvoker(
                registry: try ToolRegistry {
                    tool
                },
                policy: ToolExecutionPolicy(
                    autonomyMode: .auto_observe
                )
            ),
            context: AgentToolExecutionContext(
                sessionID: "host-authored-resume-session"
            )
        )
        let first = try call(
            id: "host-authored-resume-first",
            marker: "first"
        )
        let second = try call(
            id: "host-authored-resume-second",
            marker: "second"
        )
        let third = try call(
            id: "host-authored-resume-third",
            marker: "third"
        )
        let plan = AgentToolPlan(
            id: "host-authored-resume-plan",
            root: .sequence(
                [
                    .call(
                        first
                    ),
                    .batch(
                        [
                            .call(
                                second
                            ),
                        ]
                    ),
                    .call(
                        third
                    ),
                ]
            )
        )
        let runID = "host-authored-resume-run"
        let paused = try await coordinator.start(
            plan,
            runID: runID,
            executionPolicy: .single_step
        )
        let startLog = await probe.invocationLog()

        guard case .paused(let firstPause) = paused.state,
              firstPause.afterCallID == first.id,
              startLog == "first"
        else {
            throw Failure.unexpectedRunState
        }

        let resumed = try await coordinator.resume(
            runID: runID,
            expectedRevision: paused.revision,
            executionPolicy: .single_step
        )
        let resumedLog = await probe.invocationLog()

        guard case .paused(let secondPause) = resumed.state,
              secondPause.afterPath == "root.sequence[1].batch[0]",
              secondPause.afterCallID == second.id,
              secondPause.reason == .single_step,
              resumedLog == "first,second"
        else {
            throw Failure.unexpectedRunState
        }

        guard let presentation = HostProjection.snapshot(
            runs: [
                resumed,
            ],
            context: "authored resume"
        ).runs.first else {
            throw Failure.missingRun
        }

        guard presentation.steps.count == 3,
              presentation.steps[0].state == .completed,
              presentation.steps[1].state == .completed,
              presentation.steps[2].state == .pending
        else {
            throw Failure.unexpectedRunState
        }

        return [
            .field(
                "executed",
                resumedLog
            ),
            .field(
                "pause-after",
                secondPause.afterCallID
            ),
            .field(
                "future",
                presentation.steps[2].state.rawValue
            ),
        ]
    }

    private static func call(
        id: String,
        marker: String
    ) throws -> AgentToolCall {
        AgentToolCall(
            id: id,
            name: "host_authored_resume_probe",
            input: try JSONToolBridge.encode(
                HostAuthoredResumeInput(
                    marker: marker
                )
            )
        )
    }
}

private actor HostAuthoredResumeProbe {
    private var invocations: [String] = []

    func record(
        _ marker: String
    ) {
        invocations.append(
            marker
        )
    }

    func invocationLog() -> String {
        invocations.joined(
            separator: ","
        )
    }
}

@JSONSchema
private struct HostAuthoredResumeInput:
    Sendable,
    Codable,
    Hashable
{
    let marker: String
}

private struct HostAuthoredResumeProbeTool: AgentTool {
    typealias Input = HostAuthoredResumeInput
    typealias Output = HostAuthoredResumeInput

    let identifier: AgentToolIdentifier = "host_authored_resume_probe"
    let description = "Records authored single-step resume execution order."
    let risk: ActionRisk = .observe
    let probe: HostAuthoredResumeProbe

    func call(
        _ input: Input,
        context _: AgentToolExecutionContext
    ) async throws -> Output {
        await probe.record(
            input.marker
        )

        return input
    }
}