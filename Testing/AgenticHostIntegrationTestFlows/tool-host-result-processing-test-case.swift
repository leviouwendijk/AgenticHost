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
            invocation.execution?.result,
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

        let call = ToolCall(
            id: "result-processing-render",
            tool: .init(rawValue: "swift_build"),
            input: output
        )

        let review = ToolInvocation.Review(
            call: call,
            preflight: .init(
                tool: call.tool,
                risk: .observe,
                summary: "Build product aetest in Agentic."
            ),
            requirement: .no_approval_needed
        )

        let result = ToolResult(
            toolCallID: call.id,
            tool: call.tool,
            output: output,
            projection: .init(
                status: "failed",
                summary: "Build complete! (20.64s)",
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
            isError: false
        )

        return .init(
            review: review,
            outcome: .executed(
                ToolExecutionResult(
                    result: result
                )
            )
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
            rendered.contains("swift_build"),
            "\(label) retains tool identity"
        )

        try Expect.true(
            rendered.contains("intent"),
            "\(label) labels staged intent separately from the result"
        )

        try Expect.true(
            rendered.contains(
                "Build product aetest in Agentic."
            ),
            "\(label) retains product and workspace identity from preflight"
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
            rendered.contains("Build complete! (20.64s)"),
            "\(label) renders completion summary independently from staged intent"
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


    }
}

private struct ResultProcessingFixture:
    Sendable,
    Codable,
    Hashable
{
    let value: String
}

