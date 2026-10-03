import Agentic
import AgenticInterfaces
import AgenticRuntime
import AgenticCommandLine
import Primitives
import TestFlows

enum AgenticRuntimeHostAuthoredTimelineFlowTesting {
    enum Failure:
        Error
    {
        case missingRun
    }

    static func runPausedFutureStepProjection()
        throws -> [TestDiagnostic]
    {
        let first = try call(
            id: "host-authored-first",
            tool: "host_authored_first",
            marker: "first"
        )
        let second = try call(
            id: "host-authored-second",
            tool: "host_authored_second",
            marker: "second"
        )
        let plan = try ToolPlan(
            id: "host-authored-timeline-plan",
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
                ]
            )
        )
        let run = ToolPlan.Run(
            id: "host-authored-timeline-run",
            plan: plan,
            relationship: .root,
            attempts: [
                ToolPlan.Run.Attempt(
                    number: 1,
                    scope: .plan,
                    result: ToolPlan.Result(
                        planID: plan.id,
                        outcome: .succeeded,
                        records: [
                            ToolPlan.Record(
                                path: "root.sequence[0]",
                                call: first,
                                outcome: .succeeded
                            ),
                        ]
                    )
                ),
            ],
            revision: 2,
            state: .interrupted(
                ToolPlan.Run.Interruption(
                    point: .init(
                        path: "root.sequence[0]",
                        callID: first.id,
                        attemptNumber: 1
                    ),
                    reason: .policy(
                        .single_step
                    )
                )
            )
        )
        let snapshot = HostProjection.snapshot(
            runs: [
                run,
            ],
            context: "authored timeline projection"
        )

        guard let presentation = snapshot.runs.first else {
            throw Failure.missingRun
        }

        try Expect.equal(
            presentation.steps.count,
            2,
            "paused run preserves all authored call rows"
        )
        try Expect.equal(
            presentation.steps[0].id,
            first.id,
            "first authored call remains first"
        )
        try Expect.equal(
            presentation.steps[0].state,
            .completed,
            "attempted first call overlays completed state"
        )
        try Expect.equal(
            presentation.steps[1].id,
            second.id,
            "future authored batch call remains visible"
        )
        try Expect.equal(
            presentation.steps[1].state,
            .pending,
            "future authored call remains pending after single-step pause"
        )

        return [
            .field(
                "steps",
                "\(presentation.steps.count)"
            ),
            .field(
                "first",
                presentation.steps[0].state.rawValue
            ),
            .field(
                "future",
                presentation.steps[1].state.rawValue
            ),
        ]
    }

    static func runActivatedFailureBranchProjection()
        throws -> [TestDiagnostic]
    {
        let parent = try call(
            id: "host-authored-branch-parent",
            tool: "host_authored_branch_parent",
            marker: "parent"
        )
        let successOnly = try call(
            id: "host-authored-success-only",
            tool: "host_authored_success_only",
            marker: "success-only"
        )
        let repair = try call(
            id: "host-authored-branch-repair",
            tool: "host_authored_branch_repair",
            marker: "repair"
        )
        let verify = try call(
            id: "host-authored-branch-verify",
            tool: "host_authored_branch_verify",
            marker: "verify"
        )
        let deniedOnly = try call(
            id: "host-authored-denied-only",
            tool: "host_authored_denied_only",
            marker: "denied-only"
        )
        let suffix = try call(
            id: "host-authored-branch-suffix",
            tool: "host_authored_branch_suffix",
            marker: "suffix"
        )
        let plan = try ToolPlan(
            id: "host-authored-branch-timeline-plan",
            root: .sequence(
                [
                    .call(
                        parent,
                        onSuccess: [
                            .call(
                                successOnly
                            ),
                        ],
                        onFailure: [
                            .call(
                                repair
                            ),
                            .call(
                                verify
                            ),
                        ],
                        onDenied: [
                            .call(
                                deniedOnly
                            ),
                        ]
                    ),
                    .call(
                        suffix
                    ),
                ]
            )
        )
        let run = ToolPlan.Run(
            id: "host-authored-branch-timeline-run",
            plan: plan,
            relationship: .root,
            attempts: [
                ToolPlan.Run.Attempt(
                    number: 1,
                    scope: .plan,
                    result: ToolPlan.Result(
                        planID: plan.id,
                        outcome: .failed,
                        records: [
                            ToolPlan.Record(
                                path: "root.sequence[0]",
                                call: parent,
                                outcome: .failed
                            ),
                            ToolPlan.Record(
                                path: "root.sequence[0].onSuccess[0]",
                                call: successOnly,
                                outcome: .skipped,
                                skipReason: "condition_not_selected"
                            ),
                            ToolPlan.Record(
                                path: "root.sequence[0].onFailure[0]",
                                call: repair,
                                outcome: .succeeded
                            ),
                            ToolPlan.Record(
                                path: "root.sequence[0].onFailure[1]",
                                call: verify,
                                outcome: .succeeded
                            ),
                            ToolPlan.Record(
                                path: "root.sequence[0].onDenied[0]",
                                call: deniedOnly,
                                outcome: .skipped,
                                skipReason: "condition_not_selected"
                            ),
                            ToolPlan.Record(
                                path: "root.sequence[1]",
                                call: suffix,
                                outcome: .skipped,
                                skipReason: "sequence_stopped_after_failed"
                            ),
                        ]
                    )
                ),
                ToolPlan.Run.Attempt(
                    number: 2,
                    scope: .plan,
                    result: ToolPlan.Result(
                        planID: plan.id,
                        outcome: .succeeded,
                        records: [
                            ToolPlan.Record(
                                path: "root.sequence[0]",
                                call: parent,
                                outcome: .succeeded
                            ),
                            ToolPlan.Record(
                                path: "root.sequence[0].onFailure[0]",
                                call: repair,
                                outcome: .skipped,
                                skipReason: "condition_not_selected"
                            ),
                            ToolPlan.Record(
                                path: "root.sequence[0].onFailure[1]",
                                call: verify,
                                outcome: .skipped,
                                skipReason: "condition_not_selected"
                            ),
                        ]
                    )
                ),
                ToolPlan.Run.Attempt(
                    number: 3,
                    scope: .plan,
                    result: ToolPlan.Result(
                        planID: plan.id,
                        outcome: .succeeded,
                        records: [
                            ToolPlan.Record(
                                path: "root.sequence[1]",
                                call: suffix,
                                outcome: .succeeded
                            ),
                        ]
                    )
                ),
            ],
            revision: 3,
            state: .terminal(
                .succeeded
            )
        )
        let snapshot = HostProjection.snapshot(
            runs: [
                run,
            ],
            context: "activated authored branch projection"
        )

        guard let presentation = snapshot.runs.first else {
            throw Failure.missingRun
        }

        try Expect.equal(
            presentation.steps.map(\.id),
            [
                parent.id,
                repair.id,
                verify.id,
                suffix.id,
            ],
            "host timeline includes only the activated authored failure branch"
        )
        try Expect.equal(
            presentation.steps.map(\.state.rawValue),
            [
                "completed",
                "completed",
                "completed",
                "completed",
            ],
            "latest meaningful execution state survives retry projection"
        )
        try Expect.equal(
            presentation.steps[0].groups,
            [],
            "parent call remains outside authored branch grouping"
        )
        try Expect.equal(
            presentation.steps[1].groups,
            [
                "on failure",
            ],
            "first activated failure-branch call carries group ancestry"
        )
        try Expect.equal(
            presentation.steps[2].groups,
            [
                "on failure",
            ],
            "second activated failure-branch call carries group ancestry"
        )
        try Expect.equal(
            presentation.steps[3].groups,
            [],
            "resumed suffix returns to the parent timeline level"
        )

        return [
            .field(
                "steps",
                presentation.steps.map(\.id).joined(
                    separator: ","
                )
            ),
            .field(
                "repair-groups",
                presentation.steps[1].groups.joined(
                    separator: ","
                )
            ),
            .field(
                "suffix-state",
                presentation.steps[3].state.rawValue
            ),
        ]
    }
}

private extension AgenticRuntimeHostAuthoredTimelineFlowTesting {
    struct FixtureInput:
        Sendable,
        Codable,
        Hashable
    {
        let marker: String
    }

    static func call(
        id: String,
        tool: String,
        marker: String
    ) throws -> ToolCall {
        ToolCall(
            id: id,
            tool: .init(
                rawValue: tool
            ),
            input: try JSONValue.encoding(
                FixtureInput(
                    marker: marker
                )
            )
        )
    }
}
