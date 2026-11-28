import Agentic
import Terminal
import AgenticHost

public struct TerminalToolHostReceiptRenderer:
    Sendable
{
    public var stream: TerminalStream
    public var theme: TerminalTheme

    public init(
        stream: TerminalStream = .standardError,
        theme: TerminalTheme = .agentic
    ) {
        self.stream = stream
        self.theme = theme
    }

    public func render(
        _ envelope: AgenticToolHostEnvelope,
        copiedToClipboard: Bool = false
    ) -> String {
        if let invocation = envelope.invocation {
            return render(
                invocation,
                copiedToClipboard: copiedToClipboard
            )
        }

        if let plan = envelope.planResult {
            return render(
                plan,
                copiedToClipboard: copiedToClipboard
            )
        }

        return block(
            title: "Tool host result",
            fields: clipboardFields(
                copiedToClipboard
            )
        )
    }
}

private extension TerminalToolHostReceiptRenderer {
    func render(
        _ invocation: ToolInvocation.Result,
        copiedToClipboard: Bool
    ) -> String {
        let projection =
            invocation
                .execution?
                .result
                .projection

        var fields: [TerminalField] = [
            .init(
                "execution",
                executionStatus(
                    invocation
                )
            ),
            .init(
                "decision",
                invocation.decision.rawValue
            ),
            .init(
                "risk",
                invocation.review.preflight.risk.rawValue
            ),
            .init(
                "intent",
                invocation.review.preflight.summary
            ),
        ]

        if let projection {
            fields.insert(
                .init(
                    "operation",
                    projection.status
                ),
                at: 1
            )
        }

        if let summary = projection?.summary,
           !summary.isEmpty
        {
            fields.append(
                .init(
                    "summary",
                    summary
                )
            )
        }

        fields.append(
            contentsOf:
                clipboardFields(
                    copiedToClipboard
                )
        )

        return block(
            title: invocation.review.invocation.tool.rawValue,
            fields: fields,
            body: projectionBody(
                projection
            )
        )
    }

    func render(
        _ plan: ToolPlan.Result,
        copiedToClipboard: Bool
    ) -> String {
        var fields: [TerminalField] = [
            .init(
                "execution",
                plan.outcome.rawValue
            ),
            .init(
                "executed",
                "\(plan.executedCount)"
            ),
            .init(
                "skipped",
                "\(plan.skippedCount)"
            ),
        ]

        fields.append(
            contentsOf:
                clipboardFields(
                    copiedToClipboard
                )
        )

        return block(
            title: "Tool plan",
            fields: fields,
            body:
                plan.records
                    .map(
                        recordBody
                    )
                    .joined(
                        separator: "\n\n"
                    )
        )
    }

    func recordBody(
        _ record: ToolPlan.Record
    ) -> String {
        let invocation = record.invocation
        let projection =
            invocation?
                .execution?
                .result
                .projection

        var details: [String] = [
            record.outcome.rawValue
        ]

        if let invocation {
            details.append(
                invocation.decision.rawValue
            )

            details.append(
                invocation.review
                    .preflight
                    .risk
                    .rawValue
            )
        }

        var lines = [
            "\(record.call.name)  \(details.joined(separator: " · "))"
        ]

        if let intent = invocation?.review.preflight.summary,
           !intent.isEmpty
        {
            lines.append(
                contentsOf:
                    labeledValueLines(
                        label: "intent",
                        value: intent,
                        prefix: "  "
                    )
            )
        }

        if let projection {
            lines.append(
                "  operation  \(projection.status)"
            )
        }

        if let summary = projection?.summary,
           !summary.isEmpty
        {
            lines.append(
                "  \(summary)"
            )
        }

        if let projection,
           !projection.facts.isEmpty
        {
            lines.append(
                contentsOf:
                    projection.facts.flatMap { fact in
                        projectionFactLines(
                            fact,
                            prefix: "  "
                        )
                    }
            )
        }

        if let error = record.errorDescription,
           !error.isEmpty
        {
            lines.append(
                "  error  \(error)"
            )
        }

        if let reason = record.skipReason,
           !reason.isEmpty
        {
            lines.append(
                "  skipped  \(reason)"
            )
        }

        return lines.joined(
            separator: "\n"
        )
    }

    func executionStatus(
        _ invocation: ToolInvocation.Result
    ) -> String {
        if invocation.decision == .denied {
            return "denied"
        }

        if invocation.execution?.result.isError == true {
            return "failed"
        }

        if invocation.executed {
            return "succeeded"
        }

        return invocation.decision.rawValue
    }

    func projectionBody(
        _ projection: ToolExecution.Projection?
    ) -> String? {
        guard let projection,
              !projection.facts.isEmpty
        else {
            return nil
        }

        return projection.facts
            .flatMap { fact in
                projectionFactLines(
                    fact
                )
            }
            .joined(
                separator: "\n"
            )
    }

    func projectionFactLines(
        _ fact: ToolExecution.Projection.Fact,
        prefix: String = ""
    ) -> [String] {
        labeledValueLines(
            label: fact.label,
            value: fact.value,
            prefix: prefix
        )
    }

    func labeledValueLines(
        label: String,
        value: String,
        prefix: String = ""
    ) -> [String] {
        var valueLines =
            value
                .split(
                    separator: "\n",
                    omittingEmptySubsequences: false
                )
                .map { line in
                    String(line)
                }

        while valueLines.first?.isEmpty == true {
            valueLines.removeFirst()
        }

        while valueLines.last?.isEmpty == true {
            valueLines.removeLast()
        }

        guard !valueLines.isEmpty else {
            return [
                "\(prefix)\(label)"
            ]
        }

        guard valueLines.count > 1 else {
            return [
                "\(prefix)\(label)  \(valueLines[0])"
            ]
        }

        return [
            "\(prefix)\(label)"
        ] + valueLines.map { line in
            "\(prefix)  \(line)"
        }
    }

    func clipboardFields(
        _ copied: Bool
    ) -> [TerminalField] {
        guard copied else {
            return []
        }

        return [
            .init(
                "clipboard",
                "result copied"
            ),
        ]
    }

    func block(
        title: String,
        fields: [TerminalField],
        body: String? = nil
    ) -> String {
        TerminalBlock(
            title: title,
            fields: fields,
            body: body,
            theme: theme,
            layout: .agentic
        ).render(
            stream: stream
        )
    }
}
