import Agentic
import AgenticExecution
import AgenticHost
import AgenticModels
import AgenticRuntime
import AgenticUsage
import AgenticWorkspace

public struct AgenticRunCommandInvocationResult: Sendable {
    public var invocation: AgenticRunCommandInvocation
    public var execution: AgenticRunCommandExecution

    public init(
        invocation: AgenticRunCommandInvocation,
        execution: AgenticRunCommandExecution
    ) {
        self.invocation = invocation
        self.execution = execution
    }

    public var command: AgenticRunCommand {
        execution.command
    }

    public var preparation: ModeRunPreparation {
        execution.preparation
    }

    public var result: AgenticInterfaceRunControllerResult {
        execution.result
    }
}

public struct AgenticRunCommandInvocationExecutor: Sendable {
    public struct Preparation: Sendable {
        public var invocation: AgenticRunCommandInvocation
        public var preparation: ModeRunPreparation

        public init(
            invocation: AgenticRunCommandInvocation,
            preparation: ModeRunPreparation
        ) {
            self.invocation = invocation
            self.preparation = preparation
        }
    }

    public var parser: AgenticRunCommandArgumentParser
    public var commandExecutor: AgenticRunCommandExecutor

    public init(
        parser: AgenticRunCommandArgumentParser,
        commandExecutor: AgenticRunCommandExecutor
    ) {
        self.parser = parser
        self.commandExecutor = commandExecutor
    }

    public static func standard(
        controller: AgenticInterfaceRunController
    ) throws -> Self {
        try .init(
            parser: .standard(),
            commandExecutor: .init(
                factory: .standard(),
                controller: controller
            )
        )
    }

    public func prepare(
        _ argv: [String],
        tools: ToolRegistry,
        skills: SkillRegistry = .init(),
        baseConfiguration: AgentRunnerConfiguration? = nil,
        overlay: ModeOverlay? = nil,
        generationConfiguration: AgentGenerationConfiguration? = nil,
        additionalMetadata: [String: String] = [:]
    ) throws -> Preparation {
        let parsedInvocation = try parser.parse(
            argv
        )
        let invocation = resolvedInvocation(
            parsedInvocation,
            baseConfiguration: baseConfiguration,
            overlay: overlay,
            generationConfiguration: generationConfiguration,
            additionalMetadata: additionalMetadata
        )
        let preparation = try commandExecutor.factory.prepare(
            invocation.command,
            tools: tools,
            skills: skills
        )

        return .init(
            invocation: invocation,
            preparation: preparation
        )
    }

    public func execute(
        _ argv: [String],
        model: AgentRuntimeServices.Model,
        tooling: AgentRuntimeServices.Tooling = .init(),
        skills: SkillRegistry = .init(),
        sessionID: String? = nil,
        extensions: [any AgentHarnessExtension] = [],
        recording: AgentRuntimeServices.Recording = .init(),
        baseConfiguration: AgentRunnerConfiguration? = nil,
        overlay: ModeOverlay? = nil,
        generationConfiguration: AgentGenerationConfiguration? = nil,
        additionalMetadata: [String: String] = [:],
        resumeMetadata: [String: String] = [:]
    ) async throws -> AgenticRunCommandInvocationResult {
        let prepared = try prepare(
            argv,
            tools: tooling.registry,
            skills: skills,
            baseConfiguration: baseConfiguration,
            overlay: overlay,
            generationConfiguration: generationConfiguration,
            additionalMetadata: additionalMetadata
        )

        let execution = try await commandExecutor.execute(
            prepared.invocation.command,
            model: model,
            tooling: tooling,
            skills: skills,
            sessionID: sessionID,
            extensions: extensions,
            recording: recording,
            resumeMetadata: resumeMetadata
        )

        return .init(
            invocation: prepared.invocation,
            execution: execution
        )
    }
}

private extension AgenticRunCommandInvocationExecutor {
    func resolvedInvocation(
        _ invocation: AgenticRunCommandInvocation,
        baseConfiguration: AgentRunnerConfiguration?,
        overlay: ModeOverlay?,
        generationConfiguration: AgentGenerationConfiguration?,
        additionalMetadata: [String: String]
    ) -> AgenticRunCommandInvocation {
        var command = invocation.command

        if let baseConfiguration {
            command.baseConfiguration = baseConfiguration
        }

        if let overlay {
            command.overlay = overlay
        }

        if let generationConfiguration {
            command.generationConfiguration = generationConfiguration
        }

        for (key, value) in additionalMetadata {
            command.metadata[key] = value
        }

        return .init(
            arguments: invocation.arguments,
            command: command
        )
    }
}
