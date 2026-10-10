import Agentic
import AgenticRuntime
import TestFlows

enum GatewayRuntimeFlowDiagnostics {
    static func input(
        _ request: AgentRequest
    ) -> TestDiagnostic {
        var lines: [String] = [
            "tools: \(request.tools.map(\.name).joined(separator: ", "))",
        ]

        for message in request.messages {
            lines.append(
                "\(message.role.rawValue): \(message.content.text)"
            )
        }

        return .section("input", lines)
    }

    static func output(
        _ response: AgentResponse
    ) -> TestDiagnostic {
        .section(
            "output",
            [
                "role: \(response.message.role.rawValue)",
                "stopReason: \(response.stopReason.rawValue)",
                "text: \(response.message.content.text)",
                "metadata: \(response.metadata)",
            ]
        )
    }

    static func stream(
        _ events: [AgentStreamEvent]
    ) -> TestDiagnostic {
        .section(
            "stream",
            events.map { event in
                switch event {
                case .messagedelta(let block):
                    return "delta: \(block)"

                case .toolcall(let call):
                    return "toolcall: \(call.tool.rawValue) id=\(call.id) input=\(call.input)"

                case .toolresult(let result):
                    return "toolresult: \(result.call.tool.rawValue) id=\(result.call.id) output=\(result.output)"

                case .completed(let response):
                    return "completed: \(response.message.content.text)"
                }
            }
        )
    }

    static func events(
        _ events: [Run.Event.State]
    ) -> TestDiagnostic {
        .field(
            "events",
            events.map(\.kind.rawValue).joined(separator: ",")
        )
    }
}
