import Agentic
import AgenticExecution
import AgenticInterfaces
import AgenticModels
import AgenticRuntime
import AgenticUsage
import AgenticWorkspace

public struct AgenticRunCommand: Sendable, Codable, Hashable {
    public var modeID: AgenticModeIdentifier
    public var prompt: String
    public var system: String?
    public var baseConfiguration: AgentRunnerConfiguration
    public var overlay: ModeOverlay
    public var generationConfiguration: AgentGenerationConfiguration
    public var metadata: [String: String]

    public init(
        modeID: AgenticModeIdentifier,
        prompt: String,
        system: String? = nil,
        baseConfiguration: AgentRunnerConfiguration = .default,
        overlay: ModeOverlay = .init(),
        generationConfiguration: AgentGenerationConfiguration = .default,
        metadata: [String: String] = [:]
    ) {
        self.modeID = modeID
        self.prompt = prompt
        self.system = system
        self.baseConfiguration = baseConfiguration
        self.overlay = overlay
        self.generationConfiguration = generationConfiguration
        self.metadata = metadata
    }

    public static func coder(
        _ prompt: String,
        system: String? = nil,
        metadata: [String: String] = [:]
    ) -> Self {
        .init(
            modeID: .coder,
            prompt: prompt,
            system: system,
            metadata: metadata
        )
    }
}

public struct AgenticRunCommandFactory: Sendable {
    public var modeRunFactory: ModeRunFactory

    public init(
        modeRunFactory: ModeRunFactory
    ) {
        self.modeRunFactory = modeRunFactory
    }

    public static func standard() throws -> Self {
        try .init(
            modeRunFactory: .standard()
        )
    }

    public func prepare(
        _ command: AgenticRunCommand,
        tools: ToolRegistry,
        skills: SkillRegistry = .init()
    ) throws -> ModeRunPreparation {
        try modeRunFactory.make(
            modeID: command.modeID,
            prompt: command.prompt,
            system: command.system,
            tools: tools,
            skills: skills,
            baseConfiguration: command.baseConfiguration,
            overlay: command.overlay,
            generationConfiguration: command.generationConfiguration,
            metadata: command.metadata
        )
    }
}

public struct AgenticRunCommandExecution: Sendable {
    public var command: AgenticRunCommand
    public var preparation: ModeRunPreparation
    public var result: AgenticInterfaceRunControllerResult

    public init(
        command: AgenticRunCommand,
        preparation: ModeRunPreparation,
        result: AgenticInterfaceRunControllerResult
    ) {
        self.command = command
        self.preparation = preparation
        self.result = result
    }
}

public struct AgenticRunCommandExecutor: Sendable {
    public var factory: AgenticRunCommandFactory
    public var controller: AgenticInterfaceRunController

    public init(
        factory: AgenticRunCommandFactory,
        controller: AgenticInterfaceRunController
    ) {
        self.factory = factory
        self.controller = controller
    }

    public func execute(
        _ command: AgenticRunCommand,
        modelBroker: AgentModelBroker,
        tools: ToolRegistry,
        skills: SkillRegistry = .init(),
        sessionID: String? = nil,
        workspace: AgentWorkspace? = nil,
        historyStore: (any AgentHistoryStore)? = nil,
        extensions: [any AgentHarnessExtension] = [],
        eventSinks: [any AgentRunEventSink] = [],
        costTracker: AgentCostTracker? = nil,
        resumeMetadata: [String: String] = [:]
    ) async throws -> AgenticRunCommandExecution {
        let preparation = try factory.prepare(
            command,
            tools: tools,
            skills: skills
        )

        let result = try await controller.run(
            preparation,
            modelBroker: modelBroker,
            sessionID: sessionID,
            workspace: workspace,
            historyStore: historyStore,
            extensions: extensions,
            eventSinks: eventSinks,
            costTracker: costTracker,
            resumeMetadata: resumeMetadata
        )

        return .init(
            command: command,
            preparation: preparation,
            result: result
        )
    }
}
