import Agentic
import AgenticIO
import AgenticInterfaces
import AgenticRuntime
import AgenticCommandLine
import AgenticStandard
import Difference
import DSL
import Errors
import Foundation
import Macros
import Primitives
import Schema
import TestFlows
import Workspace

private struct ConversationRuntimeProfileProvider:
    AgentModelProfileProvider
{
    let gatewayIdentifier: AgentModelGatewayIdentifier

    func profiles() throws -> [AgentModelProfile] {
        [
            .init(
                identifier: "conversation-scripted",
                gatewayIdentifier: gatewayIdentifier,
                model: "scripted",
                title: "Conversation Scripted",
                capabilities: [
                    .text,
                    .streaming,
                ],
                cost: .free,
                latency: .low,
                privacy: .local_private
            ),
            .init(
                identifier: "conversation-buffered",
                gatewayIdentifier: gatewayIdentifier,
                model: "buffered",
                title: "Z Conversation Buffered",
                capabilities: [
                    .text,
                ],
                cost: .free,
                latency: .low,
                privacy: .local_private
            ),
        ]
    }
}

private struct ConversationRuntimeModelProvider:
    AgentModelProvider
{
    let modelGateway: GatewayFlowScriptedModelGateway

    let descriptor = AgentModelProviderDescriptor(
        source: "conversation-scripted",
        displayName: "Conversation Scripted"
    )

    var gateways: [AgentModelGatewayFactory] {
        [
            .init(
                identifier: modelGateway.identifier
            ) {
                modelGateway
            },
        ]
    }

    var profileProviders: [any AgentModelProfileProvider] {
        [
            ConversationRuntimeProfileProvider(
                gatewayIdentifier: modelGateway.identifier
            ),
        ]
    }
}

private actor ConversationRuntimeStateSink: AgentRunStateSink {
    private var values: [AgentRunStateSnapshot] = []

    func publish(
        _ snapshot: AgentRunStateSnapshot
    ) async {
        values.append(
            snapshot
        )
    }

    func snapshots() -> [AgentRunStateSnapshot] {
        values
    }
}

private actor ConversationApprovalToolProbe {
    private var invocationCount = 0

    func recordInvocation() {
        invocationCount += 1
    }

    func count() -> Int {
        invocationCount
    }
}

private struct ConversationApprovalTool: Tool {
    typealias Input = GatewayFlowEchoToolInput
    typealias Output = GatewayFlowEchoToolOutput

    static let definition = ToolDefinition(
        identifier: .init(rawValue: "conversation_approval_tool"),
        purpose: "Bounded mutation fixture for conversation approval routing.",
        risk: .boundedmutate
    )

    static var identifier: ToolIdentifier {
        definition.identifier
    }

    let probe: ConversationApprovalToolProbe

    func preflight(
        _ input: Input,
        in _: ToolContext
    ) async throws -> ToolPreflight {
        let layout = DifferenceLayout(
            lines: [
                .init(
                    role: .headerOld,
                    text: "a/conversation.txt"
                ),
                .init(
                    role: .headerNew,
                    text: "b/conversation.txt"
                ),
                .init(
                    role: .delete,
                    text: "old",
                    coordinate: .init(
                        old: 1
                    )
                ),
                .init(
                    role: .insert,
                    text: "new",
                    coordinate: .init(
                        new: 1
                    )
                ),
            ]
        )

        return ToolPreflight(
            tool: Self.definition.identifier,
            risk: Self.definition.risk,
            summary: Self.definition.purpose,
            preview: .init(
                difference: .init(
                    title: "Conversation diff preview",
                    layout: layout
                )
            )
        )
    }

    func call(
        _ input: Input,
        in _: ToolContext
    ) async throws -> Output {
        await probe.recordInvocation()
        return GatewayFlowEchoToolOutput(
            text: input.text
        )
    }
}

private struct ConversationApprovalProgramFixture:
    Program
{
    @JSONSchema
    struct Input: HashableSource {
        let value: String
    }

    @JSONSchema
    struct Output: HashableResult {
        let value: String
    }

    static let definition = ProgramDefinition(
        identifier: "fixture.conversation_approval_program",
        purpose: "Proves Program approval suspension and resume through Host-backed conversation UI.",
        title: "Conversation Approval Program"
    )

    func run(
        _ input: Input,
        in context: ProgramContext
    ) async throws -> Output {
        let result = try await context.invoke(
            ConversationApprovalTool.identifier,
            input: GatewayFlowEchoToolInput(
                text: input.value
            ),
            as: GatewayFlowEchoToolOutput.self
        )

        return .init(
            value: result.text
        )
    }
}

private struct ConversationUserInputProgramFixture:
    Program
{
    @JSONSchema
    struct Input: HashableSource {
        let value: String
    }

    @JSONSchema
    struct Output: HashableResult {
        let value: String
    }

    static let definition = ProgramDefinition(
        identifier: "fixture.conversation_user_input_program",
        purpose: "Proves Program-native user input projection and exact Host resume through the conversation surface.",
        title: "Conversation User Input Program"
    )

    func run(
        _ input: Input,
        in context: ProgramContext
    ) async throws -> Output {
        let response = try await context.ask(
            UserInputRequest(
                prompt: "Name the continuation."
            )
        )

        guard let answer = response.answer,
              case .text(let value) = answer else {
            return .init(
                value: "\(input.value):invalid"
            )
        }

        return .init(
            value: "\(input.value):\(value)"
        )
    }
}

private struct ConversationProgramFixture:
    Program
{
    @JSONSchema
    struct Input: HashableSource {
        let value: String
    }

    @JSONSchema
    struct Output: HashableResult {
        let value: String
    }

    static let definition = ProgramDefinition(
        identifier: "fixture.conversation_program",
        purpose: "Proves direct Program execution through the Host-backed conversation surface.",
        title: "Conversation Program"
    )

    func run(
        _ input: Input,
        in _: ProgramContext
    ) async throws -> Output {
        .init(
            value: "echo:\(input.value)"
        )
    }
}

enum AgenticRuntimeConversationFlowTesting {
    static func runOrdinaryUserInputResume()
        async throws
        -> [TestDiagnostic]
    {
        let clarifyCall = ToolCall(
            id: "conversation-user-input-call",
            tool: Standard.Tools.ClarifyWithUser.definition.identifier,
            input: .object([
                "arguments": try JSONValue.encoding(
                    Standard.Tools.ClarifyWithUser.Input(
                        prompt: "Name the continuation."
                    )
                ),
            ])
        )
        let clarificationResponse = AgentResponse(
            message: .init(
                role: .assistant,
                content: .init(
                    blocks: [
                        .tool_call(
                            clarifyCall
                        ),
                    ]
                )
            ),
            stopReason: .tool_use
        )
        let finalResponse = AgentResponse(
            message: .init(
                role: .assistant,
                text: "ordinary user input resumed"
            ),
            stopReason: .end_turn
        )
        let modelGateway = GatewayFlowScriptedModelGateway(
            bufferedResponses: [
                clarificationResponse,
                finalResponse,
            ]
        )
        let application = Agentic.application(
            "conversation-user-input-runtime-fixture"
        ) {
            tools {
                Standard.Tools.ClarifyWithUser()
            }
            modelProvider(
                ConversationRuntimeModelProvider(
                    modelGateway: modelGateway
                )
            )
        }
        let runtime = try await AgenticRuntime(
            application: application
        )
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "agentic-conversation-user-input-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: workspaceRoot,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(
                at: workspaceRoot
            )
        }

        let conversation = try await makeLocalConversationSession(
            runtime: runtime,
            workspacePath: workspaceRoot.path,
            sessionID: "conversation-user-input-runtime"
        )
        let initial = try await conversation.submit(
            AgenticConversationSubmission(
                body: "Ask for the missing continuation.",
                contents: [],
                preferredModelProfileID: "conversation-scripted",
                skillIDs: [],
                toolExposure: .all,
                responseDelivery: .buffered
            )
        )
        let suspendedSnapshot = await conversation.snapshot
        let interaction = try Expect.notNil(
            initial.interactionRequest,
            "ordinary suspended run interaction request"
        )
        let pending = try Expect.notNil(
            suspendedSnapshot.pendingUserInput,
            "ordinary run projects pending user input into conversation presentation"
        )

        try Expect.equal(
            initial.isAwaitingUserInput,
            true,
            "clarify_with_user suspends the ordinary run for user input"
        )
        try Expect.equal(
            pending.interactionID,
            interaction.id,
            "conversation projects the exact Runtime interaction identity"
        )
        try Expect.equal(
            pending.runID,
            initial.sessionID,
            "conversation user input preserves the exact run identity"
        )
        try Expect.equal(
            pending.request,
            try Expect.notNil(
                interaction.requirement.pendingUserInput,
                "ordinary interaction semantic user-input request"
            ),
            "conversation projects the exact semantic user-input request"
        )

        try await conversation.resolveUserInput(
            interactionID: interaction.id,
            runID: initial.sessionID,
            reply: .text(
                "reviewed"
            )
        )

        let completedSnapshot = await conversation.snapshot
        try Expect.equal(
            completedSnapshot.pendingUserInput,
            nil,
            "ordinary user input clears after exact Host resume"
        )
        try Expect.equal(
            completedSnapshot.messages.last?.body,
            "ordinary user input resumed",
            "ordinary run continues through the model after user input"
        )
        try Expect.equal(
            await modelGateway.recordedRequests().count,
            2,
            "ordinary user-input resume continues the same model run exactly once"
        )

        var staleRejected = false
        do {
            try await conversation.resolveUserInput(
                interactionID: interaction.id,
                runID: initial.sessionID,
                reply: .text(
                    "stale"
                )
            )
        } catch AgenticConversationSessionError.staleUserInput(_, _) {
            staleRejected = true
        }

        try Expect.equal(
            staleRejected,
            true,
            "resolved ordinary user-input interaction cannot be replayed"
        )

        return [
            .field(
                "interaction",
                interaction.id
            ),
            .field(
                "model_requests",
                String(await modelGateway.recordedRequests().count)
            ),
            .field(
                "stale_rejected",
                String(staleRejected)
            ),
        ]
    }

    static func runProgramUserInputResume()
        async throws
        -> [TestDiagnostic]
    {
        let modelGateway = GatewayFlowScriptedModelGateway()
        let application = Agentic.application(
            "conversation-program-user-input-runtime-fixture"
        ) {
            programs {
                program(
                    ConversationUserInputProgramFixture()
                )
            }
            modelProvider(
                ConversationRuntimeModelProvider(
                    modelGateway: modelGateway
                )
            )
        }
        let runtime = try await AgenticRuntime(
            application: application
        )
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "agentic-conversation-program-user-input-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: workspaceRoot,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(
                at: workspaceRoot
            )
        }

        let conversation = try await makeLocalConversationSession(
            runtime: runtime,
            workspacePath: workspaceRoot.path,
            sessionID: "conversation-program-user-input-runtime"
        )
        let input = try JSONValue.encoding(
            ConversationUserInputProgramFixture.Input(
                value: "seed"
            )
        )
        let initial = try await conversation.invokeProgram(
            .init(
                program: ConversationUserInputProgramFixture
                    .definition.identifier,
                input: input
            ),
            submission: AgenticConversationSubmission(
                body: "/program fixture.conversation_user_input_program {\"value\":\"seed\"}",
                contents: [],
                preferredModelProfileID: "conversation-scripted",
                skillIDs: []
            )
        )
        let suspendedSnapshot = await conversation.snapshot
        let runID = try Expect.notNil(
            initial.sessionID,
            "Program user-input run identity"
        )
        let interaction = try Expect.notNil(
            initial.interactionRequest,
            "Program user-input interaction request"
        )
        let pending = try Expect.notNil(
            suspendedSnapshot.pendingUserInput,
            "Program projects user input into conversation presentation"
        )

        try Expect.equal(
            initial.outcome,
            .suspended,
            "Program ask suspends through Runtime"
        )
        try Expect.equal(
            interaction.kind,
            .user_input,
            "Program suspension remains user input rather than approval"
        )
        try Expect.equal(
            pending.interactionID,
            interaction.id,
            "Program conversation projection preserves exact interaction identity"
        )
        try Expect.equal(
            pending.runID,
            runID,
            "Program conversation projection preserves exact run identity"
        )
        try Expect.equal(
            pending.request,
            try Expect.notNil(
                interaction.requirement.pendingUserInput,
                "Program interaction semantic user-input request"
            ),
            "Program conversation projection preserves exact semantic request"
        )
        try Expect.equal(
            suspendedSnapshot.hostConsole.runs.first(
                where: { run in
                    run.id == runID
                }
            )?.state,
            .paused,
            "Program user input is a paused run, not an approval state"
        )
        try Expect.equal(
            suspendedSnapshot.hostConsole.interruptions.contains(
                where: { interruption in
                    interruption.runID == runID
                }
            ),
            false,
            "Program user input does not masquerade as an approval interruption"
        )

        try await conversation.resolveUserInput(
            interactionID: interaction.id,
            runID: runID,
            reply: .text(
                "reviewed"
            )
        )

        let completedSnapshot = await conversation.snapshot
        let completedMessage = try Expect.notNil(
            completedSnapshot.messages.last,
            "resumed Program user-input message"
        )
        let completedPresentation = try Expect.notNil(
            completedMessage.attachments.compactMap { attachment in
                if case .program(let presentation) = attachment {
                    return presentation
                }
                return nil
            }.first,
            "resumed Program user-input presentation"
        )

        try Expect.equal(
            completedSnapshot.pendingUserInput,
            nil,
            "Program user input clears after exact resume"
        )
        try Expect.equal(
            completedPresentation.outcome,
            .succeeded,
            "same Program presentation succeeds after user-input resume"
        )
        try Expect.equal(
            completedPresentation.output?.contains("seed:reviewed"),
            true,
            "Program receives the refined user-input answer"
        )
        try Expect.equal(
            await modelGateway.recordedRequests().count,
            0,
            "Program-native user input does not become a model turn"
        )

        var staleRejected = false
        do {
            try await conversation.resolveUserInput(
                interactionID: interaction.id,
                runID: runID,
                reply: .text(
                    "stale"
                )
            )
        } catch AgenticConversationSessionError.staleUserInput(_, _) {
            staleRejected = true
        }

        try Expect.equal(
            staleRejected,
            true,
            "resolved Program user-input interaction cannot be replayed"
        )

        return [
            .field(
                "initial_outcome",
                initial.outcome.rawValue
            ),
            .field(
                "final_outcome",
                completedPresentation.outcome.rawValue
            ),
            .field(
                "stale_rejected",
                String(staleRejected)
            ),
        ]
    }

    static func runProgramApprovalResume()
        async throws
        -> [TestDiagnostic]
    {
        let probe = ConversationApprovalToolProbe()
        let modelGateway = GatewayFlowScriptedModelGateway()
        let application = Agentic.application(
            "conversation-program-approval-runtime-fixture"
        ) {
            tools {
                ConversationApprovalTool(
                    probe: probe
                )
            }
            programs {
                program(
                    ConversationApprovalProgramFixture()
                )
            }
            modelProvider(
                ConversationRuntimeModelProvider(
                    modelGateway: modelGateway
                )
            )
        }
        let runtime = try await AgenticRuntime(
            application: application
        )
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "agentic-conversation-program-approval-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: workspaceRoot,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(
                at: workspaceRoot
            )
        }

        let conversation = try await makeLocalConversationSession(
            runtime: runtime,
            workspacePath: workspaceRoot.path,
            sessionID: "conversation-program-approval-runtime"
        )
        let input = try JSONValue.encoding(
            ConversationApprovalProgramFixture.Input(
                value: "approved"
            )
        )
        let submission = AgenticConversationSubmission(
            body: "/program fixture.conversation_approval_program {\"value\":\"approved\"}",
            contents: [],
            preferredModelProfileID: "conversation-scripted",
            skillIDs: [],
            autonomyMode: .auto_observe
        )
        let initial = try await conversation.invokeProgram(
            .init(
                program: ConversationApprovalProgramFixture
                    .definition.identifier,
                input: input
            ),
            submission: submission
        )
        let suspendedSnapshot = await conversation.snapshot
        let runID = try Expect.notNil(
            initial.sessionID,
            "suspended Program run identity"
        )
        let interruption = try Expect.notNil(
            suspendedSnapshot.hostConsole.interruptions.first(
                where: { interruption in
                    interruption.runID == runID
                }
            ),
            "suspended Program approval interruption"
        )
        let suspendedMessage = try Expect.notNil(
            suspendedSnapshot.messages.last,
            "suspended Program assistant message"
        )
        let suspendedPresentation = try Expect.notNil(
            suspendedMessage.attachments.compactMap { attachment in
                if case .program(let presentation) = attachment {
                    return presentation
                }
                return nil
            }.first,
            "suspended Program presentation"
        )

        try Expect.equal(
            initial.outcome,
            .suspended,
            "Host-backed Program reaches a genuine Runtime suspension"
        )
        try Expect.equal(
            await probe.count(),
            0,
            "bounded Program tool does not execute before approval"
        )
        try Expect.equal(
            suspendedPresentation.outcome,
            .suspended,
            "conversation Program attachment presents suspension"
        )
        try Expect.equal(
            suspendedPresentation.steps.last?.suspended,
            true,
            "suspended semantic Program step is presented explicitly"
        )
        try Expect.equal(
            suspendedPresentation.steps.last?.marker,
            "◉",
            "suspended Program step uses the active marker"
        )
        try Expect.equal(
            suspendedSnapshot.hostConsole.runs.first(
                where: { run in
                    run.id == runID
                }
            )?.state,
            .awaitingApproval,
            "Program suspension reuses existing Host run-review approval presentation"
        )
        try Expect.equal(
            suspendedMessage.attachments.contains(
                where: { attachment in
                    if case .run(let attachedRunID) = attachment {
                        return attachedRunID == runID
                    }
                    return false
                }
            ),
            true,
            "suspended Program exposes existing run-review attachment"
        )

        try await conversation.resolveConversationAction(
            interruptionID: interruption.id,
            runID: interruption.runID,
            stepID: interruption.stepID,
            action: .approve
        )

        let completedSnapshot = await conversation.snapshot
        let completedMessage = try Expect.notNil(
            completedSnapshot.messages.last,
            "resumed Program assistant message"
        )
        let completedPresentation = try Expect.notNil(
            completedMessage.attachments.compactMap { attachment in
                if case .program(let presentation) = attachment {
                    return presentation
                }
                return nil
            }.first,
            "resumed Program presentation"
        )

        try Expect.equal(
            await probe.count(),
            1,
            "approved Program tool executes exactly once through Host resume"
        )
        try Expect.equal(
            completedPresentation.outcome,
            .succeeded,
            "same Program attachment becomes succeeded after resume"
        )
        try Expect.equal(
            completedPresentation.output?.contains("approved"),
            true,
            "resumed Program output reaches conversation presentation"
        )
        try Expect.equal(
            completedMessage.attachments.contains(
                where: { attachment in
                    if case .run(let attachedRunID) = attachment {
                        return attachedRunID == runID
                    }
                    return false
                }
            ),
            false,
            "completed Program no longer exposes pending run-review attachment"
        )
        try Expect.equal(
            completedSnapshot.hostConsole.interruptions.contains(
                where: { interruption in
                    interruption.runID == runID
                }
            ),
            false,
            "resolved Program approval is removed from Host console presentation"
        )
        try Expect.equal(
            await modelGateway.recordedRequests().count,
            0,
            "direct Program approval/resume does not become a model turn"
        )

        return [
            .field(
                "initial_outcome",
                initial.outcome.rawValue
            ),
            .field(
                "tool_executions",
                String(await probe.count())
            ),
            .field(
                "final_outcome",
                completedPresentation.outcome.rawValue
            ),
        ]
    }

    static func runProgramInvocation()
        async throws
        -> [TestDiagnostic]
    {
        let modelGateway = GatewayFlowScriptedModelGateway()
        let application = Agentic.application(
            "conversation-program-runtime-fixture"
        ) {
            programs {
                program(
                    ConversationProgramFixture()
                )
            }
            modelProvider(
                ConversationRuntimeModelProvider(
                    modelGateway: modelGateway
                )
            )
        }
        let runtime = try await AgenticRuntime(
            application: application
        )
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "agentic-conversation-program-runtime-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: workspaceRoot,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(
                at: workspaceRoot
            )
        }

        let conversation = try await makeLocalConversationSession(
            runtime: runtime,
            workspacePath: workspaceRoot.path,
            sessionID: "conversation-program-runtime"
        )
        let initialSnapshot = await conversation.snapshot
        let input = try JSONValue.encoding(
            ConversationProgramFixture.Input(
                value: "conversation"
            )
        )
        let submission = AgenticConversationSubmission(
            body: "/program fixture.conversation_program {\"value\":\"conversation\"}",
            contents: [],
            preferredModelProfileID: "conversation-scripted",
            skillIDs: []
        )
        let record = try await conversation.invokeProgram(
            .init(
                program: ConversationProgramFixture.definition.identifier,
                input: input
            ),
            submission: submission
        )
        let output = try (record.output ?? .null).decode(
            ConversationProgramFixture.Output.self
        )
        let requests = await modelGateway.recordedRequests()
        let conversationSnapshot = await conversation.snapshot
        let attachment = conversationSnapshot.messages.last?
            .attachments.first
        let programPresentation: AgenticConversationProgramExecutionPresentation?

        if case .program(let presentation)? = attachment {
            programPresentation = presentation
        } else {
            programPresentation = nil
        }

        let presentation = try Expect.notNil(
            programPresentation,
            "conversation Program execution presentation"
        )

        try Expect.equal(
            initialSnapshot.programs.count,
            1,
            "conversation snapshot discovers installed Programs"
        )
        try Expect.equal(
            initialSnapshot.programs.first?.identifier,
            ConversationProgramFixture.definition.identifier,
            "conversation snapshot preserves Program identity"
        )
        try Expect.equal(
            record.outcome,
            ProgramExecutionOutcome.succeeded,
            "conversation delegates Program execution to Runtime through Host"
        )
        try Expect.equal(
            output.value,
            "echo:conversation",
            "conversation receives typed Program output through erased Host transport"
        )
        try Expect.equal(
            requests.count,
            0,
            "direct conversation Program invocation does not become a model request or fake tool call"
        )
        try Expect.equal(
            conversationSnapshot.messages.count,
            2,
            "conversation records user command and Program result"
        )
        try Expect.equal(
            presentation.program,
            ConversationProgramFixture.definition.identifier,
            "Program attachment preserves semantic Program identity"
        )
        try Expect.equal(
            presentation.outcome,
            AgenticConversationProgramExecutionOutcome.succeeded,
            "Program attachment preserves execution outcome"
        )
        try Expect.equal(
            presentation.output?.contains("echo:conversation"),
            true,
            "Program attachment renders erased output"
        )
        try Expect.equal(
            conversationSnapshot.messages.last?.body,
            "Conversation Program completed.",
            "conversation renders completed Program result as assistant output"
        )

        return [
            .field(
                "programs",
                String(initialSnapshot.programs.count)
            ),
            .field(
                "program",
                presentation.program.rawValue
            ),
            .field(
                "outcome",
                presentation.outcome.rawValue
            ),
            .field(
                "output",
                output.value
            ),
            .field(
                "model_requests",
                String(requests.count)
            ),
        ]
    }

    static func run() async throws -> [TestDiagnostic] {
        let findCall = ToolCall(
            id: "conversation-find-tools-call",
            tool: Standard.Tools.FindCapabilities.definition.identifier,
            input: .object([
                "arguments": try JSONValue.encoding(
                    Standard.Tools.FindCapabilities.Input(
                        query: GatewayFlowEchoTool.identifier.rawValue,
                        maximumResults: 1
                    )
                ),
            ])
        )
        let echoCall = ToolCall(
            id: "conversation-echo-call",
            tool: GatewayFlowEchoTool.identifier,
            input: .object([
                "arguments": try JSONValue.encoding(
                    GatewayFlowEchoToolInput(
                        text: "conversation payload"
                    )
                ),
            ])
        )
        let findResponse = AgentResponse(
            message: .init(
                role: .assistant,
                content: .init(
                    blocks: [
                        .tool_call(
                            findCall
                        ),
                    ]
                )
            ),
            stopReason: .tool_use
        )
        let echoResponse = AgentResponse(
            message: .init(
                role: .assistant,
                content: .init(
                    blocks: [
                        .tool_call(
                            echoCall
                        ),
                    ]
                )
            ),
            stopReason: .tool_use
        )
        let finalResponse = AgentResponse(
            message: .init(
                role: .assistant,
                text: "conversation tool ok"
            ),
            stopReason: .end_turn
        )
        let bufferedResponse = AgentResponse(
            message: .init(
                role: .assistant,
                text: "conversation buffered ok"
            ),
            stopReason: .end_turn
        )
        let scriptedAdapter = GatewayFlowScriptedModelGateway(
            bufferedResponses: [
                bufferedResponse,
            ],
            streamBatches: [
                [
                    .toolcall(
                        findCall
                    ),
                    .completed(
                        findResponse
                    ),
                ],
                [
                    .toolcall(
                        echoCall
                    ),
                    .completed(
                        echoResponse
                    ),
                ],
                [
                    .completed(
                        finalResponse
                    ),
                ],
            ]
        )
        let application = Agentic.application(
            "conversation-runtime-fixture"
        ) {
            install(
                Catalog(
                    declarations: [
                        .tool(GatewayFlowEchoTool.definition),
                        .tool(Standard.Tools.FindCapabilities.definition),
                    ]
                )
            )
            tools {
                GatewayFlowEchoTool()
                Standard.Tools.FindCapabilities()
            }
            modelProvider(
                ConversationRuntimeModelProvider(
                    modelGateway: scriptedAdapter
                )
            )
        }
        let runtime = try await AgenticRuntime(
            application: application
        )
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "agentic-conversation-runtime-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: workspaceRoot,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: workspaceRoot)
        }

        let conversation = try await makeLocalConversationSession(
            runtime: runtime,
            workspacePath: workspaceRoot.path,
            sessionID: "conversation-runtime"
        )
        let submission = AgenticConversationSubmission(
            body: "Use the echo tool.",
            origin: .transcribed,
            contents: [
                .init(
                    id: "pinned-1",
                    kind: .transcribed,
                    title: "Pinned note",
                    summary: "one note",
                    body: "exact pinned body"
                ),
            ],
            preferredModelProfileID: "conversation-scripted",
            skillIDs: [],
            toolExposure: .discovery,
            responseDelivery: .stream,
            invocationoptions: .init(
                timeoutseconds: 600
            )
        )
        let result = try await conversation.submit(
            submission
        )
        let requests = await scriptedAdapter.recordedRequests()
        let conversationSnapshot = await conversation.snapshot
        let retainedInput = await conversation.input(
            for: result.sessionID
        )
        let retainedOutput = await conversation.output(
            for: result.sessionID
        )
        let run: AgenticHostConsoleRunPresentation = try Expect.notNil(
            conversationSnapshot.hostConsole.runs.first,
            "attached host run"
        )
        let assistant: AgenticConversationMessagePresentation = try Expect.notNil(
            conversationSnapshot.messages.last,
            "assistant message"
        )

        try Expect.equal(
            result.response?.message.content.text,
            "conversation tool ok",
            "final response"
        )
        try Expect.equal(
            AgentRunnerConfiguration.default.autonomyMode,
            AutonomyMode.auto_observe,
            "runner configuration defaults to auto observe"
        )
        try Expect.equal(
            requests.count,
            3,
            "model request count"
        )
        try Expect.equal(
            requests.compactMap { request in
                request.invocationoptions?.timeoutseconds
            },
            [
                600,
                600,
                600,
            ],
            "conversation invocation timeout survives every model turn"
        )
        try Expect.equal(
            requests[0].tools.map(
                \.name
            ),
            [
                Standard.Tools.FindCapabilities.definition.identifier.rawValue,
            ],
            "conversation begins with discovery visible while ordinary available tools remain hidden"
        )
        try Expect.equal(
            requests[1].tools.map(
                \.name
            ),
            [
                GatewayFlowEchoTool.identifier.rawValue,
                Standard.Tools.FindCapabilities.definition.identifier.rawValue,
            ],
            "discovered tool is advertised on the next turn"
        )
        try Expect.equal(
            requests[2].tools.map(
                \.name
            ),
            [
                GatewayFlowEchoTool.identifier.rawValue,
                Standard.Tools.FindCapabilities.definition.identifier.rawValue,
            ],
            "discovered tool remains exposed for the run"
        )
        try Expect.equal(
            requests.first?.metadata["conversation_input_origin"],
            "transcribed",
            "conversation input origin metadata"
        )
        try Expect.equal(
            requests.first?.metadata["conversation_tool_exposure"],
            "discovery",
            "conversation tool exposure metadata"
        )
        try Expect.equal(
            requests.first?.metadata["conversation_response_delivery"],
            "stream",
            "conversation response delivery metadata"
        )
        try Expect.equal(
            requests.first?.metadata["conversation_autonomy_mode"],
            AutonomyMode.auto_observe.rawValue,
            "conversation autonomy metadata"
        )
        try Expect.equal(
            conversationSnapshot.selectedResponseDelivery,
            AgentModelResponseDelivery.stream,
            "conversation retains streaming response delivery"
        )
        try Expect.equal(
            conversationSnapshot.selectedInvocationOptions.timeoutseconds,
            600,
            "conversation retains invocation timeout selection"
        )
        try Expect.equal(
            conversationSnapshot.selectedToolExposure,
            AgenticConversationToolExposure.discovery,
            "conversation retains discovery exposure selection"
        )
        try Expect.equal(
            conversationSnapshot.selectedAutonomyMode,
            AutonomyMode.auto_observe,
            "conversation retains auto-observe autonomy selection"
        )
        try Expect.contains(
            requests.first?.messages.first?.content.text ?? "",
            "Only find_capabilities is exposed initially.",
            "discovery system prompt"
        )
        try Expect.equal(
            assistant.body,
            "conversation tool ok",
            "assistant presentation"
        )
        try Expect.equal(
            assistant.attachments,
            [
                AgenticConversationAttachmentPresentation.run(
                    runID: result.sessionID
                ),
            ],
            "assistant run attachment"
        )
        try Expect.equal(
            run.state,
            AgenticHostConsoleRunState.completed,
            "attached run state"
        )
        try Expect.equal(
            run.steps.map(
                \.title
            ),
            [
                Standard.Tools.FindCapabilities.definition.identifier.rawValue,
                GatewayFlowEchoTool.identifier.rawValue,
            ],
            "attached run records discovery then execution"
        )
        try Expect.equal(
            run.steps.last?.state,
            Optional(
                AgenticHostConsoleStepState.completed
            ),
            "attached tool outcome"
        )
        try Expect.equal(
            run.summary,
            run.steps.last?.detail,
            "attached run summarizes operational work instead of assistant prose"
        )
        try Expect.contains(
            retainedInput ?? "",
            "# Transcribed content: Pinned note",
            "retained transcribed content heading"
        )
        try Expect.contains(
            retainedInput ?? "",
            "exact pinned body",
            "retained run input"
        )
        try Expect.contains(
            retainedOutput ?? "",
            "\"sessionID\" : \"conversation-runtime-turn-1\"",
            "retained run output"
        )
        try Expect.equal(
            result.toolUses.map(\.toolCall.id),
            [
                findCall.id,
                echoCall.id,
            ],
            "run result retains exact model tool calls"
        )

        let documents =
            conversationSnapshot.hostConsole.documents
        let findDetails = documents.first {
            $0.stepID == findCall.id
                && $0.kind == .details
        }
        let echoDetails = documents.first {
            $0.stepID == echoCall.id
                && $0.kind == .details
        }
        let echoStdout = documents.first {
            $0.stepID == echoCall.id
                && $0.kind == .stdout
        }

        try Expect.contains(
            findDetails?.body ?? "",
            "\"maximumResults\"",
            "find_capabilities details expose exact model input"
        )
        try Expect.contains(
            findDetails?.body ?? "",
            GatewayFlowEchoTool.identifier.rawValue,
            "find_capabilities details expose exact discovery query"
        )
        try Expect.contains(
            echoDetails?.body ?? "",
            "\"text\" : \"conversation payload\"",
            "echo details expose exact model input"
        )
        try Expect.contains(
            echoDetails?.body ?? "",
            "Echoed conversation payload.",
            "echo details expose semantic result projection"
        )
        try Expect.contains(
            echoDetails?.body ?? "",
            "echo detail: conversation payload",
            "echo details expose non-stream observation"
        )
        try Expect.contains(
            echoStdout?.body ?? "",
            "echo stdout: conversation payload",
            "echo stdout is projected as a dedicated stream document"
        )

        try Expect.equal(
            findDetails?.structuredBody == nil,
            false,
            "find_capabilities details retain semantic structured content"
        )
        try Expect.equal(
            echoDetails?.structuredBody == nil,
            false,
            "echo details retain semantic structured content"
        )

        let structuredEncoder = JSONEncoder()
        structuredEncoder.outputFormatting = [
            .sortedKeys,
        ]
        let findStructuredText = try String(
            decoding: structuredEncoder.encode(
                findDetails?.structuredBody
            ),
            as: UTF8.self
        )
        let echoStructuredText = try String(
            decoding: structuredEncoder.encode(
                echoDetails?.structuredBody
            ),
            as: UTF8.self
        )

        try Expect.contains(
            findStructuredText,
            "agentic.tool.input",
            "find_capabilities structured details preserve semantic input role"
        )
        try Expect.contains(
            findStructuredText,
            "maximumResults",
            "find_capabilities structured details preserve exact input"
        )
        try Expect.contains(
            findStructuredText,
            GatewayFlowEchoTool.identifier.rawValue,
            "find_capabilities structured details preserve discovery query"
        )
        try Expect.contains(
            echoStructuredText,
            "agentic.tool.result",
            "echo structured details preserve semantic result role"
        )
        try Expect.contains(
            echoStructuredText,
            "Echoed conversation payload.",
            "echo structured details preserve result summary"
        )
        try Expect.contains(
            echoStructuredText,
            "echo detail: conversation payload",
            "echo structured details preserve non-stream observation"
        )

        let bufferedResult = try await conversation.submit(
            AgenticConversationSubmission(
                body: "Use buffered delivery.",
                contents: [],
                preferredModelProfileID: "conversation-scripted",
                skillIDs: [],
                toolExposure: .discovery,
                responseDelivery: .buffered
            )
        )
        let requestsAfterBuffered = await scriptedAdapter.recordedRequests()
        let snapshotAfterBuffered = await conversation.snapshot

        try Expect.equal(
            bufferedResult.response?.message.content.text,
            "conversation buffered ok",
            "buffered conversation response"
        )
        try Expect.equal(
            requestsAfterBuffered.count,
            4,
            "buffered conversation adds one model request"
        )
        try Expect.equal(
            requestsAfterBuffered.last?.metadata[
                "conversation_response_delivery"
            ],
            "buffered",
            "buffered response delivery metadata"
        )
        try Expect.equal(
            snapshotAfterBuffered.selectedResponseDelivery,
            AgentModelResponseDelivery.buffered,
            "buffered selection remains visible in conversation state"
        )

        let bufferedAssistant:
            AgenticConversationMessagePresentation = try Expect.notNil(
                snapshotAfterBuffered.messages.last,
                "buffered assistant presentation"
            )
        let bufferedRun:
            AgenticHostConsoleRunPresentation = try Expect.notNil(
                snapshotAfterBuffered.hostConsole.runs.first(where: { run in
                    run.id == bufferedResult.sessionID
                }),
                "buffered host run"
            )

        try Expect.equal(
            bufferedAssistant.attachments,
            [],
            "response-only conversation never needs a run attachment"
        )
        try Expect.equal(
            bufferedRun.steps.isEmpty,
            true,
            "response-only conversation does not synthesize a model response stage"
        )

        await conversation.preferModel(
            "conversation-buffered"
        )
        let nonStreamingModelSnapshot = await conversation.snapshot

        try Expect.equal(
            nonStreamingModelSnapshot.selectedResponseDelivery,
            AgentModelResponseDelivery.buffered,
            "non-streaming model coerces response delivery to buffered"
        )

        await conversation.selectResponseDelivery(
            .stream
        )
        let rejectedStreamingSnapshot = await conversation.snapshot

        try Expect.equal(
            rejectedStreamingSnapshot.selectedResponseDelivery,
            AgentModelResponseDelivery.buffered,
            "non-streaming model rejects streaming selection"
        )

        await conversation.preferModel(
            "conversation-scripted"
        )
        await conversation.selectResponseDelivery(
            .stream
        )
        let restoredStreamingSnapshot = await conversation.snapshot

        try Expect.equal(
            restoredStreamingSnapshot.selectedResponseDelivery,
            AgentModelResponseDelivery.stream,
            "stream-capable model allows streaming selection"
        )

        try await proveEmbeddedApprovalAction(
            workspaceRoot: workspaceRoot
        )
        try await proveEmbeddedWorkspaceAccessAction(
            workspaceRoot: workspaceRoot
        )

        return [
            .field(
                "workspace",
                conversationSnapshot.workspace
            ),
            .field(
                "model_calls",
                String(
                    requests.count
                )
            ),
            .field(
                "run",
                run.id
            ),
            .field(
                "steps",
                String(
                    run.steps.count
                )
            ),
            GatewayRuntimeFlowDiagnostics.events(
                result.events
            ),
        ]
    }

    private static func proveEmbeddedApprovalAction(
        workspaceRoot: URL
    ) async throws {
        let probe = ConversationApprovalToolProbe()
        let call = ToolCall(
            id: "conversation-approval-call",
            tool: ConversationApprovalTool.identifier,
            input: .object([
                "arguments": try JSONValue.encoding(
                    GatewayFlowEchoToolInput(
                        text: "approved payload"
                    )
                ),
            ])
        )
        let toolResponse = AgentResponse(
            message: .init(
                role: .assistant,
                content: .init(
                    blocks: [
                        .tool_call(
                            call
                        ),
                    ]
                )
            ),
            stopReason: .tool_use
        )
        let finalResponse = AgentResponse(
            message: .init(
                role: .assistant,
                text: "conversation approval resumed"
            ),
            stopReason: .end_turn
        )
        let adapter = GatewayFlowScriptedModelGateway(
            streamBatches: [
                [
                    .toolcall(
                        call
                    ),
                    .completed(
                        toolResponse
                    ),
                ],
                [
                    .completed(
                        finalResponse
                    ),
                ],
            ]
        )
        let application = Agentic.application(
            "conversation-approval-runtime-fixture"
        ) {
            tools {
                ConversationApprovalTool(
                    probe: probe
                )
            }
            modelProvider(
                ConversationRuntimeModelProvider(
                    modelGateway: adapter
                )
            )
        }
        let runtime = try await AgenticRuntime(
            application: application
        )
        let conversation = try await makeLocalConversationSession(
            runtime: runtime,
            workspacePath: workspaceRoot.path,
            sessionID: "conversation-approval-runtime"
        )
        let initial = try await conversation.submit(
            .init(
                body: "Request the bounded mutation.",
                contents: [],
                preferredModelProfileID: "conversation-scripted",
                skillIDs: [],
                toolExposure: .all,
                responseDelivery: .stream,
                autonomyMode: .auto_observe
            )
        )
        let suspendedSnapshot = await conversation.snapshot
        let interruption: AgenticHostConsoleInterruptionPresentation = try Expect.notNil(
            suspendedSnapshot.hostConsole.interruptions.first(
                where: { interruption in
                    interruption.runID == initial.sessionID
                }
            ),
            "conversation approval interruption"
        )

        try Expect.equal(
            initial.isAwaitingApproval,
            true,
            "conversation bounded mutation suspends for approval"
        )
        try Expect.equal(
            await probe.count(),
            0,
            "conversation bounded mutation does not execute before approval"
        )
        try Expect.equal(
            interruption.stepID,
            call.id,
            "conversation approval interruption retains exact tool call"
        )
        try Expect.equal(
            interruption.actions,
            [
                AgenticHostConsoleAction.approve,
                .deny,
                .skip,
            ],
            "conversation approval interruption exposes resolvable actions"
        )
        try Expect.equal(
            suspendedSnapshot.hostConsole.documents.contains(
                where: { document in
                    document.runID == initial.sessionID
                        && document.stepID == call.id
                        && document.kind == .details
                }
            ),
            true,
            "conversation approval exposes staged tool details"
        )

        let diffDocument: AgenticHostConsoleDocumentPresentation = try Expect.notNil(
            suspendedSnapshot.hostConsole.documents.first(
                where: { document in
                    document.runID == initial.sessionID
                        && document.stepID == call.id
                        && document.kind == .diff
                }
            ),
            "conversation approval diff document"
        )

        try Expect.contains(
            diffDocument.body,
            "1:-",
            "conversation approval diff uses Difference old-line gutter"
        )
        try Expect.contains(
            diffDocument.body,
            "-:1",
            "conversation approval diff uses Difference new-line gutter"
        )
        try Expect.contains(
            diffDocument.body,
            "\u{001B}[",
            "conversation approval diff retains Terminal Difference styling"
        )

        let resumed = try await conversation.resolveHostAction(
            interruptionID: interruption.id,
            runID: interruption.runID,
            stepID: interruption.stepID,
            action: .approve
        )
        let completedSnapshot = await conversation.snapshot
        let completedRun: AgenticHostConsoleRunPresentation = try Expect.notNil(
            completedSnapshot.hostConsole.runs.first(
                where: { run in
                    run.id == resumed.sessionID
                }
            ),
            "completed conversation approval run"
        )

        try Expect.equal(
            resumed.isCompleted,
            true,
            "approved conversation run resumes to completion"
        )
        try Expect.equal(
            await probe.count(),
            1,
            "approved conversation bounded mutation executes exactly once"
        )
        try Expect.equal(
            completedRun.state,
            AgenticHostConsoleRunState.completed,
            "approved conversation run projects completed state"
        )
        try Expect.equal(
            completedSnapshot.hostConsole.interruptions.contains(
                where: { interruption in
                    interruption.runID == resumed.sessionID
                }
            ),
            false,
            "resolved conversation approval interruption is removed"
        )
        try Expect.equal(
            completedSnapshot.messages.last?.body,
            Optional("conversation approval resumed"),
            "approved conversation run updates the attached assistant message"
        )
        try Expect.equal(
            await adapter.recordedRequests().count,
            2,
            "approved conversation run continues the model after tool execution"
        )
    }

    private static func proveEmbeddedWorkspaceAccessAction(
        workspaceRoot: URL
    ) async throws {
        try await proveEmbeddedWorkspaceAccessResolution(
            workspaceRoot: workspaceRoot,
            suffix: "grant",
            action: .grant_for_turn,
            finalText: "conversation workspace access granted"
        )
        try await proveEmbeddedWorkspaceAccessResolution(
            workspaceRoot: workspaceRoot,
            suffix: "deny",
            action: .deny,
            finalText: "conversation workspace access denied"
        )
    }

    private static func proveEmbeddedWorkspaceAccessResolution(
        workspaceRoot: URL,
        suffix: String,
        action: AgenticHostConsoleAction,
        finalText: String
    ) async throws {
        let externalRoot = workspaceRoot
            .deletingLastPathComponent()
            .appendingPathComponent(
                "conversation-workspace-access-\(suffix)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: externalRoot,
            withIntermediateDirectories: true
        )

        defer {
            try? FileManager.default.removeItem(
                at: externalRoot
            )
        }

        let rootID = "conversation_workspace_access_\(suffix)"
        let reason = "Exercise conversation workspace-access \(suffix) resolution."
        let call = ToolCall(
            id: "conversation-workspace-access-\(suffix)-call",
            tool: SystemIO.Tools.RequestPathGrant.definition.identifier,
            input: .object([
                "arguments": try JSONValue.encoding(
                    SystemIO.Tools.RequestPathGrant.Input(
                        requestedRootPath: externalRoot.path,
                        suggestedRootID: rootID,
                        reason: reason
                    )
                ),
            ])
        )
        let toolResponse = AgentResponse(
            message: .init(
                role: .assistant,
                content: .init(
                    blocks: [
                        .tool_call(
                            call
                        ),
                    ]
                )
            ),
            stopReason: .tool_use
        )
        let finalResponse = AgentResponse(
            message: .init(
                role: .assistant,
                text: finalText
            ),
            stopReason: .end_turn
        )
        let adapter = GatewayFlowScriptedModelGateway(
            streamBatches: [
                [
                    .toolcall(
                        call
                    ),
                    .completed(
                        toolResponse
                    ),
                ],
                [
                    .completed(
                        finalResponse
                    ),
                ],
            ]
        )
        let application = Agentic.application(
            AgenticApplicationIdentifier(
                rawValue: "conversation-workspace-access-\(suffix)-fixture"
            )
        ) {
            tools {
                CoreWorkspaceToolSet()
            }
            modelProvider(
                ConversationRuntimeModelProvider(
                    modelGateway: adapter
                )
            )
        }
        let runtime = try await AgenticRuntime(
            application: application
        )
        let conversation = try await makeLocalConversationSession(
            runtime: runtime,
            workspacePath: workspaceRoot.path,
            sessionID: "conversation-workspace-access-\(suffix)"
        )
        let submission = AgenticConversationSubmission(
            body: "Request temporary workspace access.",
            contents: [],
            preferredModelProfileID: "conversation-scripted",
            skillIDs: [],
            toolExposure: .all,
            responseDelivery: .stream,
            autonomyMode: .auto_observe
        )
        let initial: AgentRunResult = try await conversation.submit(
            submission
        )
        let suspendedSnapshot = await conversation.snapshot
        let interactionRequest: AgentInteraction.Request = try Expect.notNil(
            initial.interactionRequest,
            "conversation workspace-access interaction request"
        )
        let interruptionMatch: AgenticHostConsoleInterruptionPresentation? =
            suspendedSnapshot.hostConsole.interruptions.first { interruption in
                interruption.runID == initial.sessionID
                    && interruption.kind ==
                        AgenticHostConsoleInterruptionKind.workspace_access
            }
        let interruption: AgenticHostConsoleInterruptionPresentation =
            try Expect.notNil(
                interruptionMatch,
                "conversation workspace-access interruption"
            )
        let detailsMatch: AgenticHostConsoleDocumentPresentation? =
            suspendedSnapshot.hostConsole.documents.first { document in
                document.runID == initial.sessionID
                    && document.stepID == call.id
                    && document.kind ==
                        AgenticHostConsoleDocumentKind.details
            }
        let details: AgenticHostConsoleDocumentPresentation =
            try Expect.notNil(
                detailsMatch,
                "conversation workspace-access details"
            )

        try Expect.equal(
            initial.isAwaitingWorkspaceAccess,
            true,
            "conversation path request suspends for workspace access"
        )
        try Expect.equal(
            interruption.id,
            interactionRequest.id,
            "conversation workspace interruption retains Runtime interaction identity"
        )
        try Expect.equal(
            interruption.stepID,
            call.id,
            "conversation workspace interruption retains exact tool call"
        )
        try Expect.equal(
            interruption.actions,
            [
                AgenticHostConsoleAction.grant_for_turn,
                .grant_for_session,
                .deny,
            ],
            "conversation workspace interruption exposes lifetime-aware actions"
        )
        try Expect.contains(
            details.body,
            rootID,
            "conversation workspace details expose resolved root identity"
        )
        try Expect.contains(
            details.body,
            reason,
            "conversation workspace details expose request rationale"
        )

        let resumed = try await conversation.resolveHostAction(
            interruptionID: interruption.id,
            runID: interruption.runID,
            stepID: interruption.stepID,
            action: action
        )
        let completedSnapshot = await conversation.snapshot
        let completedRun: AgenticHostConsoleRunPresentation = try Expect.notNil(
            completedSnapshot.hostConsole.runs.first(
                where: { run in
                    run.id == resumed.sessionID
                }
            ),
            "completed conversation workspace-access run"
        )

        try Expect.equal(
            resumed.isCompleted,
            true,
            "resolved conversation workspace-access run resumes to completion"
        )
        try Expect.equal(
            completedRun.state,
            AgenticHostConsoleRunState.completed,
            "resolved conversation workspace-access run projects completed state"
        )
        try Expect.equal(
            completedSnapshot.hostConsole.interruptions.contains(
                where: { interruption in
                    interruption.runID == resumed.sessionID
                }
            ),
            false,
            "resolved conversation workspace-access interruption is removed"
        )
        try Expect.equal(
            completedSnapshot.messages.last?.body,
            Optional(finalText),
            "resolved conversation workspace-access run updates the attached assistant message"
        )
        try Expect.equal(
            await adapter.recordedRequests().count,
            2,
            "resolved conversation workspace-access run continues the model"
        )
    }

    static func runRecoveredToolErrorProjection() async throws -> [TestDiagnostic] {
        let result = AgentRunResult.completed(
            sessionID: "conversation-recovered-tool-error-runtime",
            response: AgentResponse(
                message: .init(
                    role: .assistant,
                    text: "conversation recovered"
                ),
                stopReason: .end_turn
            ),
            state: .init(
                iteration: 4
            ),
            events: [
                .init(
                    kind: .tool_error,
                    iteration: 1,
                    toolCallID: "conversation-hidden-tool-call",
                    toolName: GatewayFlowEchoTool.identifier.rawValue,
                    summary: "Tool was rejected before discovery."
                ),
                .init(
                    kind: .tool_result,
                    iteration: 3,
                    toolCallID: "conversation-recovered-tool-call",
                    toolName: GatewayFlowEchoTool.identifier.rawValue,
                    summary: "Tool completed after discovery."
                ),
            ]
        )
        let projection = AgenticConversationRunProjection.project(
            result,
            title: "Recovered conversation"
        )

        try Expect.equal(
            result.isCompleted,
            true,
            "historical tool error does not change the structured completed outcome"
        )
        try Expect.equal(
            result.events.contains(
                where: { event in
                    event.kind == .tool_error
                }
            ),
            true,
            "historical tool error remains available as run evidence"
        )
        try Expect.equal(
            projection.run.state,
            AgenticHostConsoleRunState.completed,
            "completed result projects a completed host run despite historical tool error"
        )
        try Expect.equal(
            projection.run.steps.count,
            2,
            "projection retains historical tool error and recovered tool result steps"
        )

        return [
            .field(
                "run_state",
                projection.run.state.rawValue
            ),
            .field(
                "history_steps",
                String(
                    projection.run.steps.count
                )
            ),
        ]
    }

    static func runFailureObservability() async throws -> [TestDiagnostic] {
        let persistedCall = ToolCall(
            id: "failed-run-persisted-echo",
            tool: GatewayFlowEchoTool.identifier,
            input: try JSONValue.encoding(
                GatewayFlowEchoToolInput(
                    text: "persisted failure payload"
                )
            )
        )
        let persistedResponse = AgentResponse(
            message: .init(
                role: .assistant,
                content: .init(
                    blocks: [
                        .tool_call(
                            persistedCall
                        ),
                    ]
                )
            ),
            stopReason: .tool_use
        )
        let persistedAdapter = GatewayFlowScriptedModelGateway(
            streamBatches: [
                [
                    .toolcall(
                        persistedCall
                    ),
                    .completed(
                        persistedResponse
                    ),
                ],
            ]
        )
        let sessionsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "agentic-runtime-failed-run-\(UUID().uuidString)",
                isDirectory: true
            )
        let historyStore = FileHistoryStore(
            sessionsdir: sessionsDirectory
        )
        defer {
            try? FileManager.default.removeItem(
                at: sessionsDirectory
            )
        }
        let persistedSessionID = "runtime-failed-run-persisted"
        let persistedRunner = AgentRunner(
            model: .init(
                invoker: GatewayFlowModelInvoker(
                    gateway: persistedAdapter,
                    model: "scripted"
                )
            ),
            configuration: .init(
                runLimits: .init(iterations: 1),
                historyPersistenceMode: .checkpointmutation,
                responseDelivery: .stream
            ),
            tooling: .init(
                registry: try ToolRegistry {
                    GatewayFlowEchoTool()
                }
            ),
            recording: .init(
                historyStore: historyStore
            )
        )
        let persistedResult = try await persistedRunner.run(
            AgentRequest(
                messages: [
                    .init(
                        role: .user,
                        text: "Keep using the echo tool."
                    ),
                ]
            ),
            sessionID: persistedSessionID
        )
        let persistedCheckpoint = try Expect.notNil(
            try await historyStore.loadCheckpoint(
                sessionID: persistedSessionID
            ),
            "failed checkpoint persisted"
        )
        let restoredResult = try await persistedRunner.resume(
            sessionID: persistedSessionID
        )

        try Expect.equal(
            persistedResult.isAwaitingRunLimit,
            true,
            "iteration limit suspends the run"
        )
        try Expect.equal(
            persistedResult.failure,
            nil,
            "iteration limit is not a run failure"
        )
        try Expect.equal(
            persistedResult.state.iteration,
            1,
            "run-limit suspension retains loop state"
        )
        try Expect.equal(
            persistedResult.events.last?.kind,
            Optional(AgentRunEvent.Kind.run_limit_reached),
            "run-limit suspension records a supervisory event"
        )
        try Expect.equal(
            persistedCheckpoint.phase,
            AgentHistoryPhase.suspended,
            "run-limit checkpoint remains resumable"
        )
        try Expect.equal(
            persistedCheckpoint.failure,
            nil,
            "run-limit checkpoint stores no failure"
        )
        try Expect.equal(
            restoredResult.pendingRunLimit,
            persistedResult.pendingRunLimit,
            "loading a suspended session preserves run-limit exhaustion"
        )
        try Expect.equal(
            restoredResult.events,
            persistedResult.events,
            "loading a suspended session preserves run events"
        )

        let bufferedFailureAdapter = GatewayFlowScriptedModelGateway()
        let bufferedFailureSessionID = "runtime-model-invocation-failed-buffered"
        let bufferedFailureRunner = AgentRunner(
            model: .init(
                invoker: GatewayFlowModelInvoker(
                    gateway: bufferedFailureAdapter,
                    model: "scripted"
                )
            ),
            configuration: .init(
                runLimits: .init(iterations: 2),
                historyPersistenceMode: .checkpointmutation,
                responseDelivery: .buffered
            ),
            recording: .init(
                historyStore: historyStore
            )
        )
        let bufferedFailureResult = try await bufferedFailureRunner.run(
            AgentRequest(
                messages: [
                    .init(
                        role: .user,
                        text: "Fail this buffered model invocation."
                    ),
                ]
            ),
            sessionID: bufferedFailureSessionID
        )
        let bufferedFailureCheckpoint = try Expect.notNil(
            try await historyStore.loadCheckpoint(
                sessionID: bufferedFailureSessionID
            ),
            "buffered model failure checkpoint persisted"
        )
        let restoredBufferedFailure = try await bufferedFailureRunner.resume(
            sessionID: bufferedFailureSessionID
        )

        try Expect.equal(
            bufferedFailureResult.failure?.kind,
            Optional(AgentRunFailure.Kind.model_invocation_failed),
            "buffered model invocation becomes structured run failure"
        )
        try Expect.contains(
            bufferedFailureResult.failure?.message ?? "",
            "Scripted model has no buffered response left.",
            "buffered model failure preserves adapter message"
        )
        try Expect.equal(
            bufferedFailureCheckpoint.failure,
            bufferedFailureResult.failure,
            "buffered model failure persists in checkpoint"
        )
        try Expect.equal(
            restoredBufferedFailure.failure,
            bufferedFailureResult.failure,
            "buffered model failure restores as terminal run result"
        )
        try Expect.equal(
            bufferedFailureResult.events.last?.kind,
            Optional(AgentRunEvent.Kind.run_failed),
            "buffered model failure records terminal run event"
        )

        let findCall = ToolCall(
            id: "conversation-failed-find-tools",
            tool: Standard.Tools.FindCapabilities.definition.identifier,
            input: try JSONValue.encoding(
                Standard.Tools.FindCapabilities.Input(
                    query: GatewayFlowEchoTool.identifier.rawValue,
                    maximumResults: 1
                )
            )
        )
        let findResponse = AgentResponse(
            message: .init(
                role: .assistant,
                content: .init(
                    blocks: [
                        .tool_call(
                            findCall
                        ),
                    ]
                )
            ),
            stopReason: .tool_use
        )
        var streamBatches: [[AgentStreamEvent]] = [
            [
                .toolcall(
                    findCall
                ),
                .completed(
                    findResponse
                ),
            ],
        ]

        for index in 1..<12 {
            let call = ToolCall(
                id: "conversation-failed-echo-\(index)",
                tool: GatewayFlowEchoTool.identifier,
                input: try JSONValue.encoding(
                    GatewayFlowEchoToolInput(
                        text: "loop \(index)"
                    )
                )
            )
            let response = AgentResponse(
                message: .init(
                    role: .assistant,
                    content: .init(
                        blocks: [
                            .tool_call(
                                call
                            ),
                        ]
                    )
                ),
                stopReason: .tool_use
            )

            streamBatches.append(
                [
                    .toolcall(
                        call
                    ),
                    .completed(
                        response
                    ),
                ]
            )
        }

        let continuedResponse = AgentResponse(
            message: .init(
                role: .assistant,
                text: "continued after run limit"
            ),
            stopReason: .end_turn
        )
        streamBatches.append(
            [
                .completed(
                    continuedResponse
                ),
            ]
        )

        let conversationAdapter = GatewayFlowScriptedModelGateway(
            streamBatches: streamBatches
        )
        let application = Agentic.application(
            "conversation-failed-runtime-fixture"
        ) {
            tools {
                GatewayFlowEchoTool()
            }
            modelProvider(
                ConversationRuntimeModelProvider(
                    modelGateway: conversationAdapter
                )
            )
        }
        let runtime = try await AgenticRuntime(
            application: application
        )
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "agentic-conversation-failed-runtime-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: workspaceRoot,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(
                at: workspaceRoot
            )
        }

        let conversation = try await makeLocalConversationSession(
            runtime: runtime,
            workspacePath: workspaceRoot.path,
            sessionID: "conversation-failed-runtime"
        )
        let result: AgentRunResult = try await conversation.submit(
            .init(
                body: "Keep using the echo tool until the run limit is reached.",
                contents: [],
                preferredModelProfileID: "conversation-scripted",
                skillIDs: []
            )
        )
        let requests = await conversationAdapter.recordedRequests()
        let conversationSnapshot = await conversation.snapshot
        let retainedInput = await conversation.input(
            for: result.sessionID
        )
        let retainedOutput = await conversation.output(
            for: result.sessionID
        )
        let run: AgenticHostConsoleRunPresentation = try Expect.notNil(
            conversationSnapshot.hostConsole.runs.first,
            "failed conversation retains attached host run"
        )
        let assistant: AgenticConversationMessagePresentation = try Expect.notNil(
            conversationSnapshot.messages.last,
            "failed conversation retains assistant presentation"
        )
        let interruption = try Expect.notNil(
            conversationSnapshot.hostConsole.interruptions.first { candidate in
                candidate.kind == .run_limit
            },
            "run-limit suspension projects a console interruption"
        )
        let exhaustion = try Expect.notNil(
            result.pendingRunLimit,
            "conversation exposes typed run-limit exhaustion"
        )

        try Expect.equal(
            result.isAwaitingRunLimit,
            true,
            "conversation returns a resumable run-limit suspension"
        )
        try Expect.equal(
            result.isFailed,
            false,
            "conversation run limit is not a failure"
        )
        try Expect.equal(
            result.state.iteration,
            12,
            "conversation retains all bounded iterations"
        )
        try Expect.equal(
            requests.count,
            12,
            "conversation suspends before a thirteenth model request"
        )
        try Expect.equal(
            assistant.body,
            exhaustion.summary,
            "assistant presentation explains the run-limit suspension"
        )
        try Expect.equal(
            assistant.attachments,
            [
                AgenticConversationAttachmentPresentation.run(
                    runID: result.sessionID
                ),
            ],
            "run-limit suspension retains run attachment"
        )
        try Expect.equal(
            run.state,
            AgenticHostConsoleRunState.paused,
            "run-limit suspension projects paused run state"
        )
        try Expect.equal(
            run.steps.last?.title,
            Optional("run limit"),
            "run-limit suspension exposes a supervisory timeline step"
        )
        try Expect.equal(
            interruption.actions,
            [
                .run_limit_continue(
                    iterations: 16
                ),
                .run_limit_continue(
                    iterations: 24
                ),
                .run_limit_unlimited,
                .run_limit_stop,
            ],
            "run-limit interruption exposes typed continuation choices"
        )
        try Expect.equal(
            conversationSnapshot.activity,
            "run limit reached",
            "conversation activity explains supervisory suspension"
        )
        try Expect.contains(
            retainedInput ?? "",
            "Keep using the echo tool",
            "run-limit run retains input"
        )
        try Expect.contains(
            retainedOutput ?? "",
            "run_limit",
            "run-limit run retains encoded suspension output"
        )

        let continued = try await conversation.resolveHostAction(
            interruptionID: interruption.id,
            runID: interruption.runID,
            stepID: interruption.stepID,
            action: .run_limit_continue(
                iterations: 16
            )
        )
        let continuedRequests = await conversationAdapter.recordedRequests()
        let continuedSnapshot = await conversation.snapshot

        try Expect.equal(
            continued.isCompleted,
            true,
            "typed run-limit action continues the same run"
        )
        try Expect.equal(
            continued.state.iteration,
            13,
            "run-limit continuation preserves cumulative iteration state"
        )
        try Expect.equal(
            continuedRequests.count,
            13,
            "run-limit continuation performs the next model request"
        )
        try Expect.equal(
            continued.response?.message.content.text,
            "continued after run limit",
            "run-limit continuation reaches scripted completion"
        )
        try Expect.equal(
            continuedSnapshot.hostConsole.runs.first?.state,
            Optional(AgenticHostConsoleRunState.completed),
            "continued run returns to completed console state"
        )
        try Expect.equal(
            continuedSnapshot.activity,
            "response completed",
            "continued run updates conversation activity"
        )

        let invocationFailureAdapter = GatewayFlowScriptedModelGateway()
        let invocationFailureApplication = Agentic.application(
            "conversation-model-invocation-failed-runtime-fixture"
        ) {
            tools {
                GatewayFlowEchoTool()
            }
            modelProvider(
                ConversationRuntimeModelProvider(
                    modelGateway: invocationFailureAdapter
                )
            )
        }
        let invocationFailureRuntime = try await AgenticRuntime(
            application: invocationFailureApplication
        )
        let invocationFailureConversation = try await makeLocalConversationSession(
            runtime: invocationFailureRuntime,
            workspacePath: workspaceRoot.path,
            sessionID: "conversation-model-invocation-failed-runtime"
        )
        let invocationFailureResult = try await invocationFailureConversation.submit(
            .init(
                body: "Trigger a model invocation failure.",
                contents: [],
                preferredModelProfileID: "conversation-scripted",
                skillIDs: [],
                toolExposure: .discovery
            )
        )
        let invocationFailureRequests = await invocationFailureAdapter.recordedRequests()
        let invocationFailureSnapshot = await invocationFailureConversation.snapshot
        let invocationFailureInput = await invocationFailureConversation.input(
            for: invocationFailureResult.sessionID
        )
        let invocationFailureOutput = await invocationFailureConversation.output(
            for: invocationFailureResult.sessionID
        )
        let invocationFailure = try Expect.notNil(
            invocationFailureResult.failure,
            "conversation model invocation failure"
        )
        let invocationFailureRun = try Expect.notNil(
            invocationFailureSnapshot.hostConsole.runs.first,
            "conversation model invocation failure retains host run"
        )
        let invocationFailureAssistant = try Expect.notNil(
            invocationFailureSnapshot.messages.last,
            "conversation model invocation failure retains assistant message"
        )
        let invocationFailureReport = try Expect.notNil(
            invocationFailure.report,
            "conversation model invocation failure retains error report"
        )
        let invocationFailureDetails = try Expect.notNil(
            invocationFailureSnapshot.hostConsole.documents.first {
                $0.stepID
                    == "\(invocationFailureResult.sessionID)-failure"
                    && $0.kind == .details
            },
            "conversation model invocation failure retains failure details"
        )
        let encodedInvocationFailure = try JSONEncoder().encode(
            invocationFailure
        )
        let decodedInvocationFailure = try JSONDecoder().decode(
            AgentRunFailure.self,
            from: encodedInvocationFailure
        )
        let legacyInvocationFailure = try JSONDecoder().decode(
            AgentRunFailure.self,
            from: Data(
                #"{"kind":"model_invocation_failed","message":"legacy failure","metadata":{}}"#.utf8
            )
        )

        try Expect.equal(
            invocationFailure.kind,
            AgentRunFailure.Kind.model_invocation_failed,
            "conversation model invocation failure kind"
        )
        try Expect.equal(
            invocationFailureRequests.count,
            1,
            "conversation model invocation failure records one attempted request"
        )
        try Expect.contains(
            invocationFailure.message,
            "Scripted model has no stream batch left.",
            "streaming model failure preserves adapter message"
        )
        try Expect.contains(
            invocationFailureReport.presentation.message,
            "Scripted model has no stream batch left.",
            "streaming model failure report preserves presentation"
        )
        try Expect.equal(
            decodedInvocationFailure.report,
            invocationFailure.report,
            "model invocation failure report survives Codable round trip"
        )
        try Expect.equal(
            legacyInvocationFailure.report == nil,
            true,
            "legacy failure without report remains decodable"
        )
        try Expect.equal(
            invocationFailureDetails.structuredBody == nil,
            false,
            "conversation model invocation failure exposes structured error details"
        )
        try Expect.equal(
            invocationFailureResult.events.contains {
                $0.kind == .model_stream_failed
            },
            true,
            "streaming model failure records model stream failure event"
        )
        try Expect.equal(
            invocationFailureResult.events.last?.kind,
            Optional(AgentRunEvent.Kind.run_failed),
            "streaming model failure records terminal run event"
        )
        try Expect.equal(
            invocationFailureRun.state,
            AgenticHostConsoleRunState.failed,
            "conversation model invocation failure projects failed run"
        )
        try Expect.equal(
            invocationFailureAssistant.attachments,
            [
                AgenticConversationAttachmentPresentation.run(
                    runID: invocationFailureResult.sessionID
                ),
            ],
            "conversation model invocation failure retains run attachment"
        )
        try Expect.contains(
            invocationFailureInput ?? "",
            "Trigger a model invocation failure.",
            "conversation model invocation failure retains input"
        )
        try Expect.contains(
            invocationFailureOutput ?? "",
            "model_invocation_failed",
            "conversation model invocation failure retains encoded output"
        )
        try Expect.contains(
            invocationFailureOutput ?? "",
            "\"report\"",
            "conversation model invocation failure retains encoded error report"
        )

        return [
            .field(
                "persisted_limit",
                persistedResult.pendingRunLimit?.summary ?? "missing"
            ),
            .field(
                "conversation_limit",
                exhaustion.summary
            ),
            .field(
                "conversation_model_calls",
                String(continuedRequests.count)
            ),
            .field(
                "buffered_model_failure",
                bufferedFailureResult.failure?.kind.rawValue ?? "missing"
            ),
            .field(
                "streaming_model_failure",
                invocationFailure.kind.rawValue
            ),
            GatewayRuntimeFlowDiagnostics.events(
                result.events
            ),
        ]
    }

    static func runLiveStateObservation() async throws -> [TestDiagnostic] {
        let response = AgentResponse(
            message: .init(
                role: .assistant,
                text: "live state ok"
            ),
            stopReason: .end_turn
        )
        let adapter = GatewayFlowScriptedModelGateway(
            streamBatches: [
                [
                    .messagedelta(
                        .text("live ")
                    ),
                    .messagedelta(
                        .text("state ok")
                    ),
                    .completed(
                        response
                    ),
                ],
            ]
        )
        let sink = ConversationRuntimeStateSink()
        let runner = AgentRunner(
            model: .init(
                invoker: GatewayFlowModelInvoker(
                    gateway: adapter,
                    model: "scripted"
                )
            ),
            configuration: .init(
                runLimits: .init(iterations: 1),
                responseDelivery: .stream
            ),
            recording: .init(
                stateSinks: [
                    sink,
                ]
            )
        )
        let result = try await runner.run(
            AgentRequest(
                messages: [
                    .init(
                        role: .user,
                        text: "stream a response"
                    ),
                ]
            ),
            sessionID: "conversation-live-state"
        )
        let snapshots = await sink.snapshots()
        let startedAt: Date = try Expect.notNil(
            snapshots.first?.startedAt,
            "live state start time"
        )
        let receivingSnapshot: AgentRunStateSnapshot = try Expect.notNil(
            snapshots.first(where: { snapshot in
                snapshot.phase == .receiving_model_response
            }),
            "live receiving snapshot"
        )
        let liveProjection = AgenticConversationRunProjection.project(
            receivingSnapshot,
            title: "live conversation run"
        )

        try Expect.equal(
            liveProjection.run.state,
            AgenticHostConsoleRunState.active,
            "live projection remains active while receiving model response"
        )
        try Expect.equal(
            liveProjection.run.steps.isEmpty,
            true,
            "live model response does not synthesize a completed step before tool use"
        )

        try Expect.equal(
            snapshots.first?.phase,
            Optional(AgentHistoryPhase.ready_for_model),
            "live state begins ready for model"
        )
        try Expect.equal(
            snapshots.contains { snapshot in
                snapshot.phase == .receiving_model_response
            },
            true,
            "live state exposes receiving phase"
        )
        try Expect.equal(
            snapshots.contains { snapshot in
                snapshot.partialResponse?.message.content.text == "live "
            },
            true,
            "live state exposes partial assistant text before completion"
        )
        try Expect.equal(
            snapshots.allSatisfy { snapshot in
                snapshot.startedAt == startedAt
            },
            true,
            "live state preserves stable start time"
        )
        try Expect.equal(
            snapshots.last?.phase,
            Optional(AgentHistoryPhase.completed),
            "live state publishes completed phase"
        )
        try Expect.equal(
            result.response?.message.content.text,
            "live state ok",
            "live state observation does not alter the run result"
        )

        return [
            .field(
                "snapshots",
                String(snapshots.count)
            ),
            .field(
                "final_phase",
                snapshots.last?.phase.rawValue ?? "missing"
            ),
        ]
    }
}