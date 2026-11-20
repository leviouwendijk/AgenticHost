import AgenticInterfaces
import AgenticSensitivity
import Foundation

/// Handles (`⟦contact:989e8cb1⟧`) shown on the owner's screen as what they
/// stand for, marked as scrubbed values: `⟨sam@example.com ✉⟩`. Applied to the
/// presentation only; the session's state, records and the model's context
/// keep handles.
package enum AgenticConversationReveal {
    /// `text` with each known handle replaced by its marked display text;
    /// unknown handles stay as they are.
    package static func text(
        _ text: String,
        _ reveal: Privacy.Reveal
    ) -> String {
        reveal.marked(text)
    }

    /// Every string inside a Codable value, through its encoded form: for
    /// structured documents, reports and approval previews.
    static func codable<Value: Codable>(
        _ value: Value,
        _ reveal: Privacy.Reveal
    ) -> Value {
        guard reveal.mode != .handles,
              let data = try? JSONEncoder().encode(value),
              String(decoding: data, as: UTF8.self).contains("⟦"),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let mapped = try? JSONSerialization.data(withJSONObject: strings(object, reveal), options: [.fragmentsAllowed]),
              let decoded = try? JSONDecoder().decode(Value.self, from: mapped)
        else {
            return value
        }
        return decoded
    }

    private static func strings(
        _ object: Any,
        _ reveal: Privacy.Reveal
    ) -> Any {
        switch object {
        case let string as String:
            return text(string, reveal)
        case let array as [Any]:
            return array.map { strings($0, reveal) }
        case let dictionary as [String: Any]:
            return dictionary.mapValues { strings($0, reveal) }
        default:
            return object
        }
    }
}

extension AgenticConversationSnapshot {
    /// This snapshot as the owner's screen shows it.
    @_spi(Testing) public func revealing(
        _ reveal: Privacy.Reveal
    ) -> Self {
        guard reveal.mode != .handles else {
            return self
        }
        func t(_ text: String) -> String { AgenticConversationReveal.text(text, reveal) }
        func o(_ text: String?) -> String? { text.map(t) }

        var shown = self
        shown.activity = o(activity)
        for index in shown.messages.indices {
            shown.messages[index].body = t(shown.messages[index].body)
            shown.messages[index].iterations = shown.messages[index].iterations.map { iteration in
                AgenticConversationIterationPresentation(
                    id: iteration.id,
                    number: iteration.number,
                    assistantBody: o(iteration.assistantBody),
                    events: iteration.events.map(t),
                    callIDs: iteration.callIDs
                )
            }
        }
        shown.hostConsole = hostConsole.revealing(reveal)
        return shown
    }
}

package extension AgenticHostConsoleSnapshot {
    func revealing(
        _ reveal: Privacy.Reveal
    ) -> Self {
        func t(_ text: String) -> String { AgenticConversationReveal.text(text, reveal) }
        func o(_ text: String?) -> String? { text.map(t) }
        func c<Value: Codable>(_ value: Value) -> Value { AgenticConversationReveal.codable(value, reveal) }

        var shown = self
        for run in shown.runs.indices {
            shown.runs[run].summary = o(shown.runs[run].summary)
            shown.runs[run].notes = shown.runs[run].notes.map(t)
            for step in shown.runs[run].steps.indices {
                shown.runs[run].steps[step].title = t(shown.runs[run].steps[step].title)
                shown.runs[run].steps[step].detail = o(shown.runs[run].steps[step].detail)
                for field in shown.runs[run].steps[step].fields.indices {
                    shown.runs[run].steps[step].fields[field].value = t(shown.runs[run].steps[step].fields[field].value)
                }
            }
        }
        for index in shown.interruptions.indices {
            shown.interruptions[index].title = t(shown.interruptions[index].title)
            shown.interruptions[index].summary = t(shown.interruptions[index].summary)
        }
        for index in shown.documents.indices {
            shown.documents[index].title = t(shown.documents[index].title)
            shown.documents[index].body = t(shown.documents[index].body)
            shown.documents[index].previewPrelude = o(shown.documents[index].previewPrelude)
            shown.documents[index].structuredBody = shown.documents[index].structuredBody.map(c)
            shown.documents[index].reportBody = shown.documents[index].reportBody.map(c)
            shown.documents[index].previewBody = shown.documents[index].previewBody.map(c)
            shown.documents[index].traceRoots = shown.documents[index].traceRoots.map(c)
        }
        for index in shown.statuses.indices {
            shown.statuses[index].summary = t(shown.statuses[index].summary)
            shown.statuses[index].body = t(shown.statuses[index].body)
        }
        return shown
    }
}
