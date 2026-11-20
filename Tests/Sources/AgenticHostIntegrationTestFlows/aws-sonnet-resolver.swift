import AWSConnector
import Foundation

internal enum AWSBedrockSonnetResolver {
    static func resolve(
        explicitModelIdentifier: String?,
        modelMatch: String
    ) async throws -> String {
        if let explicitModelIdentifier {
            let trimmed = explicitModelIdentifier.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

            if !trimmed.isEmpty {
                return trimmed
            }
        }

        let control = try BedrockClient.resolve()
        let match = AWSBedrockModelMatch(
            modelMatch
        )

        if let profile = try await matchingInferenceProfile(
            control: control,
            match: match
        ) {
            return profile.inferenceProfileId
        }

        if let model = try await matchingFoundationModel(
            control: control,
            match: match
        ) {
            return model.modelId
        }

        throw AWSBedrockSonnetResolverError.noMatchingModel(
            modelMatch
        )
    }

    static func matchingInferenceProfile(
        control: BedrockClient,
        match: AWSBedrockModelMatch
    ) async throws -> Bedrock.InferenceProfiles.Summary? {
        let response = try await control.inferenceProfiles.list(
            .init(
                maxResults: 25,
                nextToken: nil,
                typeEquals: "SYSTEM_DEFINED"
            )
        )

        return response.inferenceProfileSummaries
            .filter {
                $0.status.uppercased() == "ACTIVE"
            }
            .filter {
                !isProbablyLegacyProfile(
                    $0
                )
            }
            .filter {
                match.matches(
                    profileSearchText(
                        $0
                    )
                )
            }
            .sorted {
                profileScore($0) > profileScore($1)
            }
            .first
    }

    static func matchingFoundationModel(
        control: BedrockClient,
        match: AWSBedrockModelMatch
    ) async throws -> Bedrock.Models.Summary? {
        let response = try await control.models.list(
            .init(
                byOutputModality: "TEXT",
                byProvider: match.requiresAnthropic ? "Anthropic" : nil
            )
        )

        return response.modelSummaries
            .filter {
                $0.responseStreamingSupported != false
            }
            .filter {
                $0.modelLifecycle?.status?.uppercased() != "LEGACY"
            }
            .filter {
                !isProbablyLegacyModel(
                    $0
                )
            }
            .filter {
                match.matches(
                    modelSearchText(
                        $0
                    )
                )
            }
            .sorted {
                modelScore($0) > modelScore($1)
            }
            .first
    }

    static func profileSearchText(
        _ profile: Bedrock.InferenceProfiles.Summary
    ) -> String {
        [
            profile.inferenceProfileId,
            profile.inferenceProfileName,
            profile.type,
            profile.status,
            profile.models.map(\.modelArn).joined(
                separator: " "
            )
        ].joined(
            separator: " "
        )
    }

    static func modelSearchText(
        _ model: Bedrock.Models.Summary
    ) -> String {
        [
            model.modelId,
            model.modelName ?? "",
            model.providerName ?? "",
            model.modelLifecycle?.status ?? ""
        ].joined(
            separator: " "
        )
    }

    static func isProbablyLegacyProfile(
        _ profile: Bedrock.InferenceProfiles.Summary
    ) -> Bool {
        isProbablyLegacyText(
            profileSearchText(
                profile
            )
        )
    }

    static func isProbablyLegacyModel(
        _ model: Bedrock.Models.Summary
    ) -> Bool {
        isProbablyLegacyText(
            modelSearchText(
                model
            )
        )
    }

    static func isProbablyLegacyText(
        _ text: String
    ) -> Bool {
        let normalized = AWSBedrockModelMatch.normalizedText(
            text
        )

        return normalized.contains("legacy")
            || normalized.contains("claude 3 sonnet")
            || normalized.contains("claude 3 5 sonnet 20240620")
            || normalized.contains("claude 3 5 sonnet 20241022")
            || normalized.contains("claude 3 haiku")
            || normalized.contains("claude 3 opus")
    }

    static func profileScore(
        _ profile: Bedrock.InferenceProfiles.Summary
    ) -> Int {
        score(
            profileSearchText(
                profile
            )
        )
    }

    static func modelScore(
        _ model: Bedrock.Models.Summary
    ) -> Int {
        score(
            modelSearchText(
                model
            )
        )
    }

    static func score(
        _ text: String
    ) -> Int {
        let tokens = Set(
            AWSBedrockModelMatch.tokens(
                text
            )
        )
        let normalized = AWSBedrockModelMatch.normalizedText(
            text
        )

        var score = 0

        if tokens.contains("sonnet") {
            score += 100
        }

        if tokens.contains("claude") {
            score += 50
        }

        if tokens.contains("anthropic") {
            score += 25
        }

        if normalized.contains("sonnet 4")
            || normalized.contains("claude sonnet 4")
            || normalized.contains("claude 4 sonnet") {
            score += 90
        }

        if tokens.contains("3"),
           tokens.contains("7"),
           tokens.contains("sonnet") {
            score += 70
        }

        if isProbablyLegacyText(
            text
        ) {
            score -= 10_000
        }

        score += latestEmbeddedDateScore(
            tokens: tokens
        )

        return score
    }

    static func latestEmbeddedDateScore(
        tokens: Set<String>
    ) -> Int {
        let dates = tokens.compactMap { token -> Int? in
            guard token.count == 8,
                  token.hasPrefix("20"),
                  let value = Int(token)
            else {
                return nil
            }

            return value
        }

        guard let latest = dates.max() else {
            return 0
        }

        return max(
            0,
            (latest - 20_240_000) / 100
        )
    }
}

internal struct AWSBedrockModelMatch: Sendable, Hashable {
    var rawValue: String
    var tokens: [String]

    init(
        _ rawValue: String
    ) {
        self.rawValue = rawValue
        self.tokens = Self.tokens(
            rawValue
        )
    }

    var requiresAnthropic: Bool {
        tokens.contains("sonnet")
            || tokens.contains("claude")
            || tokens.contains("anthropic")
    }

    func matches(
        _ text: String
    ) -> Bool {
        let textTokens = Set(
            Self.tokens(
                text
            )
        )

        return tokens.allSatisfy {
            textTokens.contains(
                $0
            )
        }
    }

    static func normalizedText(
        _ value: String
    ) -> String {
        tokens(
            value
        ).joined(
            separator: " "
        )
    }

    static func tokens(
        _ value: String
    ) -> [String] {
        let normalized = value.lowercased().map { character in
            if character.isLetter || character.isNumber {
                return String(
                    character
                )
            }

            return " "
        }.joined()

        return normalized
            .split(
                separator: " "
            )
            .map(String.init)
    }
}

internal enum AWSBedrockSonnetResolverError: Error, Sendable, LocalizedError {
    case noMatchingModel(String)
    case invalidDouble(argument: String, value: String)

    var errorDescription: String? {
        switch self {
        case .noMatchingModel(let match):
            return "Could not find an active non-legacy Bedrock inference profile or foundation model matching '\(match)'. Pass --model with an exact model/profile identifier."

        case .invalidDouble(let argument, let value):
            return "Expected \(argument) to be a Double, got '\(value)'."
        }
    }
}
