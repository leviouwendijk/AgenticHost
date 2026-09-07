import Foundation

enum AgenticInterfaceTestInvocation: Sendable, Hashable {
    case menu
    case list
    case run(String, [String])

    static func parse(
        _ arguments: [String]
    ) throws -> Self {
        var values = Array(
            arguments.dropFirst()
        )

        guard !values.isEmpty else {
            return .menu
        }

        let first = values.removeFirst()

        switch first {
        case "list",
             "--list",
             "-l":
            return .list

        case "help",
             "--help",
             "-h":
            return .list

        default:
            return .run(
                first,
                values
            )
        }
    }
}

enum AgenticInterfaceTestPrinter {
    static func printAvailable(
        _ tests: [AgenticInterfaceTestCase]
    ) {
        let width = tests.map(\.id.count).max() ?? 0
        var lines: [String] = [
            "Agentic interface test cases",
            "",
            "usage:",
            "    swift run aginttest",
            "    swift run aginttest <test-case> [arguments]",
            "",
            "available:"
        ]

        for test in tests.sorted(by: { $0.id < $1.id }) {
            let padding = String(
                repeating: " ",
                count: max(0, width - test.id.count)
            )

            lines.append(
                "    \(test.id)\(padding)    \(test.summary)"
            )
        }

        lines.append("")
        lines.append("examples:")
        lines.append("    swift run aginttest")
        lines.append("    swift run aginttest apple-write agentic-interface-hello.txt")
        lines.append("    swift run aginttest aws-call")
        lines.append("    swift run aginttest aws-refactor")
        lines.append("    swift run aginttest aws-mutate-refactor")

        print(
            lines.joined(
                separator: "\n"
            )
        )
    }
}
