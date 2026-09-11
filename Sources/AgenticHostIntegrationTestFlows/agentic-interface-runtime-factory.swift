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

    static func bedrockGateway(
        metadata: [String: String]
    ) throws -> BedrockModelGateway {
        try BedrockModelGateway.resolve(
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

        let gateway = try bedrockGateway(
            metadata: metadata
        )

        return try AgentModelBroker(
            profiles: .init(
                profiles: [
                    executor,
                    advisor,
                ]
            ),
            gateways: .init(
                gateways: [
                    gateway,
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
                defaultProfileIdentifier: executor.identifier
            )
        )
    }
}
