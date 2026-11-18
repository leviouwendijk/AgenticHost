import Agentic
import AgenticCommandLine
import AgenticTUI
import AgenticInterfaces
import AgenticRuntime
import AgenticStandard
import Foundation
import Primitives
import Reporting

private enum SmokeFailure: Error {
    case check(String)
}

@main
struct ConversationHostStructuresSmoke {
    static func main() async throws {
        let graphInput = Standard.Tools.CreateGraph.Input(
            nodes: [
                .init(id: "a", value: .string("A")),
                .init(id: "b", value: .string("B")),
            ],
            edges: [.init(id: "ab", source: "a", destination: "b", value: .null)],
            references: [.init(id: "main", target: "b")]
        )
        let output = try Standard.Tools.CreateGraph.evaluate(graphInput)
        let encoded = try JSONEncoder().encode(output)
        let value = try JSONDecoder().decode(JSONValue.self, from: encoded)
        let call = FunctionCall(id: "call-1", name: "create_graph", input: .null)
        let record = AgentToolUseRecord(
            functionCall: call,
            disposition: .executed,
            result: .init(call: call.reference, output: value),
            presentation: Standard.Tools.CreateGraph().present(output, input: graphInput)
        )
        let events: [Run.Event.State] = [
            .init(kind: .assistant_response, iteration: 2,
                  messageID: "response-2", summary: "Model responded"),
            .init(kind: .tool_result, iteration: 2,
                  callID: call.id, toolName: "create_graph", summary: "Completed"),
        ]
        let messages: [Message] = [
            .init(id: "response-2", role: .assistant, content: .init(text: "Here is a graph."))
        ]
        let history = AgenticConversationStructuredProjection.iterations(
            runID: "run", messages: messages, events: events
        )
        try check(history.count == 1 && history[0].number == 2, "iteration mapping")
        try check(history[0].assistantBody == "Here is a graph.", "recorded assistant text")
        try check(history[0].callIDs == ["call-1"], "tool call provenance")
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
        let reportInput = Standard.Tools.CreateReport.Input(
            title: "Projection report", datasets: [],
            blocks: [.init(kind: .narrative, text: "Illustrative")]
        )
        let reportOutput = try Standard.Tools.CreateReport.evaluate(reportInput)
        let reportValue = try JSONDecoder().decode(
            JSONValue.self, from: JSONEncoder().encode(reportOutput)
        )
        let reportCall = FunctionCall(id: "call-2", name: "create_report", input: .null)
        let reportRecord = AgentToolUseRecord(
            functionCall: reportCall, disposition: .executed,
            result: .init(call: reportCall.reference, output: reportValue),
            presentation: Standard.Tools.CreateReport().present(reportOutput, input: reportInput)
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
        let callTreeCall = FunctionCall(
            id: "call-3", name: "create_call_tree", input: .null
        )
        let callTreeRecord = AgentToolUseRecord(
            functionCall: callTreeCall, disposition: .executed,
            result: .init(call: callTreeCall.reference, output: callTreeValue)
        )
        let callTreeEvents = events + [Run.Event.State(
            kind: .tool_result, iteration: 3, callID: callTreeCall.id,
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
            functionCall: callTreeCall, disposition: .executed,
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
        let unpresented = AgentToolUseRecord(
            functionCall: call, disposition: .executed,
            result: .init(call: call.reference, output: value)
        )
        try check(AgenticConversationStructuredProjection.attachments(
            runID: "run", toolUses: [unpresented], events: events
        ).isEmpty, "the tool's presentation decides, not its name")
        let domainCall = FunctionCall(id: "call-4", name: "schedule_propose", input: .null)
        let domainRecord = AgentToolUseRecord(
            functionCall: domainCall, disposition: .executed,
            result: .init(call: domainCall.reference, output: .null),
            presentation: .init(reportOutput.document)
        )
        try check(AgenticConversationStructuredProjection.attachments(
            runID: "run", toolUses: [domainRecord], events: events
        ).count == 1, "any tool with a presentation gets an attachment")
        let intermediate = AgentToolUseRecord(
            functionCall: domainCall, disposition: .executed,
            result: .init(call: domainCall.reference, output: .null),
            presentation: .init(reportOutput.document, placement: .inspector)
        )
        try check(AgenticConversationStructuredProjection.attachments(
            runID: "run", toolUses: [intermediate], events: events
        ).isEmpty, "inspector presentations stay out of the transcript")
        let denied = AgentToolUseRecord(functionCall: call, disposition: .skipped_by_user)
        try check(AgenticConversationStructuredProjection.attachments(
            runID: "run", toolUses: [denied], events: events
        ).isEmpty, "no view for skipped tools")
        try await exports()
        try settingsNotices()
        print("Conversation host structured projection smoke: passed")
    }

    /// `:export` writes the newest result in every format; calendars take
    /// its highlighted times as tentative events.
    static func exports() async throws {
        let parsed = try AgenticExportCommand(parsing: "export pdf 2 out/plan")
        try check(parsed.format == .pdf && parsed.index == 2 && parsed.path == "out/plan", "export parsing")
        try check((try? AgenticExportCommand(parsing: "export docx")) == nil, "unknown format refused")
        try check((try? AgenticExportCommand(parsing: "export md 0")) == nil, "results count from 1")

        let start = Date(timeIntervalSince1970: 1_763_449_200)
        let document = try ReportDocument(
            title: "Intake proposal",
            datasets: [],
            blocks: [
                .facts(.init(facts: [.init("Recommended", "Tue 10:00")])),
                .callout(.init(tone: .info, content: .list(style: .unordered, items: [.paragraph([.text("No location")])]))),
                .timeline(.init(start: start, end: start + 8 * 3600, timeZone: "Europe/Amsterdam", lanes: [
                    .init(label: "Levi", spans: [.init(start: start, end: start + 3600, mark: .occupied, label: "Standup")]),
                    .init(label: "Options", spans: [
                        .init(start: start + 7200, end: start + 10800, mark: .highlight, label: "A · recommended"),
                        .init(start: start + 14400, end: start + 18000, mark: .highlight, label: "B"),
                    ]),
                ])),
            ]
        )
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let now = Date(timeIntervalSince1970: 1_763_400_000)
        let exports = AgenticSettings.Exports().resolvedDirectory(workspace: workspace.path)
        try check(exports.path == workspace.appendingPathComponent(".agentic/artifacts/exports").path, "exports default under .agentic/artifacts")
        var formats: [AgenticExportCommand.Format] = [.txt, .md, .html, .ics]
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/weasyprint") { formats.append(.pdf) }
        for format in formats {
            let url = try await AgenticExportCommand(parsing: "export \(format.rawValue)").write(document, workspace: workspace.path, exports: exports, now: now)
            try check(url.deletingLastPathComponent().path == exports.path && url.lastPathComponent.hasSuffix("-intake-proposal.\(format.rawValue)"), "default \(format) destination")
            let data = try Data(contentsOf: url)
            try check(!data.isEmpty, "\(format) written")
            let text = String(decoding: data, as: UTF8.self)
            switch format {
            case .txt: try check(text.contains("Recommended") && !text.contains("\u{1B}["), "plain text without escapes")
            case .md: try check(text.hasPrefix("# Intake proposal"), "markdown")
            case .html: try check(text.contains("<title>Intake proposal</title>"), "html")
            case .pdf: try check(text.hasPrefix("%PDF"), "pdf")
            case .ics:
                try check(text.components(separatedBy: "BEGIN:VEVENT").count == 3, "one event per highlighted time")
                try check(text.contains("SUMMARY:Intake proposal · A · recommended") && text.contains("STATUS:TENTATIVE"), "tentative events")
            }
        }
        let explicit = try await AgenticExportCommand(parsing: "export md notes/plan").write(document, workspace: workspace.path, exports: exports, now: now)
        try check(explicit.path == workspace.appendingPathComponent("notes/plan.md").path, "relative path in the workspace, extension added")
        let bare = try ReportDocument(title: "No times", datasets: [], blocks: [.facts(.init(facts: [.init("a", "b")]))])
        do {
            _ = try await AgenticExportCommand(parsing: "export ics").write(bare, workspace: workspace.path, exports: exports)
            throw SmokeFailure.check("ics without times refused")
        } catch AgenticExportCommand.Failure.noTimes {}
    }

    static func settingsNotices() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = AgentHome(root: root, kind: .ephemeral)
        try check(AgenticConversationSession.settingsNotices(home).isEmpty, "no file, no notice")
        try home.prepareSettingsFile()
        try check(AgenticConversationSession.settingsNotices(home).isEmpty, "the template declares the current schema")
        try "import Agentic;\nlet settings: AgenticSettings = .{};\n".write(to: home.layout.settingsfile, atomically: true, encoding: .utf8)
        let notices = AgenticConversationSession.settingsNotices(home)
        try check(notices.count == 1 && notices[0].contains(".schema = .{"), "an undeclared schema names the line to add")
    }

    static func check(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        guard condition() else { throw SmokeFailure.check(description) }
    }
}
