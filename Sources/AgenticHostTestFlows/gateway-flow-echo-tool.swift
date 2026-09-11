import Agentic
import AgenticExecution
import AgenticWorkspace
import Primitives
import Schema
import SchemaMacros

struct GatewayFlowEchoTool: AgentTool {
    typealias Input = GatewayFlowEchoToolInput
    typealias Output = GatewayFlowEchoToolOutput

    static let identifier: AgentToolIdentifier = .init(
        "adapter_echo_tool"
    )
    static let description = "Echoes a value back to the model."
    static let risk: ActionRisk = .observe

    var identifier: AgentToolIdentifier {
        Self.identifier
    }

    var description: String {
        Self.description
    }

    var risk: ActionRisk {
        Self.risk
    }

    func call(
        _ input: Input,
        context: AgentToolExecutionContext
    ) async throws -> Output {
        await context.observe(
            .init(
                kind: .standard_output,
                label: "stdout",
                content: "echo stdout: \(input.text)"
            )
        )
        await context.observe(
            .init(
                kind: .detail,
                label: "echo",
                content: "echo detail: \(input.text)"
            )
        )

        return GatewayFlowEchoToolOutput(
            text: input.text
        )
    }

    func process(
        _ output: Output,
        input _: Input,
        context _: AgentToolExecutionContext
    ) -> AgentToolResultProjection? {
        .init(
            status: "passed",
            summary: "Echoed conversation payload.",
            facts: [
                .init(
                    label: "text",
                    value: output.text
                ),
            ]
        )
    }
}

@JSONSchema
struct GatewayFlowEchoToolInput: Sendable, Codable, Hashable {
    var text: String
}

struct GatewayFlowEchoToolOutput: Sendable, Codable, Hashable {
    var text: String
}
