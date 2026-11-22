import AgenticPresentation
import Foundation
import ICS
import IO
import Reporting
import Writers

/// `:export`, typed without `:`: writes a result the conversation shows
/// (a report, a graph, a proposal) to a file.
///
///     export <format> [n] [path]   n: the nth newest result, 1 by default;
///                                  path: where to write, relative to the
///                                  workspace; by default a dated file in
///                                  the exports directory of settings.frame
public struct AgenticExportCommand: Sendable, Hashable {
    public enum Format: String, Sendable, Hashable, CaseIterable {
        /// The terminal view without colour.
        case txt
        case md
        /// A self-contained page, printable to A4.
        case html
        /// The HTML page through WeasyPrint.
        case pdf
        /// Highlighted times (such as proposed slots) as tentative events.
        case ics
    }

    public let format: Format
    /// 1 is the newest result.
    public let index: Int
    public let path: String?

    package static let definitions: [AgenticCommandDefinition] = [
        .init(
            name: "export",
            syntax: ["export <txt|md|html|pdf|ics> [n] [path]"],
            summary: "Write the newest result (or the nth newest) to a file: text, Markdown, HTML, PDF, or its highlighted times as calendar events.",
            chapter: .results,
            surfaces: [.conversation]
        ),
    ]

    package static let usage = AgenticCommandCatalog(definitions).usage(["export"])

    @_spi(Testing) public init(parsing text: String) throws {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.first == "export", words.count >= 2, words.count <= 4,
              let format = Format(rawValue: words[1].lowercased()) else {
            throw Failure.usage
        }
        words.removeFirst(2)
        var index = 1
        if let first = words.first, let number = Int(first) {
            guard number >= 1 else { throw Failure.usage }
            index = number
            words.removeFirst()
        }
        guard words.count <= 1 else { throw Failure.usage }
        self.format = format
        self.index = index
        self.path = words.first
    }

    /// Writes `document` and returns where it went: to `path`, or else a
    /// dated file in `exports`.
    public func write(
        _ document: ReportDocument,
        workspace: String,
        exports: URL,
        rendering: any AgenticConversationTextRendering,
        now: Date = Date()
    ) async throws -> URL {
        let destination = Self.destination(path, title: document.title, format: format, workspace: workspace, exports: exports, now: now)
        switch format {
        case .txt:
            let rows = rendering.rows(.document(document), columns: 100, includeTitle: true)
            try Self.write(rows.map(Self.plain).joined(separator: "\n") + "\n", to: destination)
        case .md:
            try Self.write(ReportMarkdown.render(document), to: destination)
        case .html:
            try Self.write(ReportHTML.render(document, generated: now), to: destination)
        case .pdf:
            let page = URL.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("html")
            try Self.write(ReportHTML.render(document, generated: now), to: page)
            defer { try? FileSystem.default.remove(page) }
            try await Self.weasyprint(page, to: destination)
        case .ics:
            let events = Self.events(document)
            guard !events.isEmpty else { throw Failure.noTimes }
            try Self.write(Self.calendar(document.title, events: events, now: now), to: destination)
        }
        return destination
    }

    static func destination(
        _ path: String?,
        title: String,
        format: Format,
        workspace: String,
        exports: URL,
        now: Date
    ) -> URL {
        if let path {
            let expanded = (path as NSString).expandingTildeInPath
            let url = expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded)
                : URL(fileURLWithPath: workspace, isDirectory: true).appendingPathComponent(expanded)
            return url.pathExtension.isEmpty ? url.appendingPathExtension(format.rawValue) : url
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return exports
            .appendingPathComponent("\(formatter.string(from: now))-\(slug(title)).\(format.rawValue)")
    }

    static func slug(_ title: String) -> String {
        let words = title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return words.isEmpty ? "result" : words.prefix(8).joined(separator: "-")
    }

    /// Atomic, creating the directories on the way; replaces a file at an
    /// explicitly given path.
    static func write(_ text: String, to url: URL) throws {
        try FileWriter(url).write(text, options: .overwriteWithoutBackup)
    }

    /// Terminal rows carry styling escapes; a text file does not.
    static func plain(_ row: String) -> String {
        row.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }

    // MARK: pdf

    static let weasyprintCandidates = ["/opt/homebrew/bin/weasyprint", "/usr/local/bin/weasyprint"]

    static func weasyprint(_ page: URL, to destination: URL) async throws {
        guard let executable = weasyprintCandidates.first(where: {
            FileSystem.default.isExecutable(URL(fileURLWithPath: $0))
        }) else {
            throw Failure.pdfRendererMissing
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [page.path, destination.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw Failure.pdfRendererFailed(message.split(separator: "\n").last.map(String.init) ?? "exit \(status)")
        }
    }

    // MARK: ics

    struct Event: Equatable {
        let summary: String
        let start: Date
        let end: Date
    }

    /// Every highlighted span: in a proposal, the recommended and
    /// alternative times. Tentative, so importing them decides nothing.
    static func events(_ document: ReportDocument) -> [Event] {
        var events: [Event] = []
        for block in document.blocks {
            guard case .timeline(let timeline) = block else { continue }
            for lane in timeline.lanes {
                for span in lane.spans where span.mark == .highlight {
                    let summary = document.title + (span.label.map { " · \($0)" } ?? "")
                    let event = Event(summary: summary, start: span.start, end: span.end)
                    if !events.contains(event) { events.append(event) }
                }
            }
        }
        return events
    }

    static func calendar(_ title: String, events: [Event], now: Date) -> String {
        let document = ICS.calendar(prodId: "-//Agentic//Export//EN") {
            for event in events {
                ICS.vEvent {
                    ICS.uid()
                    ICS.dtStamp(now)
                    ICS.dtStart(event.start)
                    ICS.dtEnd(event.end)
                    ICS.summary(event.summary)
                    ICS.prop("STATUS", .raw("TENTATIVE"))
                    ICS.prop("TRANSP", .raw("TRANSPARENT"))
                }
            }
        }
        return document.render() + "\r\n"
    }

    public enum Failure: Error, LocalizedError {
        case usage
        case noResult(Int)
        case noTimes
        case pdfRendererMissing
        case pdfRendererFailed(String)

        public var errorDescription: String? {
            switch self {
            case .usage:
                return AgenticExportCommand.usage
            case .noResult(let index):
                return index == 1
                    ? "no result to export: reports, graphs and proposals are exported"
                    : "there is no result \(index) back"
            case .noTimes:
                return "this result has no highlighted times to put in a calendar"
            case .pdfRendererMissing:
                return "PDF needs WeasyPrint (brew install weasyprint); :export html works without it"
            case .pdfRendererFailed(let message):
                return "WeasyPrint failed: \(message)"
            }
        }
    }
}
