import Agentic
import AgenticInterfaces
import AgenticRuntime
import AgenticCommandLine
import Primitives
import Schema
import Macros
import TestFlows
import Workspace

enum AgenticRuntimeHostAuthoredResumeFlowTesting {
    enum Failure:
        Error
    {
        case unexpectedRunState
        case missingRun
    }

    static func runResumeNextAuthoredOperation()
        async throws -> [TestDiagnostic]
    {
        let probe = HostAuthoredResumeProbe()
        let tool = HostAuthoredResumeProbeTool(
            probe: probe
        )
        let executor = ToolPlan.RunExecutor(
            invoker: ToolInvoker(
                registry: try ToolRegistry {
                    tool
                },
                policy: ToolExecutionPolicy(
                    autonomyMode: .auto_observe
                )
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
        let plan = try ToolPlan(
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
        let paused = try await executor.start(
            plan,
            runID: runID,
            executionPolicy: .single_step
        )
        let startLog = await probe.invocationLog()

        guard case .interrupted(let firstInterruption) = paused.state,
              firstInterruption.point.callID == first.id,
              case .policy(.single_step) = firstInterruption.reason,
              startLog == "first"
        else {
            throw Failure.unexpectedRunState
        }

        let resumed = try await executor.resume(
            paused,
            executionPolicy: .single_step
        )
        let resumedLog = await probe.invocationLog()

        guard case .interrupted(let secondInterruption) = resumed.state,
              secondInterruption.point.path == "root.sequence[1].batch[0]",
              secondInterruption.point.callID == second.id,
              case .policy(.single_step) = secondInterruption.reason,
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
                secondInterruption.point.callID
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
    ) throws -> ToolCall {
        ToolCall(
            id: id,
            tool: HostAuthoredResumeProbeTool.definition.identifier,
            input: try JSONValue.encoding(
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
    HashableSource
{
    let marker: String
}

@JSONSchema
private struct HostAuthoredResumeOutput:
    HashableResult
{
    let marker: String
}

private struct HostAuthoredResumeProbeTool: Tool {
    typealias Input = HostAuthoredResumeInput
    typealias Output = HostAuthoredResumeOutput

    static let definition = ToolDefinition(
        identifier: .init(
            rawValue: "host_authored_resume_probe"
        ),
        purpose: "Records authored single-step resume execution order.",
        risk: .observe
    )

    let probe: HostAuthoredResumeProbe

    func call(
        _ input: Input,
        workspace _: WorkspaceContext?
    ) async throws -> Output {
        await probe.record(
            input.marker
        )

        return .init(
            marker: input.marker
        )
    }
}
