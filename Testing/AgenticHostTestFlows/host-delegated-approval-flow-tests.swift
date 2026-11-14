import Agentic
import AgenticInterfaces
import AgenticRuntime
import AgenticTUI
import Difference
import Primitives
import TestFlows

extension AgenticRuntimeHostProjectionFlowTesting {
    /// An approval raised by a delegated worker reaches the parent run with
    /// the worker's call ID and no tool record of its own; review still
    /// shows the exact prepared diff from the approval.
    static func runDelegatedApprovalDocuments() throws -> [TestDiagnostic] {
        let call = FunctionCall(id: "worker-mutate", name: "mutate_files", input: .object([:]))
        let difference = ToolPreflight.Preview.Difference(
            title: "Sources/a.swift",
            layout: DifferenceLayout(lines: [
                .init(role: .delete, text: "old", coordinate: .init(old: 1)),
                .init(role: .insert, text: "new", coordinate: .init(new: 1)),
            ])
        )
        func result(_ preview: ToolPreflight.Preview) -> AgentExecutor.Result {
            .init(
                sessionID: "parent",
                phase: .awaiting_approval,
                response: nil,
                pendingApproval: PendingApproval(
                    functionCall: call,
                    preflight: ToolPreflight(
                        tool: "mutate_files",
                        risk: .boundedmutate,
                        summary: "Edit Sources/a.swift",
                        preview: preview
                    ),
                    requirement: .needs_human_review
                ),
                state: .init()
            )
        }

        let projection = AgenticConversationRunProjection.project(
            result(.init(difference: difference)),
            title: "orchestrator"
        )
        let interruption = try Expect.notNil(projection.interruptions.first, "The approval is shown")
        let reviewed = projection.documents.filter {
            $0.runID == interruption.runID && $0.stepID == interruption.stepID
        }
        try Expect.equal(
            Set(reviewed.map(\.kind)),
            [.diff, .details],
            "Review finds Diff and Details under the approval's step"
        )
        try Expect.equal(
            reviewed.first { $0.kind == .diff }?.differenceBody,
            difference,
            "The Diff is the approval's own prepared difference"
        )

        let withoutPreview = AgenticConversationRunProjection.project(
            result(.init()),
            title: "orchestrator"
        )
        let details = try Expect.notNil(
            withoutPreview.documents.first { $0.kind == .details && $0.stepID == call.id },
            "Details are shown without a preview"
        )
        try Expect.true(
            details.body.contains("diff     not available"),
            "A missing diff is stated, not silently omitted"
        )
        try Expect.true(
            !withoutPreview.documents.contains { $0.kind == .diff },
            "No empty Diff is offered"
        )
        return []
    }
}
