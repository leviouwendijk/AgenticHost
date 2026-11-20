import Agentic
@_spi(Testing) import AgenticHost
import AgenticRuntime
@_spi(Testing) import AgenticTUI
import Foundation
import Macros
import Primitives
import Schema
import TestFlows

@JSONSchema
private struct HostInferenceInput: Sendable, Codable, Hashable {
    let text: String
}

@JSONSchema
private struct HostInferenceOutput: Sendable, Codable, Hashable {
    let summary: String
}

private enum HostSummaryInference: Inference {
    typealias Input = HostInferenceInput
    typealias Output = HostInferenceOutput

    static let definition = InferenceDefinition(
        identifier: "host.summary",
        purpose: "Summarize the text."
    )
}

extension AgentHostLocalFlowTesting {
    /// The owner invokes an installed Inference directly: no adapter named,
    /// so `.json`; a text-only model gets the schema as an instruction; the
    /// typed output comes back and the invocation is in the session log.
    static func runDirectInference() async throws -> [TestDiagnostic] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("host-inference-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = Run.Log.Store(storage: .init(root: root))
        let gateway = GatewayFlowScriptedModelGateway(bufferedResponses: [
            .init(message: .init(role: .assistant, text: "```json\n{\"summary\":\"short\"}\n```"), stopReason: .end_turn),
            .init(message: .init(role: .assistant, text: #"{"summary":"again"}"#), stopReason: .end_turn),
        ])
        let runtime = try await AgenticRuntime(application: Agentic.application("host-inference") {
            install(
                HostSummaryInference.self,
                realization: .init(strategy: .direct, instructions: "Summarize.", budget: .singleAttempt)
            )
            modelProvider(AgentHostLocalModelProvider(modelGateway: gateway))
        })
        let host = AgentHost.Local(runtime: runtime, logs: logs)
        let session: AgentHost.Session.ID = "inference-session"
        _ = try await host.start(.init(id: session))

        let result = try await host.invokeInference(.init(
            inference: HostSummaryInference.definition.identifier,
            input: try JSONValue.encoding(HostInferenceInput(text: "a long text")),
            session: session
        ))
        try Expect.equal(result.output, .object(["summary": .string("short")]), "the typed output")
        let sent = try Expect.notNil(await gateway.recordedRequests().first, "the model was called")
        try Expect.equal(sent.responseFormat, .text, "a text-only model gets prompted JSON")
        let commands = try logs.read(session: session.rawValue).entries.compactMap { entry -> String? in
            guard case .state(let state) = entry.body, state.kind == .operator_command else { return nil }
            return state.summary
        }
        try Expect.true(commands.contains("inference host.summary → completed"), "traced: \(commands)")

        // From the command bar.
        guard case .inference(let identifier, let input) = try AgenticCapabilityCommand(
            parsing: #"inference host.summary {"text":"more"}"#
        ) else {
            throw HostInferenceFixtureError.notAnInference
        }
        try Expect.equal(identifier.rawValue, "host.summary", "identifier")
        guard case .program(let program) = try AgenticCapabilityCommand(
            parsing: #"program host_mutating_program {"text":"p.txt"}"#
        ) else {
            throw HostInferenceFixtureError.notAnInference
        }
        try Expect.equal(program.program.rawValue, "host_mutating_program", ":program uses the /program parser")
        try Expect.true(
            (try? AgenticCapabilityCommand(parsing: "inference host.summary not-json")) == nil,
            "invalid JSON input is refused"
        )
        try Expect.equal(
            AgenticCapabilityCommand.completer(programs: [], inferences: ["host.summary"])("inference ho")?
                .candidates.map(\.title),
            ["host.summary"],
            "identifiers complete"
        )
        let conversation = try await AgenticConversationSession(
            workspace: root.path,
            service: host,
            capabilities: try await host.capabilities(),
            sessionID: "inference-conversation"
        )
        await conversation.runInference("inference host.summary", identifier: identifier, input: input)
        let shown = await conversation.snapshot.messages.last?.body ?? ""
        try Expect.true(shown.contains("\"summary\" : \"again\""), "the output is in the transcript: \(shown)")
        return []
    }
}

private enum HostInferenceFixtureError: Error {
    case notAnInference
}
