import Foundation

/// Shared command-line configuration for AWS mutation approval integration flows.
struct AWSMutationApprovalConfiguration: Sendable, Hashable {
    static let defaultModel = "eu.amazon.nova-micro-v1:0"

    var targetPath: String
    var model: String
    var maxOutputTokens: Int
    var temperature: Double

    static func parse(
        _ arguments: [String]
    ) throws -> Self {
        var targetPath = "aws-test.swift"
        var model = ProcessInfo.processInfo.environment["AGENTIC_BEDROCK_MODEL"] ?? Self.defaultModel
        var maxOutputTokens = 1_600
        var temperature = 0.0

        var iterator = arguments.makeIterator()

        while let argument = iterator.next() {
            switch argument {
            case "--path":
                targetPath = try requireNext(
                    &iterator,
                    after: argument
                )

            case "--model":
                model = try requireNext(
                    &iterator,
                    after: argument
                )

            case "--max-output-tokens":
                let value = try requireNext(
                    &iterator,
                    after: argument
                )

                guard let parsed = Int(value) else {
                    throw AgenticInterfaceTestError.invalidInteger(
                        argument: argument,
                        value: value
                    )
                }

                maxOutputTokens = parsed

            case "--temperature":
                let value = try requireNext(
                    &iterator,
                    after: argument
                )

                guard let parsed = Double(value) else {
                    throw AgenticInterfaceTestError.unknownArgument(
                        "\(argument) \(value)"
                    )
                }

                temperature = parsed

            default:
                if argument.hasPrefix("--path=") {
                    targetPath = String(
                        argument.dropFirst(
                            "--path=".count
                        )
                    )
                } else if argument.hasPrefix("--model=") {
                    model = String(
                        argument.dropFirst(
                            "--model=".count
                        )
                    )
                } else if argument.hasPrefix("--max-output-tokens=") {
                    let value = String(
                        argument.dropFirst(
                            "--max-output-tokens=".count
                        )
                    )

                    guard let parsed = Int(value) else {
                        throw AgenticInterfaceTestError.invalidInteger(
                            argument: "--max-output-tokens",
                            value: value
                        )
                    }

                    maxOutputTokens = parsed
                } else if argument.hasPrefix("--temperature=") {
                    let value = String(
                        argument.dropFirst(
                            "--temperature=".count
                        )
                    )

                    guard let parsed = Double(value) else {
                        throw AgenticInterfaceTestError.unknownArgument(
                            "--temperature=\(value)"
                        )
                    }

                    temperature = parsed
                } else if !argument.hasPrefix("-") {
                    targetPath = argument
                } else {
                    throw AgenticInterfaceTestError.unknownArgument(
                        argument
                    )
                }
            }
        }

        return .init(
            targetPath: targetPath,
            model: model,
            maxOutputTokens: maxOutputTokens,
            temperature: temperature
        )
    }
}

/// Source fixture used by the single-file AWS mutate_files refactor flow.
enum AWSMutationRefactorFixture {
    static let content = """
    import Foundation

    public struct AWSFormatter {
        public init() {}

        public func renderUser(
            name: String,
            city: String,
            score: Int
        ) -> String {
            let trimmedName = name.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let trimmedCity = city.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

            return "user=\\(trimmedName); city=\\(trimmedCity); score=\\(score)"
        }

        public func renderDog(
            name: String,
            breed: String,
            age: Int
        ) -> String {
            let trimmedName = name.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let trimmedBreed = breed.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

            return "dog=\\(trimmedName); breed=\\(trimmedBreed); age=\\(age)"
        }

        public func renderAppointment(
            client: String,
            topic: String,
            hour: Int
        ) -> String {
            let trimmedClient = client.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let trimmedTopic = topic.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

            return "client=\\(trimmedClient); topic=\\(trimmedTopic); hour=\\(hour)"
        }
    }

    """
}
