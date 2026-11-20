import Agentic
import AgenticInterfaces
import AgenticRuntime
import AgenticStandard
import Foundation

/// Projects existing runtime evidence into message-facing history and views.
/// Checkpoint events and tool results are authoritative; no new storage.
public enum AgenticConversationStructuredProjection {
    public static func iterations(
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
                if let callID = event.callID, seen.insert(callID).inserted {
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
                callIDs: callIDs
            )
        }
    }

    public static func attachments(
        runID: String,
        toolUses: [AgentToolUseRecord],
        events: [Run.Event.State]
    ) -> [AgenticConversationAttachmentPresentation] {
        toolUses.compactMap { record -> AgenticConversationAttachmentPresentation? in
            guard record.disposition == .executed,
                  let result = record.result,
                  !result.isError,
                  let content = content(record, result: result) else { return nil }
            let iteration = events.last(where: {
                $0.callID == record.id
            })?.iteration
            return .structured(.init(
                id: "\(runID):tool:\(record.id)",
                sourceCallID: record.id,
                iteration: iteration,
                content: content
            ))
        }
    }

    /// The tool's own presentation, recorded at execution, when the tool
    /// placed it with the answer. Call trees keep their specialised view
    /// until it is expressible as a document.
    private static func content(
        _ record: AgentToolUseRecord,
        result: FunctionCall.Response
    ) -> AgenticConversationStructuredPresentation.Content? {
        if let presentation = record.presentation {
            return presentation.placement == .attachment ? .document(presentation.document) : nil
        }
        guard ToolIdentifier(record.functionCall.name) == Standard.Tools.CreateCallTree.identifier,
              let data = try? JSONEncoder().encode(result.output),
              let output = try? JSONDecoder().decode(Standard.Tools.CreateCallTree.Output.self, from: data),
              output.provenance == .proposed else {
            return nil
        }
        return .call_tree(output)
    }
}
