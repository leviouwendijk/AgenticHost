import Agentic
import AgenticInterfaces
import AgenticModels
import AgenticRuntime
import Workspace

public struct ModeRunPreparation: Sendable {
    public var selection: ModeSelection
    public var application: ModeRuntimeApplication
    public var request: AgentRequest
    public var command: AgenticRunCommandModel
    public var screen: AgenticRunScreen

    public init(
        selection: ModeSelection,
        application: ModeRuntimeApplication,
        request: AgentRequest,
        command: AgenticRunCommandModel,
        screen: AgenticRunScreen
    ) {
        self.selection = selection
        self.application = application
        self.request = request
        self.command = command
        self.screen = screen
    }

    public func runner(
        model: RuntimeServices.Model,
        tooling: RuntimeServices.Tooling = .init(),
        extensions: [any AgentHarnessExtension] = [],
        recording: RuntimeServices.Recording = .init()
    ) -> AgentRunner {
        AgentRunner(
            model: model,
            modeApplication: application,
            tooling: tooling,
            extensions: extensions,
            recording: recording
        )
    }
}

public struct ModeRunFactory: Sendable {
    public var catalog: ModeCatalog

    public init(
        catalog: ModeCatalog
    ) {
        self.catalog = catalog
    }

    public static func standard() throws -> Self {
        try .init(
            catalog: .standard
        )
    }

    public func make(
        modeID: ModeIdentifier,
        prompt: String,
        system: String? = nil,
        tools: ToolRegistry,
        capabilityState: AgentCapabilityState,
        instructionCatalog: Catalog = .none,
        baseConfiguration: AgentRunner.Configuration = .default,
        overlay: ModeOverlay = .init(),
        generationConfiguration: AgentGenerationConfiguration = .default,
        metadata: [String: String] = [:]
    ) async throws -> ModeRunPreparation {
        let selection = try catalog.selection(
            modeID,
            overlay: overlay
        )
        let application = try ModeRuntimeApplication(
            selection: selection,
            configuration: baseConfiguration,
            tools: tools,
            capabilityState: capabilityState,
            instructionCatalog: instructionCatalog,
            metadata: metadata
        )
        let request = try await application.request(
            user: prompt,
            system: system,
            generationConfiguration: generationConfiguration,
            additionalMetadata: metadata
        )
        let command = AgenticRunCommandModel(
            prompt: prompt,
            application: application,
            request: request
        )
        let screen = AgenticRunScreen(
            command: command
        )

        return .init(
            selection: selection,
            application: application,
            request: request,
            command: command,
            screen: screen
        )
    }
}
