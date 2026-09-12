import Agentic
import AgenticExecution
import AgenticIO
import AgenticInterfaces
import AgenticPrograms
import AgenticRuntime
import AgenticCommandLine
import AgenticTools
import Difference
import DSL
import Errors
import Foundation
import Primitives
import TestFlows

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

private struct ConversationApprovalTool: AgentTool {
    typealias Input = GatewayFlowEchoToolInput
    typealias Output = GatewayFlowEchoToolOutput

    static let identifier: AgentToolIdentifier = "conversation_approval_tool"
    static let description = "Bounded mutation fixture for conversation approval routing."
    static let risk: ActionRisk = .boundedmutate

    let probe: ConversationApprovalToolProbe

    var identifier: AgentToolIdentifier {
        Self.identifier
    }

    var description: String {
        Self.description
    }

    var risk: ActionRisk {
        Self.risk
    }

    func preflight(
        _ input: Input,
        context: AgentToolExecutionContext
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
                    oldLine: 1
                ),
                .init(
                    role: .insert,
                    text: "new",
                    newLine: 1
                ),
            ]
        )

        return ToolPreflight(
            toolName: name,
            risk: risk,
            workspaceRoot: context.workspace?.rootURL.path,
            summary: description,
            diffPreview: .init(
                title: "Conversation diff preview",
                contextLineCount: 3,
                text: "--- a/conversation.txt\n+++ b/conversation.txt\n-old\n+new",
                layout: layout,
                insertedLineCount: 1,
                deletedLineCount: 1
            )
        )
    }

    func call(
        _ input: Input,
        context _: AgentToolExecutionContext
    ) async throws -> Output {
        await probe.recordInvocation()
        return GatewayFlowEchoToolOutput(
            text: input.text
        )
    }
}

private struct ConversationApprovalProgramFixture:
    AgentProgram
{
    struct Input:
        Sendable,
        Codable,
        Hashable
    {
        let value: String
    }

    struct Output:
        Sendable,
        Codable,
        Hashable
    {
        let value: String
    }

    static let descriptor = AgentProgramDescriptor(
        identifier: "fixture.conversation_approval_program",
        title: "Conversation Approval Program",
        summary: "Proves Program approval suspension and resume through Host-backed conversation UI."
    )

    func run(
        _ input: Input,
        in context: AgentProgramContext
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

private struct ConversationProgramFixture:
    AgentProgram
{
    struct Input:
        Sendable,
        Codable,
        Hashable
    {
        let value: String
    }

    struct Output:
        Sendable,
        Codable,
        Hashable
    {
        let value: String
    }

    static let descriptor = AgentProgramDescriptor(
        identifier: "fixture.conversation_program",
        title: "Conversation Program",
        summary: "Proves direct Program execution through the Host-backed conversation surface."
    )

    func run(
        _ input: Input,
        in _: AgentProgramContext
    ) async throws -> Output {
        .init(
            value: "echo:\(input.value)"
        )
    }
}

enum AgenticRuntimeConversationFlowTesting {
    static func runProgramApprovalResume()
        async throws
        -> [TestFlowDiagnostic]
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
        let input = try JSONToolBridge.encode(
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
                    .descriptor.identifier,
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
        -> [TestFlowDiagnostic]
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
        let input = try JSONToolBridge.encode(
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
                program: ConversationProgramFixture.descriptor.identifier,
                input: input
            ),
            submission: submission
        )
        let output = try JSONToolBridge.decode(
            ConversationProgramFixture.Output.self,
            from: record.output ?? .null
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
            ConversationProgramFixture.descriptor.identifier,
            "conversation snapshot preserves Program identity"
        )
        try Expect.equal(
            record.outcome,
            AgentProgramExecutionOutcome.succeeded,
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
            ConversationProgramFixture.descriptor.identifier,
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

    static func run() async throws -> [TestFlowDiagnostic] {
        let findCall = AgentToolCall(
            id: "conversation-find-tools-call",
            name: FindToolsTool.identifier.rawValue,
            input: try JSONToolBridge.encode(
                FindToolsToolInput(
                    query: GatewayFlowEchoTool.identifier.rawValue,
                    maximumResults: 1
                )
            )
        )
        let echoCall = AgentToolCall(
            id: "conversation-echo-call",
            name: GatewayFlowEchoTool.identifier.rawValue,
            input: try JSONToolBridge.encode(
                GatewayFlowEchoToolInput(
                    text: "conversation payload"
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
            tools {
                GatewayFlowEchoTool()
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
                GatewayFlowEchoTool.identifier.rawValue,
                FindToolsTool.identifier.rawValue,
            ],
            "conversation begins with catalog defaults plus discovery"
        )
        try Expect.equal(
            requests[1].tools.map(
                \.name
            ),
            [
                GatewayFlowEchoTool.identifier.rawValue,
                FindToolsTool.identifier.rawValue,
            ],
            "discovered tool is advertised on the next turn"
        )
        try Expect.equal(
            requests[2].tools.map(
                \.name
            ),
            [
                GatewayFlowEchoTool.identifier.rawValue,
                FindToolsTool.identifier.rawValue,
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
            "Default application tools and required tools from selected skills are exposed immediately.",
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
                FindToolsTool.identifier.rawValue,
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
            "find_tools details expose exact model input"
        )
        try Expect.contains(
            findDetails?.body ?? "",
            GatewayFlowEchoTool.identifier.rawValue,
            "find_tools details expose exact discovery query"
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
            "find_tools details retain semantic structured content"
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
            "find_tools structured details preserve semantic input role"
        )
        try Expect.contains(
            findStructuredText,
            "maximumResults",
            "find_tools structured details preserve exact input"
        )
        try Expect.contains(
            findStructuredText,
            GatewayFlowEchoTool.identifier.rawValue,
            "find_tools structured details preserve discovery query"
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
        let call = AgentToolCall(
            id: "conversation-approval-call",
            name: ConversationApprovalTool.identifier.rawValue,
            input: try JSONToolBridge.encode(
                GatewayFlowEchoToolInput(
                    text: "approved payload"
                )
            )
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

    static func runRecoveredToolErrorProjection() async throws -> [TestFlowDiagnostic] {
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

    static func runCustomToolExposureSelection()
        async throws -> [TestFlowDiagnostic]
    {
        let store = GatewayFlowScratchpadStore()
        let skill = AgentSkill(
            identifier: "conversation-custom-required-skill",
            name: "Conversation Custom Required Skill",
            summary: "Requires scratchpad read access.",
            body: "Use scratchpad read when required.",
            metadata: .init(
                tools: .init(
                    required: [
                        .tool(
                            GatewayFlowScratchpadReadTool.identifier
                        ),
                    ]
                )
            )
        )
        let response = AgentResponse(
            message: .init(
                role: .assistant,
                text: "custom tool exposure ok"
            ),
            stopReason: .end_turn
        )
        let adapter = GatewayFlowScriptedModelGateway(
            streamBatches: [
                [
                    .completed(response),
                ],
                [
                    .completed(response),
                ],
            ]
        )
        let application = Agentic.application(
            "conversation-custom-tool-exposure-runtime-fixture"
        ) {
            tools {
                collection(
                    "conversation.defaults",
                    title: "Defaults",
                    defaultExposure: .included
                ) {
                    GatewayFlowEchoTool()
                }
                collection(
                    "conversation.custom",
                    title: "Custom",
                    defaultExposure: .excluded
                ) {
                    GatewayFlowScratchpadReadTool(
                        store: store
                    )
                    GatewayFlowScratchpadTool(
                        store: store
                    )
                }
            }
            skills {
                skill
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
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "agentic-conversation-custom-tool-exposure-\(UUID().uuidString)",
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
            sessionID: "conversation-custom-tool-exposure-runtime"
        )
        let initialSnapshot = await conversation.snapshot
        let defaultsCollection = try Expect.notNil(
            initialSnapshot.toolCollections.first { collection in
                collection.id == "conversation.defaults"
            },
            "conversation projects default tool collection"
        )
        let customCollection = try Expect.notNil(
            initialSnapshot.toolCollections.first { collection in
                collection.id == "conversation.custom"
            },
            "conversation projects excluded selectable collection"
        )
        let intrinsicCollection = try Expect.notNil(
            initialSnapshot.toolCollections.first { collection in
                collection.id
                    == AgentToolCollectionMetadata
                        .intrinsics
                        .identifier
                        .rawValue
            },
            "conversation projects runtime intrinsics"
        )
        let findToolsPresentation = try Expect.notNil(
            intrinsicCollection.tools.first { tool in
                tool.id == FindToolsTool.identifier
            },
            "conversation projects find_tools"
        )

        try Expect.equal(
            defaultsCollection.tools.map(\.id),
            [
                GatewayFlowEchoTool.identifier,
            ],
            "default collection projects exact model-facing identifiers"
        )
        try Expect.equal(
            customCollection.tools.map(\.id).sorted {
                $0.rawValue < $1.rawValue
            },
            [
                GatewayFlowScratchpadTool.identifier,
                GatewayFlowScratchpadReadTool.identifier,
            ].sorted {
                $0.rawValue < $1.rawValue
            },
            "excluded collection remains selectable in presentation"
        )
        try Expect.equal(
            findToolsPresentation.selectionRole,
            .dynamicDiscovery,
            "find_tools is presented as derived dynamic-discovery control"
        )
        try Expect.equal(
            initialSnapshot.customToolSelection,
            AgenticConversationToolSelection(
                identifiers: [
                    GatewayFlowEchoTool.identifier,
                ],
                dynamicDiscovery: true
            ),
            "initial Custom state snapshots exact application defaults"
        )

        let fixedSelection = AgenticConversationToolSelection(
            identifiers: [
                GatewayFlowScratchpadTool.identifier,
            ],
            dynamicDiscovery: false
        )
        await conversation.selectCustomToolSelection(
            fixedSelection
        )
        await conversation.selectToolExposure(
            .all
        )
        let switchedSnapshot = await conversation.snapshot

        try Expect.equal(
            switchedSnapshot.selectedToolExposure,
            .all,
            "switching exposure mode changes only the active mode"
        )
        try Expect.equal(
            switchedSnapshot.customToolSelection,
            fixedSelection,
            "switching away from Custom preserves exact Custom state"
        )

        _ = try await conversation.submit(
            .init(
                body: "Use fixed custom exposure.",
                contents: [],
                preferredModelProfileID: "conversation-scripted",
                skillIDs: [
                    skill.identifier,
                ],
                toolExposure: .custom,
                customToolSelection: fixedSelection
            )
        )

        let dynamicSelection = AgenticConversationToolSelection(
            identifiers: [
                GatewayFlowScratchpadTool.identifier,
            ],
            dynamicDiscovery: true
        )
        _ = try await conversation.submit(
            .init(
                body: "Use discoverable custom exposure.",
                contents: [],
                preferredModelProfileID: "conversation-scripted",
                skillIDs: [
                    skill.identifier,
                ],
                toolExposure: .custom,
                customToolSelection: dynamicSelection
            )
        )

        let requests = await adapter.recordedRequests()
        try Expect.equal(
            requests.count,
            2,
            "Custom exposure produces two model requests"
        )
        let fixedRequest = try Expect.notNil(
            requests.first,
            "fixed Custom request"
        )
        let dynamicRequest = try Expect.notNil(
            requests.dropFirst().first,
            "discoverable Custom request"
        )
        let fixedAdvertised = fixedRequest.tools.map(\.name).sorted()
        let dynamicAdvertised = dynamicRequest.tools.map(\.name).sorted()

        try Expect.equal(
            fixedAdvertised,
            [
                GatewayFlowScratchpadTool.identifier.rawValue,
                GatewayFlowScratchpadReadTool.identifier.rawValue,
            ].sorted(),
            "Custom discovery-off advertises exact selection plus required skill tools"
        )
        try Expect.equal(
            fixedAdvertised.contains(
                GatewayFlowEchoTool.identifier.rawValue
            ),
            false,
            "Custom selection does not inherit application defaults"
        )
        try Expect.equal(
            fixedAdvertised.contains(
                FindToolsTool.identifier.rawValue
            ),
            false,
            "Custom discovery-off does not advertise find_tools"
        )
        try Expect.contains(
            fixedRequest.messages.first?.content.text ?? "",
            "Dynamic tool discovery is disabled.",
            "fixed Custom system prompt states discovery is disabled"
        )
        try Expect.equal(
            dynamicAdvertised,
            [
                GatewayFlowScratchpadTool.identifier.rawValue,
                GatewayFlowScratchpadReadTool.identifier.rawValue,
                FindToolsTool.identifier.rawValue,
            ].sorted(),
            "Custom discovery-on adds find_tools to selection plus required skill tools"
        )
        try Expect.contains(
            dynamicRequest.messages.first?.content.text ?? "",
            "Use find_tools to discover additional registered capabilities.",
            "discoverable Custom system prompt exposes discovery path"
        )
        try Expect.equal(
            fixedRequest.metadata["conversation_tool_exposure"],
            "custom",
            "Custom exposure metadata uses canonical enum raw value"
        )

        let finalSnapshot = await conversation.snapshot
        try Expect.equal(
            finalSnapshot.selectedToolExposure,
            .custom,
            "conversation retains Custom as active exposure mode"
        )
        try Expect.equal(
            finalSnapshot.customToolSelection,
            dynamicSelection,
            "conversation retains latest independent Custom selection state"
        )

        return [
            .field(
                "collections",
                String(initialSnapshot.toolCollections.count)
            ),
            .field(
                "fixed",
                fixedAdvertised.joined(separator: ",")
            ),
            .field(
                "dynamic",
                dynamicAdvertised.joined(separator: ",")
            ),
            .field(
                "custom_retained",
                String(
                    finalSnapshot.customToolSelection
                        == dynamicSelection
                )
            ),
        ]
    }

    static func runToolExposureSelection() async throws -> [TestFlowDiagnostic] {
        let response = AgentResponse(
            message: .init(
                role: .assistant,
                text: "all tools exposure ok"
            ),
            stopReason: .end_turn
        )
        let adapter = GatewayFlowScriptedModelGateway(
            streamBatches: [
                [
                    .completed(
                        response
                    ),
                ],
            ]
        )
        let application = Agentic.application(
            "conversation-tool-exposure-runtime-fixture"
        ) {
            tools {
                GatewayFlowEchoTool()
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
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "agentic-conversation-tool-exposure-\(UUID().uuidString)",
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
            sessionID: "conversation-tool-exposure-runtime"
        )
        _ = try await conversation.submit(
            .init(
                body: "Inspect the full tool surface.",
                contents: [],
                preferredModelProfileID: "conversation-scripted",
                skillIDs: [],
                toolExposure: .all
            )
        )

        let requests = await adapter.recordedRequests()
        let conversationSnapshot = await conversation.snapshot
        let first = try Expect.notNil(
            requests.first,
            "all-tools conversation request"
        )
        let advertised = first.tools.map(\.name)

        try Expect.equal(
            advertised.contains(
                GatewayFlowEchoTool.identifier.rawValue
            ),
            true,
            "all exposure advertises registered model-facing tools"
        )
        try Expect.equal(
            first.metadata["conversation_tool_exposure"],
            "all",
            "all exposure metadata"
        )
        try Expect.equal(
            conversationSnapshot.selectedToolExposure,
            AgenticConversationToolExposure.all,
            "conversation retains all-tools selection"
        )
        try Expect.contains(
            first.messages.first?.content.text ?? "",
            "All registered model-facing tools are exposed immediately.",
            "all-tools system prompt"
        )

        return [
            .field(
                "advertised",
                advertised.joined(separator: ",")
            ),
            .field(
                "exposure",
                conversationSnapshot.selectedToolExposure.rawValue
            ),
        ]
    }


    static func runFailureObservability() async throws -> [TestFlowDiagnostic] {
        let persistedCall = AgentToolCall(
            id: "failed-run-persisted-echo",
            name: GatewayFlowEchoTool.identifier.rawValue,
            input: try JSONToolBridge.encode(
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
                maximumIterations: 1,
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
            persistedResult.isFailed,
            true,
            "maximum iteration limit returns a failed run result"
        )
        try Expect.equal(
            persistedResult.failure?.kind,
            Optional(AgentRunFailure.Kind.maximum_iterations_exceeded),
            "failed run kind"
        )
        try Expect.equal(
            persistedResult.state.iteration,
            1,
            "failed run retains loop state"
        )
        try Expect.equal(
            persistedResult.events.last?.kind,
            Optional(AgentRunEvent.Kind.run_failed),
            "failed run records terminal event"
        )
        try Expect.equal(
            persistedCheckpoint.phase,
            AgentHistoryPhase.failed,
            "failed checkpoint phase"
        )
        try Expect.equal(
            persistedCheckpoint.failure?.kind,
            Optional(AgentRunFailure.Kind.maximum_iterations_exceeded),
            "failed checkpoint reason"
        )
        try Expect.equal(
            restoredResult.failure,
            persistedResult.failure,
            "loading a terminal failed session preserves failure outcome"
        )
        try Expect.equal(
            restoredResult.events,
            persistedResult.events,
            "loading a terminal failed session preserves run events"
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
                maximumIterations: 2,
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

        let findCall = AgentToolCall(
            id: "conversation-failed-find-tools",
            name: FindToolsTool.identifier.rawValue,
            input: try JSONToolBridge.encode(
                FindToolsToolInput(
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
            let call = AgentToolCall(
                id: "conversation-failed-echo-\(index)",
                name: GatewayFlowEchoTool.identifier.rawValue,
                input: try JSONToolBridge.encode(
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
        let failure: AgentRunFailure = try Expect.notNil(
            result.failure,
            "failed conversation result"
        )

        try Expect.equal(
            result.isFailed,
            true,
            "failed conversation returns structured run outcome"
        )
        try Expect.equal(
            result.state.iteration,
            12,
            "conversation retains all bounded iterations"
        )
        try Expect.equal(
            requests.count,
            12,
            "conversation stops before a thirteenth model request"
        )
        try Expect.equal(
            assistant.body,
            failure.message,
            "failed assistant presentation uses structured failure message"
        )
        try Expect.equal(
            assistant.attachments,
            [
                AgenticConversationAttachmentPresentation.run(
                    runID: result.sessionID
                ),
            ],
            "failed assistant retains run attachment"
        )
        try Expect.equal(
            run.state,
            AgenticHostConsoleRunState.failed,
            "failed run projects failed state"
        )
        try Expect.equal(
            run.summary,
            Optional(failure.message),
            "failed run projects failure summary"
        )
        try Expect.equal(
            run.steps.last?.title,
            Optional("run failure"),
            "failed run exposes terminal failure step"
        )
        try Expect.equal(
            conversationSnapshot.activity,
            "run failed",
            "failed conversation activity"
        )
        try Expect.contains(
            retainedInput ?? "",
            "Keep using the echo tool",
            "failed run retains input"
        )
        try Expect.contains(
            retainedOutput ?? "",
            "maximum_iterations_exceeded",
            "failed run retains encoded failure output"
        )
        try Expect.contains(
            conversationSnapshot.hostConsole.documents.last?.body ?? "",
            "maximum_iterations_exceeded",
            "failed run exposes terminal failure details"
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
                "persisted_failure",
                persistedResult.failure?.kind.rawValue ?? "missing"
            ),
            .field(
                "conversation_failure",
                failure.kind.rawValue
            ),
            .field(
                "conversation_model_calls",
                String(requests.count)
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

    static func runLiveStateObservation() async throws -> [TestFlowDiagnostic] {
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
                maximumIterations: 1,
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
