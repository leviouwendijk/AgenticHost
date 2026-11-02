import Agentic
import AgenticCommandLine
import AgenticInterfaces
import AgenticRuntime
import AgenticStandard
import Foundation
import Primitives

private enum SmokeFailure: Error {
    case check(String)
}

@main
struct ConversationHostStructuresSmoke {
    static func main() throws {
        let output = try Standard.Tools.CreateGraph.evaluate(.init(
            nodes: [
                .init(id: "a", value: .string("A")),
                .init(id: "b", value: .string("B")),
            ],
            edges: [.init(id: "ab", source: "a", destination: "b", value: .null)],
            references: [.init(id: "main", target: "b")]
        ))
        let encoded = try JSONEncoder().encode(output)
        let value = try JSONDecoder().decode(JSONValue.self, from: encoded)
        let call = ToolCall(id: "call-1", tool: .init(rawValue: "create_graph"), input: .null)
        let record = AgentToolUseRecord(
            toolCall: call,
            disposition: .executed,
            result: .init(call: call.reference, output: value)
        )
        let events: [Run.Event.State] = [
            .init(kind: .assistant_response, iteration: 2,
                  messageID: "response-2", summary: "Model responded"),
            .init(kind: .tool_result, iteration: 2,
                  toolCallID: call.id, toolName: "create_graph", summary: "Completed"),
        ]
        let messages: [Message] = [
            .init(id: "response-2", role: .assistant, content: .init(text: "Here is a graph."))
        ]
        let history = AgenticConversationStructuredProjection.iterations(
            runID: "run", messages: messages, events: events
        )
        try check(history.count == 1 && history[0].number == 2, "iteration mapping")
        try check(history[0].assistantBody == "Here is a graph.", "recorded assistant text")
        try check(history[0].toolCallIDs == ["call-1"], "tool call provenance")
        let views = AgenticConversationStructuredProjection.attachments(
            runID: "run", toolUses: [record], events: events
        )
        try check(views.count == 1 && views[0].id == "run:tool:call-1", "stable view identity")
        if case .structured(let structured) = views[0] {
            try check(structured.iteration == 2, "source iteration")
            try check(structured.rows(columns: 60).joined(separator: "\n").contains("A"), "graph available")
        } else {
            throw SmokeFailure.check("typed graph attachment")
        }
        let reportOutput = try Standard.Tools.CreateReport.evaluate(.init(
            title: "Projection report", datasets: [],
            blocks: [.init(kind: .narrative, text: "Illustrative")]
        ))
        let reportValue = try JSONDecoder().decode(
            JSONValue.self, from: JSONEncoder().encode(reportOutput)
        )
        let reportCall = ToolCall(id: "call-2", tool: .init(rawValue: "create_report"), input: .null)
        let reportRecord = AgentToolUseRecord(
            toolCall: reportCall, disposition: .executed,
            result: .init(call: reportCall.reference, output: reportValue)
        )
        let reportViews = AgenticConversationStructuredProjection.attachments(
            runID: "run", toolUses: [record, reportRecord], events: events
        )
        try check(reportViews.count == 2, "graph and report remain separate views")
        if case .structured(let report) = reportViews[1] {
            try check(report.iteration == nil, "unknown source iteration remains unknown")
            try check(report.rows(columns: 60).joined(separator: "\n").contains("Illustrative"), "report view")
        } else {
            throw SmokeFailure.check("typed report attachment")
        }
        try check(views == AgenticConversationStructuredProjection.attachments(
            runID: "run", toolUses: [record], events: events
        ), "idempotent projection")
        let denied = AgentToolUseRecord(toolCall: call, disposition: .skipped_by_user)
        try check(AgenticConversationStructuredProjection.attachments(
            runID: "run", toolUses: [denied], events: events
        ).isEmpty, "no view for skipped tools")
        print("Conversation host structured projection smoke: passed")
    }

    static func check(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        guard condition() else { throw SmokeFailure.check(description) }
    }
}
