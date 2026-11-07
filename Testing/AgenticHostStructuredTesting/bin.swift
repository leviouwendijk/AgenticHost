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
        let callTreeOutput = try Standard.Tools.CreateCallTree.evaluate(.init(calls: [
            .init(id: "root", symbol_id: "GoalLoop"),
            .init(id: "search-1", symbol_id: "Search", parent_id: "root"),
            .init(id: "search-2", symbol_id: "Search", parent_id: "root"),
        ]))
        let callTreeValue = try JSONDecoder().decode(
            JSONValue.self, from: JSONEncoder().encode(callTreeOutput)
        )
        let callTreeCall = ToolCall(
            id: "call-3", tool: .init(rawValue: "create_call_tree"), input: .null
        )
        let callTreeRecord = AgentToolUseRecord(
            toolCall: callTreeCall, disposition: .executed,
            result: .init(call: callTreeCall.reference, output: callTreeValue)
        )
        let callTreeEvents = events + [Run.Event.State(
            kind: .tool_result, iteration: 3, toolCallID: callTreeCall.id,
            toolName: "create_call_tree", summary: "Completed"
        )]
        let allViews = AgenticConversationStructuredProjection.attachments(
            runID: "run", toolUses: [record, reportRecord, callTreeRecord], events: callTreeEvents
        )
        try check(allViews.count == 3, "graph, report, and call tree are distinct attachments")
        if case .structured(let callTreeView) = allViews[2] {
            try check(callTreeView.iteration == 3, "call tree source iteration")
            try check(callTreeView.sourceCallID == "call-3", "call tree call identity")
            try check(callTreeView.rows(columns: 80).joined(separator: "\n").contains("GoalLoop"), "inline call tree")
            try check(callTreeView.summary.contains("proposed"), "call tree provenance")
            try check(callTreeView.previewRows(columns: 80).count <= 12, "bounded inline presentation")
        } else {
            throw SmokeFailure.check("typed call tree attachment")
        }
        let malformedCallTree = AgentToolUseRecord(
            toolCall: callTreeCall, disposition: .executed,
            result: .init(call: callTreeCall.reference, output: .null)
        )
        try check(AgenticConversationStructuredProjection.attachments(
            runID: "run", toolUses: [malformedCallTree], events: callTreeEvents
        ).isEmpty, "invalid call tree output is not rendered")
        try check(AgenticConversationStructuredProjection.attachments(
            runID: "run", toolUses: [callTreeRecord], events: callTreeEvents
        ) == AgenticConversationStructuredProjection.attachments(
            runID: "run", toolUses: [callTreeRecord], events: callTreeEvents
        ), "call tree projection is deterministic")
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
