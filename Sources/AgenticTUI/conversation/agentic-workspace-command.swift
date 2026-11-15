import AgenticHost
import Foundation
import Workspace

/// `:path` and `:cd`, typed without `:`.
///
///     path                          list roots, restrictions, directory
///     path add <dir> [--read]       a root for this session; --read: list, read, scan
///     path rm <root|path|deny>      remove an added root or a restriction
///     path deny <pattern> [--root <id>]
///     cd [dir]                      working directory; none: the configured root
package enum AgenticWorkspaceCommand: Sendable, Hashable {
    case list
    case change(AgentHost.WorkspaceChange)

    package static let names: Set<String> = ["path", "cd"]

    package static let usage = "usage: :path [add <dir> [--read] | rm <root|path|deny> | deny <pattern> [--root <id>]] · :cd [dir]"

    package init(
        parsing text: String
    ) throws {
        var words = try Self.words(text)
        guard !words.isEmpty else { throw Failure.usage }
        let name = words.removeFirst()

        switch name {
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
                let paths = words.filter { $0 != "--read" }
                guard paths.count == 1, !paths[0].hasPrefix("--") else { throw Failure.usage }
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
