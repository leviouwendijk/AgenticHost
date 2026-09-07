import Agentic
import AgenticApple
import Foundation

struct PhilosophicalMiddleFragment: Sendable, Codable, Hashable {
    var title: String
    var quote: String
    var reflection: String
}

struct AppleStructuredQuoteGenerator: Sendable {
    func generateMiddleFragment() async throws -> PhilosophicalMiddleFragment {
        let adapter = AppleFoundationModelAdapter()

        let response = try await adapter.respond(
            request: AgentRequest(
                messages: [
                    .init(
                        role: .system,
                        text: """
                        Return only one compact JSON object.

                        Schema:
                        {
                            "title": "string, 2 to 8 words",
                            "quote": "string, one original philosophical sentence, no attribution",
                            "reflection": "string, one plain sentence explaining the quote"
                        }

                        No markdown.
                        No code fences.
                        No extra keys.
                        """
                    ),
                    .init(
                        role: .user,
                        text: """
                        Generate a fresh philosophical middle fragment about attention, agency, and the ordinary world.

                        Make it feel spontaneous, but keep the JSON shape exact.
                        """
                    ),
                ]
            )
        )

        let text = response.message.content.text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        let fragment = try decodeFragment(
            from: text
        )

        return try normalize(
            fragment
        )
    }
}

private extension AppleStructuredQuoteGenerator {
    func decodeFragment(
        from text: String
    ) throws -> PhilosophicalMiddleFragment {
        let data = Data(
            try extractJSONObject(
                from: text
            ).utf8
        )

        return try JSONDecoder().decode(
            PhilosophicalMiddleFragment.self,
            from: data
        )
    }

    func extractJSONObject(
        from text: String
    ) throws -> String {
        let trimmed = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        if trimmed.hasPrefix("{"),
           trimmed.hasSuffix("}") {
            return trimmed
        }

        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start <= end
        else {
            throw AppleGeneratedFragmentError.missingJSONObject(
                trimmed
            )
        }

        return String(
            trimmed[start...end]
        )
    }

    func normalize(
        _ fragment: PhilosophicalMiddleFragment
    ) throws -> PhilosophicalMiddleFragment {
        let title = try normalizedRequired(
            fragment.title,
            field: "title",
            maxCharacters: 80
        )

        let quote = try normalizedRequired(
            fragment.quote,
            field: "quote",
            maxCharacters: 220
        )

        let reflection = try normalizedRequired(
            fragment.reflection,
            field: "reflection",
            maxCharacters: 260
        )

        return .init(
            title: title,
            quote: quote,
            reflection: reflection
        )
    }

    func normalizedRequired(
        _ value: String,
        field: String,
        maxCharacters: Int
    ) throws -> String {
        let normalized = value
            .replacingOccurrences(
                of: "\n",
                with: " "
            )
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard !normalized.isEmpty else {
            throw AppleGeneratedFragmentError.emptyField(
                field
            )
        }

        guard normalized.count <= maxCharacters else {
            throw AppleGeneratedFragmentError.fieldTooLong(
                field: field,
                count: normalized.count,
                maximum: maxCharacters
            )
        }

        return normalized
    }
}
