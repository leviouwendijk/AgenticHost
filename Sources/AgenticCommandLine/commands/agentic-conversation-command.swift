import Agentic
import AgenticRuntime
import Arguments
import Foundation

/// A direct shortcut into AgenticWorkConsole with a primary Agent selected.
/// In normal mode, <leader>pv or :Ex returns to Work without interruption; :q archives the conversation.
public enum AgenticConversationCommand<
    Application: AgenticApplicationProviding
>: ParsedArgumentCommand {
    public typealias Options = ConversationOptions

    public static var name: String { "conversation" }

    public static func run(
        _ options: Options,
        invocation: ParsedInvocation
    ) async throws {
        _ = invocation
        try await AgenticWorkConsole.launch(
            Application.self,
            workspace: options.workspace,
            voiceInput: Application.hostVoiceInputProvider,
            startConversation: true,
            preferredAgent: options.agent,
            sessionID: options.sessionID
        )
    }
}

public struct ConversationOptions: Sendable, ArgumentParsed {
    public typealias ArgumentPayload = Payload
    public let workspace: AgenticRuntimeWorkspaceConfiguration
    public let sessionID: String?
    public let agent: AgentIdentifier?

    public init(arguments: Payload) throws {
        self.workspace = try arguments.workspace.configuration()
        let session = arguments.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sessionID = session.flatMap { $0.isEmpty ? nil : $0 }
        let agent = arguments.agent?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.agent = agent.flatMap { $0.isEmpty ? nil : AgentIdentifier(rawValue: $0) }
    }

    public struct Payload: ArgumentGroup {
        @Group("workspace")
        public var workspace: AgenticRuntimeWorkspaceArguments

        @Opt("session", help: "Optional primary conversation session identifier.")
        public var sessionID: String?

        @Opt("agent", help: "Installed primary Agent identifier. Defaults to the first installed Agent.")
        public var agent: String?

        public init() {}
    }
}
