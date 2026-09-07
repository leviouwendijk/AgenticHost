import AgenticExecution
import Agentic
import AgenticInterfaces
import Primitives
import TestFlows

enum ToolHostResultProcessingTestCase {
    static func make() -> AgenticInterfaceTestCase {
        .init(
            id: "tool-host-result-processing-render",
            summary: "Render semantic result processing and observations without relying on compatibility receipts."
        ) { _ in
            try await run()
        }
    }
}

private extension ToolHostResultProcessingTestCase {
    static func run() async throws {
        let invocation = try fixtureInvocation()

        _ = try Expect.notNil(
            invocation.toolResult,
            "result-processing rendering fixture tool result"
        )

        let renderer =
            TerminalToolHostReceiptRenderer()

        let invocationRender = renderer.render(
            .init(
                action: .invoke,
                invocation: invocation
            )
        )

        try assertProcessingRender(
            invocationRender,
            label: "single invocation"
        )

        let planRender = renderer.render(
            .init(
                action: .invoke,
                planResult: .init(
                    planID: "result-processing-render-plan",
                    outcome: .succeeded,
                    records: [
                        .init(
                            path: "root.sequence[0]",
                            call: invocation.review.call,
                            outcome: .succeeded,
                            invocation: invocation
                        )
                    ]
                )
            )
        )

        try assertProcessingRender(
            planRender,
            label: "plan invocation"
        )
    }

    static func fixtureInvocation() throws -> ToolInvocation.Result {
        let output = try JSONToolBridge.encode(
            ResultProcessingFixture(
                value: "authoritative"
            )
        )

        let call = AgentToolCall(
            id: "result-processing-render",
            name: "result_processing_fixture",
            input: output
        )

        let review = ToolInvocation.Review(
            call: call,
            preflight: .init(
                toolName: call.name,
                risk: .observe,
                summary: "Preflight fallback."
            ),
            requirement: .no_approval_needed,
            guidelineRelations: []
        )

        let result = AgentToolResult(
            toolCallID: call.id,
            name: call.name,
            output: output,
            processing: .init(
                projection: .init(
                    status: "failed",
                    summary: "Semantic operation failed.",
                    facts: [
                        .init(
                            label: "configuration",
                            value: "debug"
                        ),
                        .init(
                            label: "exit",
                            value: "1"
                        ),
                    ]
                ),
                observations: [
                    .init(
                        kind: .standard_output,
                        content:
                            "\ncompile started\n\n  indented detail\n"
                    ),
                    .init(
                        kind: .standard_error,
                        label: "compiler stderr",
                        content:
                            "\nerror: fixture failed\n"
                    ),
                ]
            ),
            isError: false
        )

        return .init(
            review: review,
            decision: .approved,
            toolResult: result
        )
    }

    static func assertProcessingRender(
        _ rendered: String,
        label: String
    ) throws {
        try Expect.true(
            rendered.contains("succeeded"),
            "\(label) keeps Agentic execution successful"
        )

        try Expect.true(
            rendered.contains("operation"),
            "\(label) renders operation label"
        )

        try Expect.true(
            rendered.contains("failed"),
            "\(label) renders semantic operation failure independently"
        )

        try Expect.true(
            rendered.contains("Semantic operation failed."),
            "\(label) renders projection summary"
        )

        try Expect.true(
            rendered.contains("configuration"),
            "\(label) renders semantic fact label"
        )

        try Expect.true(
            rendered.contains("debug"),
            "\(label) renders semantic fact value"
        )

        try Expect.true(
            rendered.contains("exit"),
            "\(label) renders exit fact"
        )

        try Expect.true(
            rendered.contains("stdout"),
            "\(label) derives stdout observation label"
        )

        try Expect.true(
            rendered.contains("compile started"),
            "\(label) renders stdout observation content"
        )

        try Expect.true(
            rendered.contains("  indented detail"),
            "\(label) preserves internal observation indentation"
        )

        try Expect.true(
            rendered.contains("compiler stderr"),
            "\(label) renders custom observation label"
        )

        try Expect.true(
            rendered.contains("error: fixture failed"),
            "\(label) renders stderr evidence"
        )

        try Expect.true(
            !rendered.contains("Preflight fallback."),
            "\(label) prefers semantic projection summary over preflight fallback"
        )
    }
}

private struct ResultProcessingFixture:
    Sendable,
    Codable,
    Hashable
{
    let value: String
}

