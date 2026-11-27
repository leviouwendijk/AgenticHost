import Agentic
import AgenticRuntime
import ParsersStructuredContent
import Primitives
import Terminal
import TerminalStructuredContent

/// Prints a session replay: messages as text (assistant text as Markdown),
/// calls with their input, results shortened unless `full`, delegated runs
/// indented under the run that started them.
struct AgenticLogReplayRenderer {
    let columns: Int
    let full: Bool
    /// Result lines shown before shortening; errors are always shown whole.
    var resultLines = 6

    private let markdown = TerminalStructuredContent.Renderer(capabilities: .currentTerminal)
    private let accent = TerminalStyle(foreground: .hex("#d7a65f"), background: nil)
    private let failure = TerminalStyle(foreground: .hex("#e06c75"), background: nil)

    init(columns: Int, full: Bool) {
        self.columns = max(40, columns)
        self.full = full
    }

    func render(_ replay: Run.Log.Replay) -> String {
        replay.items.flatMap(rows).joined(separator: "\n")
    }

    private func rows(_ item: Run.Log.Replay.Item) -> [String] {
        let gutter = TerminalStyle.dim.apply(String(repeating: "│ ", count: item.depth))
        let width = max(20, columns - 2 * item.depth)
        return body(item, width: width).map { gutter + $0 }
    }

    private func body(_ item: Run.Log.Replay.Item, width: Int) -> [String] {
        switch item.event {
        case .message(let role, let text):
            return [""] + message(role: role, text: text, seq: item.seq, width: width)

        case .call(let call, let input, let via):
            let arguments = json(input, pretty: false)
            let head = "→ " + call.name + (via.map { " via " + $0 } ?? "") + " "
            let line = TerminalStyle.bold.apply(head) + arguments
            return full
                ? TerminalTextWrap.lines(head + arguments, width: width)
                : [TerminalDisplay.clipped(line, columns: width)]

        case .response(let call, let output, let isError):
            let head = "← " + call.name + (isError ? " · error" : "")
            let lines = text(of: output)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            let shown = full || isError ? lines : Array(lines.prefix(resultLines))
            var rows = [(isError ? failure : TerminalStyle.dim).apply(head)]
            rows += shown.flatMap { line -> [String] in
                full || isError
                    ? TerminalTextWrap.lines(line, width: width - 2).map { "  " + $0 }
                    : ["  " + TerminalDisplay.clipped(line, columns: width - 2)]
            }.map { isError ? $0 : TerminalStyle.dim.apply($0) }
            if shown.count < lines.count {
                rows.append(TerminalStyle.dim.apply(
                    "  … \(lines.count - shown.count) more lines (--full, or --step \(item.seq))"
                ))
            }
            return rows

        case .branch:
            let name = item.run.map { $0.split(separator: ":").last.map(String.init) ?? $0 } ?? "-"
            return ["", accent.apply("↳ delegated run " + name)]

        case .cost(let summary):
            return [TerminalStyle.dim.apply("  " + cost(summary))]

        case .notice(let kind, let summary):
            return [accent.apply("! " + kind.rawValue + " · " + summary)]
        }
    }

    private func message(
        role: MessageRole,
        text: String,
        seq: Int,
        width: Int
    ) -> [String] {
        switch role {
        case .assistant:
            return [TerminalStyle.bold.apply("assistant")]
                + markdown.rows(MarkdownStructuredContentParser.parse(text), columns: width)
        case .system where !full:
            return [TerminalStyle.dim.apply(
                "system · \(text.count) characters (--full, or --step \(seq))"
            )]
        case .user:
            return [TerminalStyle.bold.apply("user")] + TerminalTextWrap.lines(text, width: width)
        case .system, .tool:
            return [TerminalStyle.dim.apply(role.rawValue)]
                + TerminalTextWrap.lines(text, width: width).map(TerminalStyle.dim.apply)
        }
    }

    /// Strings as they are; anything else as indented JSON.
    private func text(of output: JSONValue) -> String {
        if case .string(let value) = output { return value }
        return json(output, pretty: true)
    }

    /// JSON as a reader expects it: paths without escaped slashes.
    private func json(_ value: JSONValue, pretty: Bool) -> String {
        ((try? value.toJSONString(prettyPrinted: pretty)) ?? "")
            .replacingOccurrences(of: "\\/", with: "/")
    }

    /// "actual cost status=available amount=… (…) model=…" without the
    /// parts every line repeats.
    private func cost(_ summary: String) -> String {
        var value = Substring(summary)
        if let range = value.range(of: "status=available ") {
            value = value[range.upperBound...]
        }
        if let range = value.range(of: " model=") {
            value = value[..<range.lowerBound]
        }
        return String(value)
    }
}
