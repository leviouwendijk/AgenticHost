import AgenticExecution
import AgenticIO
import AgenticModels
import AgenticRuntime
import AgenticTools
import AgenticWorkspace
import Agentic
import AgenticAWS
import AgenticInterfaces
import Foundation
import Primitives
import Schema
import SchemaMacros

enum AWSModelRoutingAdvisorTestCase {
    static func make() -> AgenticInterfaceTestCase {
        .init(
            id: "aws-model-routing-advisor",
            summary: "Use AWS Bedrock model routing: Nova executes, advisor_ask delegates to an advisor route."
        ) { arguments in
            try await run(
                arguments
            )
        }
    }

    static func run(
        _ arguments: [String]
    ) async throws {
        let configuration = try AWSModelRoutingAdvisorConfiguration.parse(
            arguments
        )
        let workspaceRoot = try AgenticInterfaceTestEnvironment.workspaceRoot()
        let workspace = try AgentWorkspace(
            root: workspaceRoot
        )

        for file in AWSModelRoutingAdvisorFixture.files {
            try AgenticInterfaceTestEnvironment.writeWorkspaceFile(
                file.content,
                to: file.path
            )
        }

        let broker = try AgenticInterfaceRuntimeFactory.bedrockModelBroker(
            executorModelIdentifier: configuration.executorModel,
            advisorModelIdentifier: configuration.advisorModel,
            metadata: [
                "source": "aginttest",
                "test_case": "aws-model-routing-advisor",
            ]
        )

        let advisorTool = EvidenceCheckedAdvisorTool(
            delegate: AgentAdvisorTool(
                provider: broker,
                configuration: .init(
                    maxOutputTokens: configuration.advisorMaxOutputTokens,
                    temperature: configuration.temperature
                )
            ),
            requiredPaths: AWSModelRoutingAdvisorFixture.requiredPaths
        )

        var registry = ToolRegistry()

        try registry.register {
            ReadFileTool()
            advisorTool
        }

        let historyStore = FileHistoryStore(
            sessionsdir: FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "agentic-interface-aws-model-routing-advisor-\(UUID().uuidString)",
                    isDirectory: true
                )
        )
        let presenter = AgenticInterfaceRuntimeFactory.presenter()
        let routeRenderer = TerminalModelRouteRenderer()

        let executorProbeRequest = AgentRequest(
            messages: [
                .init(
                    role: .user,
                    text: "Route probe for executor."
                )
            ],
            metadata: [
                "route_probe": "executor",
            ]
        )
        let advisorProbeRequest = AgentRequest(
            messages: [
                .init(
                    role: .user,
                    text: "Route probe for advisor."
                )
            ],
            metadata: [
                "route_probe": "advisor",
            ]
        )

        print(
            routeRenderer.render(
                try broker.route(
                    request: executorProbeRequest,
                    policy: .executor
                )
            )
        )

        print(
            routeRenderer.render(
                try broker.route(
                    request: advisorProbeRequest,
                    policy: .advisor
                )
            )
        )

        print(
            "executor model: \(configuration.executorModel)"
        )
        print(
            "advisor model: \(configuration.advisorModel)"
        )

        let runner = AgentRunner(
            modelBroker: broker,
            routePolicy: .executor,
            configuration: .init(
                maximumIterations: 16,
                autonomyMode: .auto_observe,
                historyPersistenceMode: .checkpointmutation,
                responseDelivery: .stream
            ),
            toolRegistry: registry,
            workspace: workspace,
            historyStore: historyStore
        )

        let prompt = """
            Read these files:
            \(AWSModelRoutingAdvisorFixture.requiredPaths.map { "- \($0)" }.joined(separator: "\n"))

            Then call advisor_ask after all required read_file calls succeed.

            Exactly one advisor_ask call must succeed.
            If advisor_ask returns a tool_error, repair the top-level JSON input and retry.
            Do not call advisor_ask again after it succeeds.

            The advisor_ask input must include these sibling top-level keys:
            - prompt: the architectural question for the advisor
            - context: an Evidence Packet with concrete evidence from the files
            - instruction: the desired response shape

            Do not embed Prompt: or Instruction: inside context as a substitute for top-level prompt or instruction.

            The Evidence Packet must include:
            - the exact path of every file you read
            - at least three numbered findings, using either Finding 1/Finding 2/Finding 3 or 1./2./3.
            - for each finding: file path, concrete code behavior, and why it matters
            - at least one finding from ModelRouter.swift
            - at least one finding from AdvisorPolicy.swift or ToolExposurePolicy.swift
            - at least one finding from ModelRouterTests.swift

            Ask the advisor for a concise architecture review of the routing code.

            After advisor_ask returns successfully, summarize:
            - which files you read
            - the subtle mistakes or inefficiencies you found
            - which advice the advisor gave
            - why this proves model routing delegation works

            Do not call mutate_files.
            """

        try await presenter.present(
            .runStarted(
                prompt: prompt
            )
        )

        let result = try await runner.run(
            AgentRequest(
                messages: [
                    .init(
                        role: .system,
                        text: """
                        You are the executor model in a model-routing test.

                        Required tool sequence:
                        1. Call read_file for each required fixture file:
                        \(AWSModelRoutingAdvisorFixture.requiredPaths.map { "                           - \($0)" }.joined(separator: "\n"))
                        2. After all required reads succeed, call advisor_ask.
                        3. Exactly one advisor_ask call must succeed.
                        4. After advisor_ask succeeds, stop calling tools and summarize.

                        advisor_ask top-level input contract:
                        - prompt must be a top-level string and must ask for an architectural review.
                        - context must be a top-level string and must start with "Evidence Packet".
                        - instruction must be a top-level string and must request concise advice and a v1 fix order.
                        - Do not put Prompt: or Instruction: inside context as a substitute for the top-level prompt or instruction fields.

                        Evidence Packet contract:
                        - context must include every required file path.
                        - context must include at least three numbered findings.
                        - each finding must cite a file path and describe concrete code behavior.
                        - findings may be labeled Finding 1/Finding 2/Finding 3 or 1./2./3.
                        - include at least one finding from ModelRouter.swift.
                        - include at least one finding from AdvisorPolicy.swift or ToolExposurePolicy.swift.
                        - include at least one finding from ModelRouterTests.swift.

                        Tool-call discipline:
                        Prefer one tool call per assistant response.
                        Do not call advisor_ask before the required read_file calls succeed.
                        If advisor_ask returns a tool_error, repair the top-level JSON input and retry.
                        Do not call advisor_ask again after it succeeds.
                        Do not call file mutation tools.
                        """
                    ),
                    .init(
                        role: .user,
                        text: prompt
                    )
                ],
                generationConfiguration: .init(
                    maxOutputTokens: configuration.executorMaxOutputTokens,
                    temperature: configuration.temperature
                ),
                metadata: [
                    "test_case": "aws-model-routing-advisor",
                    "expected_route": "executor",
                ]
            )
        )

        try await presenter.present(
            result
        )

        guard result.isCompleted else {
            throw AWSModelRoutingAdvisorTestError.expectedCompletion
        }
    }
}

private struct AWSModelRoutingAdvisorConfiguration: Sendable, Hashable {
    static let defaultExecutorModel = "eu.amazon.nova-micro-v1:0"
    static let defaultAdvisorModel = "eu.anthropic.claude-sonnet-4-6"

    var executorModel: String
    var advisorModel: String
    var executorMaxOutputTokens: Int
    var advisorMaxOutputTokens: Int
    var temperature: Double

    static func parse(
        _ arguments: [String]
    ) throws -> Self {
        var executorModel = ProcessInfo.processInfo.environment["AGENTIC_BEDROCK_MODEL"]
            ?? Self.defaultExecutorModel
        var advisorModel = ProcessInfo.processInfo.environment["AGENTIC_BEDROCK_ADVISOR_MODEL"]
            ?? Self.defaultAdvisorModel
        var executorMaxOutputTokens = 1_600
        var advisorMaxOutputTokens = 900
        var temperature = 0.0

        var iterator = arguments.makeIterator()

        while let argument = iterator.next() {
            switch argument {
            case "--model",
                 "--executor-model":
                executorModel = try requireNext(
                    &iterator,
                    after: argument
                )

            case "--advisor-model":
                advisorModel = try requireNext(
                    &iterator,
                    after: argument
                )

            case "--max-output-tokens",
                 "--executor-max-output-tokens":
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

                executorMaxOutputTokens = parsed

            case "--advisor-max-output-tokens":
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

                advisorMaxOutputTokens = parsed

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
                if argument.hasPrefix("--model=") {
                    executorModel = String(
                        argument.dropFirst(
                            "--model=".count
                        )
                    )
                } else if argument.hasPrefix("--executor-model=") {
                    executorModel = String(
                        argument.dropFirst(
                            "--executor-model=".count
                        )
                    )
                } else if argument.hasPrefix("--advisor-model=") {
                    advisorModel = String(
                        argument.dropFirst(
                            "--advisor-model=".count
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

                    executorMaxOutputTokens = parsed
                } else if argument.hasPrefix("--executor-max-output-tokens=") {
                    let value = String(
                        argument.dropFirst(
                            "--executor-max-output-tokens=".count
                        )
                    )

                    guard let parsed = Int(value) else {
                        throw AgenticInterfaceTestError.invalidInteger(
                            argument: "--executor-max-output-tokens",
                            value: value
                        )
                    }

                    executorMaxOutputTokens = parsed
                } else if argument.hasPrefix("--advisor-max-output-tokens=") {
                    let value = String(
                        argument.dropFirst(
                            "--advisor-max-output-tokens=".count
                        )
                    )

                    guard let parsed = Int(value) else {
                        throw AgenticInterfaceTestError.invalidInteger(
                            argument: "--advisor-max-output-tokens",
                            value: value
                        )
                    }

                    advisorMaxOutputTokens = parsed
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
            executorModel: executorModel,
            advisorModel: advisorModel,
            executorMaxOutputTokens: executorMaxOutputTokens,
            advisorMaxOutputTokens: advisorMaxOutputTokens,
            temperature: temperature
        )
    }
}

private enum AWSModelRoutingAdvisorFixture {
    struct File: Sendable, Hashable {
        var path: String
        var content: String
    }

    static let requiredPaths = [
        "ARCHITECTURE.md",
        "Sources/App/Routing/ModelRouter.swift",
        "Sources/App/Runtime/AdvisorPolicy.swift",
        "Sources/App/Runtime/ToolExposurePolicy.swift",
        "Tests/AppTests/ModelRouterTests.swift",
    ]

    static let files: [File] = [
        .init(
            path: "ARCHITECTURE.md",
            content: """
            # Routing Harness

            This project separates cheap executor orchestration from expensive advisor judgement.

            Intended invariants:
            - executor handles cheap deterministic orchestration
            - advisor handles architectural judgement
            - advisor calls receive no tools
            - route decisions preserve reasons and warnings for audit
            - privacy-sensitive requests must not route to public profiles
            - deterministic classification should not use premium advisor models

            Known assumption:
            Advisor routes are safe because they are observe-only.

            The assumption above is intentionally incomplete: observe-only model calls can still leak context or tool access if tool exposure is inherited from the caller.
            """
        ),
        .init(
            path: "Sources/App/Routing/RoutePurpose.swift",
            content: """
            public enum RoutePurpose: String, Sendable, Codable, Hashable {
                case executor
                case advisor
                case reviewer
                case coder
                case summarizer
                case classifier
                case extractor
            }
            """
        ),
        .init(
            path: "Sources/App/Routing/ModelProfile.swift",
            content: """
            public struct ModelProfile: Sendable, Codable, Hashable {
                public var id: String
                public var model: String
                public var purposes: Set<RoutePurpose>
                public var cost: CostClass
                public var privacy: PrivacyClass
                public var supportsTools: Bool

                public init(
                    id: String,
                    model: String,
                    purposes: Set<RoutePurpose>,
                    cost: CostClass,
                    privacy: PrivacyClass,
                    supportsTools: Bool
                ) {
                    self.id = id
                    self.model = model
                    self.purposes = purposes
                    self.cost = cost
                    self.privacy = privacy
                    self.supportsTools = supportsTools
                }
            }

            public enum CostClass: String, Sendable, Codable, Hashable {
                case cheap
                case balanced
                case premium
            }

            public enum PrivacyClass: String, Sendable, Codable, Hashable {
                case local
                case private_cloud
                case external
            }
            """
        ),
        .init(
            path: "Sources/App/Routing/RouteDecision.swift",
            content: """
            public struct RouteDecision: Sendable, Codable, Hashable {
                public var purpose: RoutePurpose
                public var profileID: String
                public var model: String

                public init(
                    purpose: RoutePurpose,
                    profileID: String,
                    model: String
                ) {
                    self.purpose = purpose
                    self.profileID = profileID
                    self.model = model
                }
            }

            public struct RouteCandidate: Sendable, Codable, Hashable {
                public var profile: ModelProfile
                public var reasons: [String]
                public var warnings: [String]

                public init(
                    profile: ModelProfile,
                    reasons: [String] = [],
                    warnings: [String] = []
                ) {
                    self.profile = profile
                    self.reasons = reasons
                    self.warnings = warnings
                }
            }
            """
        ),
        .init(
            path: "Sources/App/Routing/ModelRouter.swift",
            content: """
            public struct ModelRouter: Sendable {
                public var profiles: [ModelProfile]
                public var defaultExecutorProfileID: String

                public init(
                    profiles: [ModelProfile],
                    defaultExecutorProfileID: String
                ) {
                    self.profiles = profiles
                    self.defaultExecutorProfileID = defaultExecutorProfileID
                }

                public func route(
                    purpose: RoutePurpose,
                    requiresPrivate: Bool,
                    deterministic: Bool
                ) throws -> RouteDecision {
                    let candidates = profiles
                        .filter { profile in
                            profile.purposes.contains(purpose)
                        }
                        .map { profile in
                            RouteCandidate(
                                profile: profile,
                                reasons: [
                                    "purpose_match",
                                ],
                                warnings: []
                            )
                        }

                    let selected = candidates.first ?? fallback(
                        purpose: purpose
                    )

                    if deterministic && selected.profile.cost == .premium {
                        // This keeps implementation simple, but wastes advisor capacity on cheap classification.
                        return decision(
                            purpose: purpose,
                            candidate: selected
                        )
                    }

                    if requiresPrivate && selected.profile.privacy == .external {
                        // Caller promises not to send sensitive context, so allow this for now.
                        return decision(
                            purpose: purpose,
                            candidate: selected
                        )
                    }

                    return decision(
                        purpose: purpose,
                        candidate: selected
                    )
                }

                private func fallback(
                    purpose: RoutePurpose
                ) -> RouteCandidate {
                    let profile = profiles.first {
                        $0.id == defaultExecutorProfileID
                    } ?? profiles[0]

                    return RouteCandidate(
                        profile: profile,
                        reasons: [
                            "fallback_executor",
                        ],
                        warnings: [
                            "fallback ignores requested purpose \\(purpose.rawValue)"
                        ]
                    )
                }

                private func decision(
                    purpose: RoutePurpose,
                    candidate: RouteCandidate
                ) -> RouteDecision {
                    RouteDecision(
                        purpose: purpose,
                        profileID: candidate.profile.id,
                        model: candidate.profile.model
                    )
                }
            }
            """
        ),
        .init(
            path: "Sources/App/Runtime/AdvisorPolicy.swift",
            content: """
            public struct AdvisorPolicy: Sendable, Codable, Hashable {
                public var maxOutputTokens: Int
                public var temperature: Double
                public var inheritCallerTools: Bool

                public init(
                    maxOutputTokens: Int = 900,
                    temperature: Double = 0.0,
                    inheritCallerTools: Bool = true
                ) {
                    self.maxOutputTokens = maxOutputTokens
                    self.temperature = temperature
                    self.inheritCallerTools = inheritCallerTools
                }

                public func toolNamesForAdvisor(
                    callerTools: [String]
                ) -> [String] {
                    if inheritCallerTools {
                        return callerTools
                    }

                    return []
                }
            }
            """
        ),
        .init(
            path: "Sources/App/Runtime/ToolExposurePolicy.swift",
            content: """
            public struct ToolExposurePolicy: Sendable, Codable, Hashable {
                public init() {
                }

                public func allowedTools(
                    purpose: RoutePurpose,
                    callerTools: [String]
                ) -> [String] {
                    switch purpose {
                    case .advisor,
                         .reviewer:
                        return callerTools

                    case .executor,
                         .coder,
                         .summarizer,
                         .classifier,
                         .extractor:
                        return callerTools
                    }
                }
            }
            """
        ),
        .init(
            path: "Tests/AppTests/ModelRouterTests.swift",
            content: """
            import Testing

            struct ModelRouterTests {
                @Test
                func fallsBackToExecutorWhenNoPurposeMatch() throws {
                    let router = ModelRouter(
                        profiles: [
                            .init(
                                id: "cheap-executor",
                                model: "nova-micro",
                                purposes: [
                                    .executor,
                                    .classifier,
                                ],
                                cost: .cheap,
                                privacy: .private_cloud,
                                supportsTools: true
                            ),
                        ],
                        defaultExecutorProfileID: "cheap-executor"
                    )

                    let decision = try router.route(
                        purpose: .advisor,
                        requiresPrivate: false,
                        deterministic: false
                    )

                    #expect(decision.profileID == "cheap-executor")
                }

                @Test
                func advisorPolicyCurrentlyInheritsTools() {
                    let policy = AdvisorPolicy(
                        inheritCallerTools: true
                    )

                    #expect(
                        policy.toolNamesForAdvisor(
                            callerTools: [
                                "read_file",
                                "mutate_files",
                            ]
                        ) == [
                            "read_file",
                            "mutate_files",
                        ]
                    )
                }
            }
            """
        ),
    ]
}

private enum AWSModelRoutingAdvisorTestError: Error, Sendable, LocalizedError {
    case expectedCompletion

    var errorDescription: String? {
        switch self {
        case .expectedCompletion:
            return "Expected the AWS model routing advisor flow to complete after the required reads and one successful advisor_ask call."
        }
    }
}

@JSONSchema
private struct EvidenceCheckedAdvisorToolRawInput: Sendable, Codable, Hashable {
    var prompt: String?
    var context: String?
    var instruction: String?
}

private struct EvidenceCheckedAdvisorTool: AgentTool {
    typealias Input = EvidenceCheckedAdvisorToolRawInput
    typealias Output = AgentAdvisorToolOutput

    static let identifier = AgentAdvisorToolDefaults.identifier

    var delegate: AgentAdvisorTool
    var requiredPaths: [String]

    var identifier: AgentToolIdentifier {
        delegate.identifier
    }

    var description: String {
        """
        Ask the configured advisor model for bounded, advisory reasoning.

        The input context must be an Evidence Packet containing concrete findings from the files read by the executor.
        The advisor receives no tools and cannot authorize actions.
        """
    }

    var risk: ActionRisk {
        delegate.risk
    }

    func preflight(
        _ input: Input,
        context: AgentToolExecutionContext
    ) async throws -> ToolPreflight {
        let advisorInput = try normalizedAdvisorInput(
            input
        )

        return try await delegate.preflight(
            advisorInput,
            context: context
        )
    }

    func call(
        _ input: Input,
        context: AgentToolExecutionContext
    ) async throws -> Output {
        let advisorInput = try normalizedAdvisorInput(
            input
        )

        try validate(
            advisorInput
        )

        return try await delegate.call(
            advisorInput,
            context: context
        )
    }
}

private extension EvidenceCheckedAdvisorTool {
    func normalizedAdvisorInput(
        _ input: EvidenceCheckedAdvisorToolRawInput
    ) throws -> AgentAdvisorToolInput {
        guard let prompt = normalized(
            input.prompt
        ) else {
            throw EvidenceCheckedAdvisorToolError.missingPrompt
        }

        guard let context = normalized(
            input.context
        ) else {
            throw EvidenceCheckedAdvisorToolError.missingContext
        }

        guard let instruction = normalized(
            input.instruction
        ) else {
            throw EvidenceCheckedAdvisorToolError.missingInstruction
        }

        return AgentAdvisorToolInput(
            prompt: prompt,
            context: context,
            instruction: instruction
        )
    }

    func validate(
        _ input: AgentAdvisorToolInput
    ) throws {
        let prompt = normalized(
            input.prompt
        )
        let context = normalized(
            input.context
        )
        let instruction = normalized(
            input.instruction
        )

        guard prompt != nil else {
            throw EvidenceCheckedAdvisorToolError.missingPrompt
        }

        guard let context else {
            throw EvidenceCheckedAdvisorToolError.missingContext
        }

        guard instruction != nil else {
            throw EvidenceCheckedAdvisorToolError.missingInstruction
        }

        guard context.hasPrefix("Evidence Packet") else {
            throw EvidenceCheckedAdvisorToolError.missingEvidencePacketHeader
        }

        let missingPaths = requiredPaths.filter { path in
            !context.contains(
                path
            )
        }

        guard missingPaths.isEmpty else {
            throw EvidenceCheckedAdvisorToolError.missingRequiredPaths(
                missingPaths
            )
        }

        let findingCount = findingMarkerSets.filter { markers in
            markers.contains { marker in
                context.contains(
                    marker
                )
            }
        }.count

        guard findingCount >= 3 else {
            throw EvidenceCheckedAdvisorToolError.insufficientFindings
        }

        guard context.contains("Sources/App/Routing/ModelRouter.swift") else {
            throw EvidenceCheckedAdvisorToolError.missingFindingArea(
                "ModelRouter.swift"
            )
        }

        guard context.contains("Sources/App/Runtime/AdvisorPolicy.swift")
            || context.contains("Sources/App/Runtime/ToolExposurePolicy.swift")
        else {
            throw EvidenceCheckedAdvisorToolError.missingFindingArea(
                "AdvisorPolicy.swift or ToolExposurePolicy.swift"
            )
        }

        guard context.contains("Tests/AppTests/ModelRouterTests.swift") else {
            throw EvidenceCheckedAdvisorToolError.missingFindingArea(
                "ModelRouterTests.swift"
            )
        }
    }

    var findingMarkerSets: [[String]] {
        [
            [
                "Finding 1",
                "\n1.",
                "\n1)",
                "1. ",
                "1) ",
            ],
            [
                "Finding 2",
                "\n2.",
                "\n2)",
                "2. ",
                "2) ",
            ],
            [
                "Finding 3",
                "\n3.",
                "\n3)",
                "3. ",
                "3) ",
            ],
        ]
    }

    func normalized(
        _ value: String?
    ) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        return trimmed.isEmpty ? nil : trimmed
    }
}

private enum EvidenceCheckedAdvisorToolError: Error, Sendable, LocalizedError {
    case missingPrompt
    case missingContext
    case missingInstruction
    case missingEvidencePacketHeader
    case missingRequiredPaths([String])
    case insufficientFindings
    case missingFindingArea(String)

    var errorDescription: String? {
        switch self {
        case .missingPrompt:
            return "advisor_ask requires a top-level prompt field. Do not put Prompt: inside context."

        case .missingContext:
            return "advisor_ask requires a top-level context field containing an Evidence Packet."

        case .missingInstruction:
            return "advisor_ask requires a top-level instruction field describing the desired advisor response shape. Do not put Instruction: inside context."

        case .missingEvidencePacketHeader:
            return "advisor_ask context must start with 'Evidence Packet'."

        case .missingRequiredPaths(let paths):
            return "advisor_ask Evidence Packet is missing required file path(s): \(paths.joined(separator: ", "))."

        case .insufficientFindings:
            return "advisor_ask Evidence Packet must include at least three numbered findings, such as Finding 1/Finding 2/Finding 3 or 1./2./3."

        case .missingFindingArea(let area):
            return "advisor_ask Evidence Packet is missing a required finding area: \(area)."
        }
    }
}