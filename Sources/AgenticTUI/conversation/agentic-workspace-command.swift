import AgenticHost
import AgenticPresentation
import Foundation
import IO
import Workspace

/// `:path` and `:cd`, typed without `:`.
///
///     path                          list roots, restrictions, directory
///     path add <dir|file> [--read|--ask]  a root for this session, or one file alone; --read: read-only; --ask: ask per call
///     path rm <root|path|deny>      remove an added root or a restriction
///     path deny <pattern> [--root <id>]
///     cd [dir]                      working directory; none: the configured root
///     paths                         the PathScope bindings in settings.frame
///     paths add <name> [--read]     one of them, as `path add` would add it
@_spi(Testing) public enum AgenticWorkspaceCommand: Sendable, Hashable {
    case list
    case change(AgentHost.WorkspaceChange)
    case listScopes
    case addScope(String, readOnly: Bool)

    package static let definitions: [AgenticCommandDefinition] = [
        .init(
            name: "path",
            syntax: [
                "path",
                "path add <dir|file> [--read|--ask]",
                "path rm <root|path|deny>",
                "path deny <pattern> [--root <id>]",
            ],
            summary: "List the workspace, add a root or one file, remove one, or deny a pattern.",
            chapter: .workspace,
            isTraced: true,
            contextEffect: .note
        ),
        .init(
            name: "paths",
            syntax: ["paths", "paths add <name> [--read]"],
            summary: "The PathScope bindings in settings.frame; add one as a root.",
            chapter: .workspace,
            isTraced: true,
            contextEffect: .note
        ),
        .init(
            name: "cd",
            syntax: ["cd [dir]"],
            summary: "Where relative paths resolve; none: the configured root.",
            chapter: .workspace,
            isTraced: true,
            contextEffect: .note
        ),
    ]

    package static let names = Set(definitions.map(\.name))

    package static let usage = AgenticCommandCatalog(definitions).usage(["path", "paths", "cd"])

    @_spi(Testing) public init(
        parsing text: String
    ) throws {
        var words = try Self.words(text)
        guard !words.isEmpty else { throw Failure.usage }
        let name = words.removeFirst()

        switch name {
        case "paths":
            guard let action = words.first else {
                self = .listScopes
                return
            }
            let rest = words.dropFirst().filter { $0 != "--read" }
            guard action == "add", rest.count == 1 else { throw Failure.usage }
            self = .addScope(rest[0], readOnly: words.contains("--read"))

        case "cd":
            guard words.count <= 1 else { throw Failure.usage }
            self = .change(.changeDirectory(words.first))

        case "path":
            guard !words.isEmpty else {
                self = .list
                return
            }
            let action = words.removeFirst()
            switch action {
            case "add":
                let read = words.contains("--read")
                let ask = words.contains("--ask")
                let paths = words.filter { $0 != "--read" && $0 != "--ask" }
                guard paths.count == 1, !paths[0].hasPrefix("--"), !(read && ask) else { throw Failure.usage }
                if ask {
                    self = .change(.ask(path: paths[0]))
                    return
                }
                self = .change(.add(
                    path: paths[0],
                    capabilities: read
                        ? [.list, .read, .scan]
                        : Set(WorkspaceCapability.allCases)
                ))

            case "rm", "remove":
                guard words.count == 1 else { throw Failure.usage }
                self = .change(.remove(words[0]))

            case "deny":
                var root: String?
                if let index = words.firstIndex(of: "--root") {
                    guard words.indices.contains(index + 1) else { throw Failure.usage }
                    root = words[index + 1]
                    words.removeSubrange(index...(index + 1))
                }
                guard words.count == 1 else { throw Failure.usage }
                self = .change(.deny(pattern: words[0], root: root))

            default:
                throw Failure.usage
            }

        default:
            throw Failure.usage
        }
    }

    /// Whitespace-separated, with '…' or "…" keeping spaces.
    static func words(
        _ text: String
    ) throws -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var started = false

        for character in text {
            if let open = quote {
                if character == open {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "'" || character == "\"" {
                quote = character
                started = true
            } else if character.isWhitespace {
                if started {
                    words.append(current)
                    current = ""
                    started = false
                }
            } else {
                current.append(character)
                started = true
            }
        }
        guard quote == nil else { throw Failure.unterminatedQuote }
        if started { words.append(current) }
        return words
    }

    package enum Failure: Error, LocalizedError {
        case usage
        case unterminatedQuote

        package var errorDescription: String? {
            switch self {
            case .usage: return AgenticWorkspaceCommand.usage
            case .unterminatedQuote: return "unterminated quote"
            }
        }
    }
}

/// Where a conversation's relative paths resolve, readable synchronously
/// by the command line's completion.
@_spi(Testing) public final class AgenticWorkingDirectory: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String

    public init(_ path: String) {
        value = path
    }

    package var path: String {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

extension AgenticWorkspaceCommand {
    /// Completes the path argument of `path add` (directories and files)
    /// and `cd` (directories), relative to `directory`.
    public static func completer(
        directory: AgenticWorkingDirectory,
        scopes: @escaping @Sendable () -> [String] = { [] },
        limit: Int = 200
    ) -> AgenticCommandCompleter {
        { text in
            if text.hasPrefix("paths add ") {
                let partial = text.hasSuffix(" ")
                    ? ""
                    : String(text.split(separator: " ").last ?? "")
                let names = scopes().filter { $0.hasPrefix(partial) }.sorted()
                guard !names.isEmpty else { return nil }
                return .init(
                    replacing: partial.count,
                    candidates: names.map { .init(text: $0, title: $0) }
                )
            }
            let directoriesOnly: Bool
            if text.hasPrefix("path add ") {
                directoriesOnly = false
            } else if text.hasPrefix("cd ") {
                directoriesOnly = true
            } else {
                return nil
            }
            // The word being typed; flags and quoted paths are left alone.
            let partial = text.hasSuffix(" ")
                ? ""
                : String(text.split(separator: " ", omittingEmptySubsequences: false).last ?? "")
            guard !partial.hasPrefix("-"), !partial.contains("'"), !partial.contains("\"") else {
                return nil
            }

            let typedParent = partial.lastIndex(of: "/").map { String(partial[...$0]) } ?? ""
            let prefix = String(partial.dropFirst(typedParent.count))
            let expanded = typedParent.hasPrefix("~")
                ? NSHomeDirectory() + typedParent.dropFirst()
                : typedParent
            let parent = expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded, isDirectory: true)
                : URL(fileURLWithPath: directory.path, isDirectory: true)
                    .appendingPathComponent(expanded, isDirectory: true)

            guard let entries = try? DirectoryInspector(parent).entries() else {
                return nil
            }
            let candidates = entries
                .compactMap { entry -> AgenticCommandCompletion.Candidate? in
                    let name = entry.url.lastPathComponent
                    guard name.hasPrefix(prefix),
                          prefix.hasPrefix(".") || !name.hasPrefix(".")
                    else { return nil }
                    let isDirectory = entry.kind == .directory
                    guard isDirectory || !directoriesOnly else { return nil }
                    let shown = isDirectory ? name + "/" : name
                    return .init(text: typedParent + shown, title: shown)
                }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                .prefix(limit)
            guard !candidates.isEmpty else { return nil }
            return .init(replacing: partial.count, candidates: Array(candidates))
        }
    }
}
