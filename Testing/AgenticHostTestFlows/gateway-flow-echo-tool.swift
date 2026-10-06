import Agentic
import Workspace
import Primitives
import Schema
import Macros

struct GatewayFlowEchoTool: Tool {
    typealias Input = GatewayFlowEchoToolInput
    typealias Output = GatewayFlowEchoToolOutput

    static let definition = ToolDefinition(
        identifier: .init(rawValue: "adapter_echo_tool"),
        purpose: "Echoes a value back to the model.",
        risk: .observe
    )

    static var identifier: ToolIdentifier {
        definition.identifier
    }

    func call(
        _ input: Input,
        in _: ToolContext
    ) async throws -> Output {
        await ToolExecutionObservations.emit(.init(
            kind: .standard_output,
            content: "echo stdout: \(input.text)\n"
        ))
        await ToolExecutionObservations.emit(.init(
            kind: .detail,
            content: "echo detail: \(input.text)"
        ))
        return .init(
            text: input.text
        )
    }

    func process(
        _ output: Output,
        input _: Input
    ) throws -> ToolCall.ResultProjection? {
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
struct GatewayFlowEchoToolInput: HashableSource {
    var text: String
}

@JSONSchema
struct GatewayFlowEchoToolOutput: HashableResult {
    var text: String
}
