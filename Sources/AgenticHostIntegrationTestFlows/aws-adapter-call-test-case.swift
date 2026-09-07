import Agentic
import AgenticAWS
import AgenticInterfaces
import AWSConnector
import Foundation

enum AWSAdapterCallTestCase {
    static func make() -> AgenticInterfaceTestCase {
        .init(
            id: "aws-call",
            summary: "Call AgenticAWS BedrockModelAdapter directly and print the response."
        ) { arguments in
            try await run(
                arguments
            )
        }
    }

    static func run(
        _ arguments: [String]
    ) async throws {
        let configuration = try AWSAdapterCallConfiguration.parse(
            arguments
        )
        // let credentials = try AWSCredentials(
        //     accessKeyIdSymbol: "AWS_ACCESS_KEY_ID",
        //     secretAccessKeySymbol: "AWS_SECRET_ACCESS_KEY",
        //     sessionTokenSymbol: "AWS_SESSION_TOKEN"
        // )
        // let runtime = BedrockRuntimeClient(
        //     region: configuration.region,
        //     credentials: credentials
        // )
        // let modelIdentifier = try await AWSBedrockSonnetResolver.resolve(
        //     explicitModelIdentifier: configuration.model,
        //     modelMatch: configuration.modelMatch
        // )

        let adapter = try AgenticInterfaceRuntimeFactory.bedrockAdapter(
            defaultModelIdentifier: configuration.model,
            metadata: [
                "source": "aginttest",
                "test_case": "aws-call",
            ]
        )

        let response = try await adapter.respond(
            request: AgentRequest(
                messages: [
                    .init(
                        role: .system,
                        text: "Answer in one short sentence."
                    ),
                    .init(
                        role: .user,
                        text: configuration.prompt
                    )
                ],
                generationConfiguration: .init(
                    maxOutputTokens: configuration.maxOutputTokens,
                    temperature: configuration.temperature
                )
            )
        )

        print(
            response.message.content.text.trimmingCharacters(
                in: CharacterSet.whitespacesAndNewlines
            )
        )
    }
}

private struct AWSAdapterCallConfiguration: Sendable, Hashable {
    static let defaultModel = "eu.amazon.nova-micro-v1:0"

    var region: String
    var model: String
    var prompt: String
    var maxOutputTokens: Int
    var temperature: Double

    static func parse(
        _ arguments: [String]
    ) throws -> Self {
        var region = ProcessInfo.processInfo.environment["AWS_REGION"] ?? "eu-west-1"
        var model = ProcessInfo.processInfo.environment["AGENTIC_BEDROCK_MODEL"] ?? Self.defaultModel
        var prompt = "Say hello from the AgenticInterfaces AWS adapter call case."
        var maxOutputTokens = 80
        var temperature = 0.0

        var iterator = arguments.makeIterator()

        while let argument = iterator.next() {
            switch argument {
            case "--region":
                region = try requireNext(
                    &iterator,
                    after: argument
                )

            case "--model":
                model = try requireNext(
                    &iterator,
                    after: argument
                )

            case "--prompt":
                prompt = try requireNext(
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
                if argument.hasPrefix("--region=") {
                    region = String(
                        argument.dropFirst(
                            "--region=".count
                        )
                    )
                } else if argument.hasPrefix("--model=") {
                    model = String(
                        argument.dropFirst(
                            "--model=".count
                        )
                    )
                } else if argument.hasPrefix("--prompt=") {
                    prompt = String(
                        argument.dropFirst(
                            "--prompt=".count
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
                } else {
                    throw AgenticInterfaceTestError.unknownArgument(
                        argument
                    )
                }
            }
        }

        return .init(
            region: region,
            model: model,
            prompt: prompt,
            maxOutputTokens: maxOutputTokens,
            temperature: temperature
        )
    }
}
