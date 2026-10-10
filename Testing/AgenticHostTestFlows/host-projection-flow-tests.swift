import Agentic
import AgenticInterfaces
import AgenticCommandLine
import Primitives
import TestFlows

enum AgenticRuntimeHostProjectionFlowTesting {
    enum Failure:
        Error
    {
        case missingStdout
        case missingStderr
        case missingDetails
        case missingStep
        case missingRun
        case unexpectedSuspensionProjection
    }

    static func runSuspensionStateProjection() throws -> [TestDiagnostic] {
        let call = ToolCall(
            id: "host-suspension-projection-call",
            tool: ToolIdentifier(rawValue: "host_suspension_projection"),
            input: .object([:])
        )
        let plan = try ToolPlan(
            id: "host-suspension-projection-plan",
            root: .call(
                call
            )
        )
        let resolution = ToolPlan.Run.Resolution(
            revision: 2,
            path: "root",
            callID: call.id,
            kind: .skipped
        )
        let failureRun = ToolPlan.Run(
            id: "host-suspension-failure",
            plan: plan,
            relationship: .root,
            attempts: [],
            revision: 1,
            state: .interrupted(
                .init(
                    point: .init(
                        path: "root",
                        callID: call.id,
                        attemptNumber: 1
                    ),
                    reason: .failure(
                        .init(
                            errorDescription: "fixture failure"
                        )
                    )
                )
            )
        )
        let continuationRun = ToolPlan.Run(
            id: "host-suspension-continuation",
            plan: plan,
            relationship: .root,
            attempts: [],
            resolutions: [
                resolution,
            ],
            revision: 2,
            state: .interrupted(
                .init(
                    point: .init(
                        path: "root",
                        callID: call.id,
                        attemptNumber: 1
                    ),
                    reason: .continuation_required(
                        resolution
                    )
                )
            )
        )
        let snapshot = HostProjection.snapshot(
            runs: [
                failureRun,
                continuationRun,
            ],
            context: "host suspension projection"
        )

        guard snapshot.runs.count == 2 else {
            throw Failure.missingRun
        }

        guard snapshot.runs[0].state == .onHold,
              snapshot.runs[1].state == .paused,
              snapshot.runs[0].state.executionControls.isEmpty,
              snapshot.runs[1].state.executionControls == [
                .execute_run,
                .execute_step_and_wait,
              ],
              snapshot.interruptions.count == 2,
              snapshot.interruptions[0].actions == [
                .retry,
                .skip,
                .create_fix_branch,
              ],
              snapshot.interruptions[1].actions == [
                .continue_run,
              ]
        else {
            throw Failure.unexpectedSuspensionProjection
        }

        return [
            .field(
                "failure-state",
                snapshot.runs[0].state.rawValue
            ),
            .field(
                "continuation-state",
                snapshot.runs[1].state.rawValue
            ),
        ]
    }

    static func runOutputDocuments() throws -> [TestDiagnostic] {
        let invocation = try fixtureInvocation()
        let call = ToolCall(
            id: invocation.review.invocation.id,
            tool: invocation.review.invocation.tool,
            input: invocation.review.invocation.arguments
        )
        let plan = try ToolPlan(
            id: "host-output-documents-plan",
            root: .call(
                call
            )
        )
        let run = ToolPlan.Run(
            id: "host-output-documents-run",
            plan: plan,
            relationship: .root,
            attempts: [
                .init(
                    number: 1,
                    scope: .plan,
                    result: .init(
                        planID: plan.id,
                        outcome: .succeeded,
                        records: [
                            .init(
                                path: "root",
                                call: call,
                                outcome: .succeeded,
                                invocation: invocation
                            ),
                        ]
                    )
                ),
            ],
            revision: 1,
            state: .terminal(.succeeded)
        )
        let snapshot = HostProjection.snapshot(
            runs: [
                run,
            ],
            context: "host output documents"
        )

        guard let presentedRun = snapshot.runs.first,
              let step = presentedRun.steps.first
        else {
            throw Failure.missingStep
        }

        let fields = Dictionary(
            uniqueKeysWithValues:
                step.fields.map { field in
                    (
                        field.label,
                        field.value
                    )
                }
        )

        guard let stdout = snapshot.documents.first(
            where: {
                $0.kind == .stdout
            }
        ) else {
            throw Failure.missingStdout
        }

        guard let stderr = snapshot.documents.first(
            where: {
                $0.kind == .stderr
            }
        ) else {
            throw Failure.missingStderr
        }

        guard snapshot.documents.contains(
            where: {
                $0.kind == .details
            }
        ) else {
            throw Failure.missingDetails
        }

        try Expect.equal(
            presentedRun.summary,
            "root · rev 1 · succeeded · 1 executed · 0 skipped",
            "completed run summary uses the canonical bridge result projection"
        )
        try Expect.equal(
            fields["outcome"],
            Optional(
                "succeeded"
            ),
            "step inspector presents record outcome"
        )
        try Expect.equal(
            fields["decision"],
            Optional(
                "approved"
            ),
            "step inspector presents invocation decision"
        )
        try Expect.equal(
            fields["operation"],
            Optional(
                "passed"
            ),
            "step inspector presents result operation status"
        )
        try Expect.equal(
            fields["summary"],
            Optional(
                "Fixture completed."
            ),
            "result summary replaces the preflight fallback"
        )
        try Expect.equal(
            fields["candidates"],
            Optional(
                "0"
            ),
            "step inspector presents result projection facts"
        )

        try Expect.equal(
            stdout.id,
            "host-output-documents-run:host-output-documents-call:stdout",
            "stdout document identity is stable by run, step, and stream"
        )
        try Expect.equal(
            stdout.body,
            "compile started\ncompile finished\n",
            "stdout observations preserve authored order without synthetic separators"
        )
        try Expect.equal(
            stderr.id,
            "host-output-documents-run:host-output-documents-call:stderr",
            "stderr document identity is stable by run, step, and stream"
        )
        try Expect.equal(
            stderr.body,
            "error: fixture failed\n",
            "stderr preserves raw standard-error observation content"
        )
        try Expect.equal(
            stdout.body.contains(
                "diagnostic-only"
            ),
            false,
            "non-stream observations do not leak into stdout documents"
        )

        return [
            .field(
                "stdout-bytes",
                "\(stdout.body.utf8.count)"
            ),
            .field(
                "stderr-bytes",
                "\(stderr.body.utf8.count)"
            ),
            .field(
                "documents",
                "\(snapshot.documents.count)"
            ),
        ]
    }

    static func runEmptyOutputDocuments() throws -> [TestDiagnostic] {
        let invocation = try emptyFixtureInvocation()
        let call = ToolCall(
            id: invocation.review.invocation.id,
            tool: invocation.review.invocation.tool,
            input: invocation.review.invocation.arguments
        )
        let plan = try ToolPlan(
            id: "host-empty-output-documents-plan",
            root: .call(
                call
            )
        )
        let run = ToolPlan.Run(
            id: "host-empty-output-documents-run",
            plan: plan,
            relationship: .root,
            attempts: [
                .init(
                    number: 1,
                    scope: .plan,
                    result: .init(
                        planID: plan.id,
                        outcome: .succeeded,
                        records: [
                            .init(
                                path: "root",
                                call: call,
                                outcome: .succeeded,
                                invocation: invocation
                            ),
                        ]
                    )
                ),
            ],
            revision: 1,
            state: .terminal(.succeeded)
        )
        let snapshot = HostProjection.snapshot(
            runs: [
                run,
            ],
            context: "host empty output documents"
        )

        guard let stdout = snapshot.documents.first(
            where: {
                $0.kind == .stdout
            }
        ) else {
            throw Failure.missingStdout
        }

        guard let stderr = snapshot.documents.first(
            where: {
                $0.kind == .stderr
            }
        ) else {
            throw Failure.missingStderr
        }

        try Expect.equal(
            stdout.body,
            "stdout is empty.",
            "executed zero-byte stdout is explicit"
        )
        try Expect.equal(
            stderr.body,
            "stderr is empty.",
            "executed zero-byte stderr is explicit"
        )

        return [
            .field(
                "stdout",
                stdout.body
            ),
            .field(
                "stderr",
                stderr.body
            ),
        ]
    }
}

private extension AgenticRuntimeHostProjectionFlowTesting {
    struct FixtureOutput:
        Sendable,
        Codable,
        Hashable
    {
        let value: String
    }

    static func emptyFixtureInvocation() throws -> ToolInvocation.Result {
        let output = try JSONValue.encoding(
            FixtureOutput(
                value: "authoritative-empty"
            )
        )
        let call = ToolCall(
            id: "host-empty-output-documents-call",
            tool: ToolIdentifier(
                rawValue: "host_empty_output_documents_fixture"
            ),
            input: output
        )
        let invocation = ToolInvocation(
            id: call.id,
            tool: call.tool,
            arguments: call.input
        )
        let review = ToolInvocation.Review(
            invocation: invocation,
            preflight: .init(
                tool: call.tool,
                risk: .observe,
                summary: "Host empty output projection fixture."
            ),
            requirement: .no_approval_needed,
            references: []
        )
        let result = ToolCall.Response(
            call: call.reference,
            output: output,
            isError: false
        )

        return .init(
            review: review,
            outcome: .executed(
                ToolExecution.Result(
                    result: result
                )
            )
        )
    }

    static func fixtureInvocation() throws -> ToolInvocation.Result {
        let output = try JSONValue.encoding(
            FixtureOutput(
                value: "authoritative"
            )
        )
        let call = ToolCall(
            id: "host-output-documents-call",
            tool: ToolIdentifier(
                rawValue: "host_output_documents_fixture"
            ),
            input: output
        )
        let invocation = ToolInvocation(
            id: call.id,
            tool: call.tool,
            arguments: call.input
        )
        let review = ToolInvocation.Review(
            invocation: invocation,
            preflight: .init(
                tool: call.tool,
                risk: .observe,
                summary: "Host output projection fixture."
            ),
            requirement: .no_approval_needed,
            references: []
        )
        let result = ToolCall.Response(
            call: call.reference,
            output: output,
            projection: .init(
                status: "passed",
                summary: "Fixture completed.",
                facts: [
                    .init(
                        label: "candidates",
                        value: "0"
                    ),
                    .init(
                        label: "mode",
                        value: "ranked"
                    ),
                ]
            ),
            isError: false
        )

        return .init(
            review: review,
            outcome: .executed(
                ToolExecution.Result(
                    result: result,
                    observations: [
                        .init(kind: .standard_output, content: "compile started\n"),
                        .init(kind: .diagnostic, content: "diagnostic-only"),
                        .init(kind: .standard_error, content: "error: fixture failed\n"),
                        .init(kind: .standard_output, content: "compile finished\n"),
                    ]
                )
            )
        )
    }

}
