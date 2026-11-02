import Agentic
import AgenticInterfaces
import AgenticRuntime
import AgenticStandard
import Foundation

/// Projects existing runtime evidence into message-facing history and views.
/// Checkpoint events and tool results are authoritative; no new storage.
package enum AgenticConversationStructuredProjection {
    package static func iterations(
        runID: String,
        messages: [Message],
        events: [Run.Event.State]
    ) -> [AgenticConversationIterationPresentation] {
        let grouped = Dictionary(grouping: events, by: \.iteration)
        return grouped.keys.sorted().map { number in
            let records = grouped[number] ?? []
            let assistantID = records.last(where: {
                $0.kind == .assistant_response && $0.messageID != nil
            })?.messageID
            let body = assistantID.flatMap { id in
                messages.first(where: { $0.id == id })?.content.text
            }
            var callIDs: [String] = []
            var seen: Set<String> = []
            for event in records {
                if let callID = event.toolCallID, seen.insert(callID).inserted {
                    callIDs.append(callID)
                }
            }
            let salient = records.filter {
                $0.kind != .assistant_delta && $0.kind != .model_stream_tool_call
            }
            let summaries = salient.prefix(64).map {
                "\($0.kind.rawValue) · \($0.summary)"
            }
            let overflow = salient.count > 64 ? ["Additional events available in the run trace."] : []
            return .init(
                id: "\(runID):iteration:\(number)",
                number: number,
                assistantBody: body,
                events: summaries + overflow,
                toolCallIDs: callIDs
            )
        }
    }

    package static func attachments(
        runID: String,
        toolUses: [AgentToolUseRecord],
        events: [Run.Event.State]
    ) -> [AgenticConversationAttachmentPresentation] {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        return toolUses.compactMap { record -> AgenticConversationAttachmentPresentation? in
            guard record.disposition == .executed,
                  let result = record.result,
                  !result.isError,
                  let data = try? encoder.encode(result.output) else { return nil }
            let iteration = events.last(where: {
                $0.toolCallID == record.id
            })?.iteration
            let content: AgenticConversationStructuredPresentation.Content
            switch record.toolCall.tool.rawValue {
            case "create_graph":
                guard let output = try? decoder.decode(Standard.Tools.CreateGraph.Output.self, from: data) else {
                    return nil
                }
                content = .graph(output.graph, output.references)
            case "create_report":
                guard let output = try? decoder.decode(Standard.Tools.CreateReport.Output.self, from: data) else {
                    return nil
                }
                content = .report(output.document)
            default:
                return nil
            }
            return .structured(.init(
                id: "\(runID):tool:\(record.id)",
                sourceCallID: record.id,
                iteration: iteration,
                content: content
            ))
        }
    }
}
