import AgenticModels
import Agentic
import AgenticAWS
import AgenticInterfaces

enum AgenticInterfaceRuntimeFactory {
    static func presenter() -> TerminalAgenticRunPresenter {
        TerminalAgenticRunPresenter(
            showsVerboseEvents: AgenticInterfaceTestEnvironment.options.verbose
        )
    }

    static func bedrockAdapter(
        defaultModelIdentifier: String,
        metadata: [String: String]
    ) throws -> BedrockModelAdapter {
        try BedrockModelAdapter.resolve(
            defaultModelIdentifier: defaultModelIdentifier,
            metadata: metadata,
            diagnostics: .init(
                raw: AgenticInterfaceTestEnvironment.options.raw
            )
        )
    }

    static func bedrockModelBroker(
        executorModelIdentifier: String,
        advisorModelIdentifier: String,
        metadata: [String: String]
    ) throws -> AgentModelBroker {
        let executor = BedrockModelProfiles.novaMicro(
            executorModelIdentifier
        )

        let advisor = BedrockModelProfiles.advisor(
            advisorModelIdentifier,
            identifier: .init(
                "aws_bedrock:advisor"
            ),
            title: "AWS Bedrock Advisor"
        )

        let adapter = try bedrockAdapter(
            defaultModelIdentifier: executorModelIdentifier,
            metadata: metadata
        )

        return try AgentModelBroker(
            profiles: .init(
                profiles: [
                    executor,
                    advisor,
                ]
            ),
            adapters: .init(
                adapters: [
                    (
                        .aws_bedrock,
                        adapter
                    ),
                ]
            ),
            router: StaticAgentModelRouter(
                defaults: [
                    .executor: executor.identifier,
                    .planner: advisor.identifier,
                    .researcher: advisor.identifier,
                    .advisor: advisor.identifier,
                    .reviewer: advisor.identifier,
                    .coder: advisor.identifier,
                    .summarizer: executor.identifier,
                    .classifier: executor.identifier,
                    .extractor: executor.identifier,
                ],
                fallback: [
                    .executor,
                ],
                defaultProfileIdentifier: executor.identifier
            )
        )
    }
}
