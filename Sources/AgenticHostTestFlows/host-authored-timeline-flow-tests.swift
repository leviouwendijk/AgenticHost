import Agentic
import AgenticExecution
import AgenticInterfaces
import AgenticRuntime
import AgenticCommandLine
import TestFlows

enum AgenticRuntimeHostAuthoredTimelineFlowTesting {
    enum Failure:
        Error
    {
        case missingRun
    }

    static func runPausedFutureStepProjection()
        throws -> [TestFlowDiagnostic]
    {
        let first = AgentToolCall(
            id: "host-authored-first",
            name: "host_authored_first",
            input: try JSONToolBridge.encode(
                FixtureInput(
                    marker: "first"
                )
            )
        )
        let second = AgentToolCall(
            id: "host-authored-second",
            name: "host_authored_second",
            input: try JSONToolBridge.encode(
                FixtureInput(
                    marker: "second"
                )
            )
        )
        let plan = AgentToolPlan(
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
        let run = AgentToolPlanRun(
            id: "host-authored-timeline-run",
            plan: plan,
            relationship: .root,
            attempts: [
                AgentToolPlanAttempt(
                    number: 1,
                    scope: .plan,
                    result: AgentToolPlanResult(
                        planID: plan.id,
                        outcome: .succeeded,
                        records: [
                            AgentToolPlanRecord(
                                path: "root.sequence[0]",
                                call: first,
                                outcome: .succeeded
                            ),
                        ]
                    )
                ),
            ],
            revision: 2,
            state: .paused(
                AgentToolPlanPause(
                    afterPath: "root.sequence[0]",
                    afterCallID: first.id,
                    attemptNumber: 1,
                    reason: .single_step
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
        throws -> [TestFlowDiagnostic]
    {
        let parent = AgentToolCall(
            id: "host-authored-branch-parent",
            name: "host_authored_branch_parent",
            input: try JSONToolBridge.encode(
                FixtureInput(
                    marker: "parent"
                )
            )
        )
        let successOnly = AgentToolCall(
            id: "host-authored-success-only",
            name: "host_authored_success_only",
            input: try JSONToolBridge.encode(
                FixtureInput(
                    marker: "success-only"
                )
            )
        )
        let repair = AgentToolCall(
            id: "host-authored-branch-repair",
            name: "host_authored_branch_repair",
            input: try JSONToolBridge.encode(
                FixtureInput(
                    marker: "repair"
                )
            )
        )
        let verify = AgentToolCall(
            id: "host-authored-branch-verify",
            name: "host_authored_branch_verify",
            input: try JSONToolBridge.encode(
                FixtureInput(
                    marker: "verify"
                )
            )
        )
        let deniedOnly = AgentToolCall(
            id: "host-authored-denied-only",
            name: "host_authored_denied_only",
            input: try JSONToolBridge.encode(
                FixtureInput(
                    marker: "denied-only"
                )
            )
        )
        let suffix = AgentToolCall(
            id: "host-authored-branch-suffix",
            name: "host_authored_branch_suffix",
            input: try JSONToolBridge.encode(
                FixtureInput(
                    marker: "suffix"
                )
            )
        )
        let plan = AgentToolPlan(
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
        let run = AgentToolPlanRun(
            id: "host-authored-branch-timeline-run",
            plan: plan,
            relationship: .root,
            attempts: [
                AgentToolPlanAttempt(
                    number: 1,
                    scope: .plan,
                    result: AgentToolPlanResult(
                        planID: plan.id,
                        outcome: .failed,
                        records: [
                            AgentToolPlanRecord(
                                path: "root.sequence[0]",
                                call: parent,
                                outcome: .failed
                            ),
                            AgentToolPlanRecord(
                                path: "root.sequence[0].onSuccess[0]",
                                call: successOnly,
                                outcome: .skipped,
                                skipReason: "condition_not_selected"
                            ),
                            AgentToolPlanRecord(
                                path: "root.sequence[0].onFailure[0]",
                                call: repair,
                                outcome: .succeeded
                            ),
                            AgentToolPlanRecord(
                                path: "root.sequence[0].onFailure[1]",
                                call: verify,
                                outcome: .succeeded
                            ),
                            AgentToolPlanRecord(
                                path: "root.sequence[0].onDenied[0]",
                                call: deniedOnly,
                                outcome: .skipped,
                                skipReason: "condition_not_selected"
                            ),
                            AgentToolPlanRecord(
                                path: "root.sequence[1]",
                                call: suffix,
                                outcome: .skipped,
                                skipReason: "sequence_stopped_after_failed"
                            ),
                        ]
                    )
                ),
                AgentToolPlanAttempt(
                    number: 2,
                    scope: .plan,
                    result: AgentToolPlanResult(
                        planID: plan.id,
                        outcome: .succeeded,
                        records: [
                            AgentToolPlanRecord(
                                path: "root.sequence[0]",
                                call: parent,
                                outcome: .succeeded
                            ),
                            AgentToolPlanRecord(
                                path: "root.sequence[0].onFailure[0]",
                                call: repair,
                                outcome: .skipped,
                                skipReason: "condition_not_selected"
                            ),
                            AgentToolPlanRecord(
                                path: "root.sequence[0].onFailure[1]",
                                call: verify,
                                outcome: .skipped,
                                skipReason: "condition_not_selected"
                            ),
                        ]
                    )
                ),
                AgentToolPlanAttempt(
                    number: 3,
                    scope: .plan,
                    result: AgentToolPlanResult(
                        planID: plan.id,
                        outcome: .succeeded,
                        records: [
                            AgentToolPlanRecord(
                                path: "root.sequence[1]",
                                call: suffix,
                                outcome: .succeeded
                            ),
                        ]
                    )
                ),
            ],
            revision: 3,
            state: .completed
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
}
