import Agentic
import Foundation
import Primitives

actor ProjectDiscoveryTrace {
    private var recordedToolCallIDs: Set<String> = []
    private var recordedToolResultIDs: Set<String> = []
    private var rejectedToolCallIDs: Set<String> = []
    private let maxOutputCharacters: Int

    init(
        maxOutputCharacters: Int = 12_000
    ) {
        self.maxOutputCharacters = maxOutputCharacters
    }

    func recordToolCall(
        id: String,
        name: String,
        input: JSONValue
    ) async {
        guard recordedToolCallIDs.insert(
            id
        ).inserted else {
            return
        }

        write(
            """
            project discovery trace
            tool call

            tool: \(name)
            id: \(id)
            input:
            \(render(input))

            """
        )
    }

    func recordToolResults(
        _ results: [AgentToolResult]
    ) async {
        for result in results {
            await recordToolResult(
                result
            )
        }
    }

    func recordText(
        title: String,
        text: String
    ) async {
        write(
            """
            project discovery trace
            \(title)

            \(truncated(text))

            """
        )
    }

    func didRecordToolResult(
        id: String
    ) -> Bool {
        recordedToolResultIDs.contains(
            id
        )
    }

    func didRejectToolCall(
        id: String
    ) -> Bool {
        rejectedToolCallIDs.contains(
            id
        )
    }
}

private extension ProjectDiscoveryTrace {
    func recordToolResult(
        _ result: AgentToolResult
    ) async {
        guard recordedToolResultIDs.insert(
            result.toolCallID
        ).inserted else {
            return
        }

        if result.isError {
            rejectedToolCallIDs.insert(
                result.toolCallID
            )
        }

        let status = result.isError ? "error" : "ok"

        write(
            """
            project discovery trace
            tool result

            tool: \(result.name ?? "<unknown>")
            tool call id: \(result.toolCallID)
            status: \(status)
            output:
            \(render(result.output))

            """
        )
    }

    func render(
        _ value: JSONValue
    ) -> String {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [
                .prettyPrinted,
                .sortedKeys,
            ]

            let data = try encoder.encode(
                value
            )

            return truncated(
                String(
                    decoding: data,
                    as: UTF8.self
                )
            )
        } catch {
            return truncated(
                String(
                    describing: value
                )
            )
        }
    }

    func truncated(
        _ text: String
    ) -> String {
        guard text.count > maxOutputCharacters else {
            return text
        }

        let prefix = text.prefix(
            maxOutputCharacters
        )

        return """
        \(prefix)

        ... truncated after \(maxOutputCharacters) characters ...
        """
    }

    func write(
        _ text: String
    ) {
        fputs(
            text,
            stderr
        )
    }
}
