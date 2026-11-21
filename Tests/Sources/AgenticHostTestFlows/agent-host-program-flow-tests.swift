import Agentic
@_spi(Testing) import AgenticHost
import AgenticIO
import AgenticRuntime
import Foundation
import Macros
import Primitives
import Schema
import Writers
import TestFlows

extension AgenticRuntimeFlowTesting {
    static func runHostProgramInvocation()
        async throws
        -> [TestDiagnostic]
    {
        let defaultRealization = try ProgramRealization<HostProgramFixture>()

        let application = Agentic.application(
            "fixture.host_program_application"
        ) {
            programs {
                program(
                    HostProgramFixture(),
                    realization: defaultRealization
                )
            }
        }
        let runtime = try await AgenticRuntime(
            application: application
        )
        let service: any AgentHost.Service =
            AgentHost.Local(
                runtime: runtime
            )

        let capabilities = try await service.capabilities()

        try Expect.equal(
            capabilities.installedCapabilities.programs,
            [HostProgramFixture.definition.identifier],
            "Installed capability projection includes bound Programs"
        )
        try Expect.equal(
            capabilities.catalogEntries.filter { $0.kind == .program }.map(\.identifier),
            [HostProgramFixture.definition.identifier.rawValue],
            "Catalog projection describes installed Programs without granting authority"
        )

        try Expect.equal(
            capabilities.programs.count,
            1,
            "Host capabilities expose installed Programs as transport-safe semantic descriptors"
        )
        try Expect.equal(
            capabilities.programs[0].identifier,
            HostProgramFixture.definition.identifier,
            "Host Program capability preserves the semantic Program identifier"
        )
        try Expect.equal(
            capabilities.programs[0].title,
            HostProgramFixture.definition.title,
            "Host Program capability preserves its title"
        )
        try Expect.equal(
            capabilities.programs[0].purpose,
            HostProgramFixture.definition.purpose,
            "Host Program capability preserves its purpose"
        )

        let input = try JSONValue.encoding(
            HostProgramFixture.Input(
                value: "host"
            )
        )
        let invocation = AgentHost.ProgramInvocation(
            program: HostProgramFixture.definition.identifier,
            input: input,
            metadata: [
                "transport": "host_service",
            ]
        )
        let encodedInvocation = try JSONEncoder().encode(
            invocation
        )
        let decodedInvocation = try JSONDecoder().decode(
            AgentHost.ProgramInvocation.self,
            from: encodedInvocation
        )

        try Expect.equal(
            decodedInvocation.program,
            invocation.program,
            "Host Program invocation identifier survives Codable transport"
        )
        try Expect.equal(
            decodedInvocation.input,
            invocation.input,
            "Host Program invocation input survives Codable transport"
        )
        try Expect.equal(
            decodedInvocation.metadata,
            invocation.metadata,
            "Host Program invocation metadata survives Codable transport"
        )

        let defaultExecution = try await service.invokeProgram(
            decodedInvocation
        )

        try Expect.equal(
            defaultExecution.outcome,
            ProgramExecutionOutcome.succeeded,
            "Host direct Program invocation delegates execution to Runtime"
        )
        try Expect.equal(
            defaultExecution.metadata[
                "transport"
            ],
            "host_service",
            "Host direct Program invocation preserves transport metadata"
        )

        let defaultOutput = try (
            defaultExecution.output
                ?? .null
        ).decode(
            HostProgramFixture.Output.self
        )

        try Expect.equal(
            defaultOutput.value,
            "echo:host",
            "Host returns the Runtime Program execution record and erased output"
        )

        let explicitRealization = try ProgramRealization<HostProgramFixture>()
        let explicitExecution = try await service.invokeProgram(
            .init(
                program: HostProgramFixture.definition.identifier,
                input: input,
                realization: try JSONValue.encoding(
                    explicitRealization
                )
            )
        )

        try Expect.equal(
            explicitExecution.outcome,
            ProgramExecutionOutcome.succeeded,
            "Host accepts an explicit typed Program realization through the erased Runtime boundary"
        )

        let explicitOutput = try (
            explicitExecution.output
                ?? .null
        ).decode(
            HostProgramFixture.Output.self
        )

        try Expect.equal(
            explicitOutput.value,
            "echo:host",
            "Explicit Program realization preserves Program execution output"
        )

        var unknownRejected = false

        do {
            _ = try await service.invokeProgram(
                .init(
                    program: "fixture.host_unknown_program",
                    input: input
                )
            )
        } catch ProgramExecutionError.bindingUnavailable {
            unknownRejected = true
        }

        try Expect.equal(
            unknownRejected,
            true,
            "Host preserves Runtime rejection for Programs not installed by the application"
        )

        return [
            .field(
                "programs",
                String(capabilities.programs.count)
            ),
            .field(
                "program",
                capabilities.programs[0]
                    .identifier.rawValue
            ),
            .field(
                "default_realization_bindings",
                String(defaultRealization.bindings.count)
            ),
            .field(
                "explicit_realization_bindings",
                String(explicitRealization.bindings.count)
            ),
            .field(
                "output",
                defaultOutput.value
            ),
            .field(
                "unknown_rejected",
                String(unknownRejected)
            ),
        ]
    }
}

private struct HostProgramFixture:
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
        identifier: "fixture.host_program",
        purpose: "Proves transport-safe Host Program discovery and direct invocation.",
        title: "Host Program"
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
/// Edits one file through the governed Mutate tool.
private struct HostMutatingProgram: Program {
    typealias Input = GatewayFlowEchoToolInput
    typealias Output = JSONValue

    static let definition = ProgramDefinition(
        identifier: "host_mutating_program",
        purpose: "Edit one file, to verify Program mutations under coordination.",
        title: "Mutating Program"
    )

    func run(_ input: Input, in context: ProgramContext) async throws -> Output {
        try await context.invoke(
            SystemIO.Tools.Mutate.identifier,
            input: JSONValue.object(["entries": .array([.object([
                "kind": .string("replace_text"),
                "path": .string(input.text),
                "content": .string("changed\n"),
            ])])]),
            as: JSONValue.self
        )
    }
}

extension AgenticRuntimeFlowTesting {
    /// A Program run in a session under coordinated mutations stages its
    /// changes with that session: reviewed and published like a run's.
    static func runCoordinatedProgramMutations() async throws -> [TestDiagnostic] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("host-program-coordinated-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("p.txt")
        try "original\n".write(to: file, atomically: true, encoding: .utf8)

        let runtime = try await AgenticRuntime(application: Agentic.application("host-program-coordinated") {
            tools { SystemIO.Tools.Mutate() }
            programs { HostMutatingProgram() }
        })
        let host = AgentHost.Local(
            runtime: runtime,
            workspace: try AgenticRuntimeWorkspace.resolve(root.path),
            io: .blocking,
            mutations: .coordinated(StandardMutationCoordinator()),
            publication: .review
        )
        let session: AgentHost.Session.ID = "program-coordinated"
        _ = try await host.start(.init(id: session))
        func invocation(session: AgentHost.Session.ID?) throws -> AgentHost.ProgramInvocation {
            .init(
                program: HostMutatingProgram.definition.identifier,
                input: try JSONValue.encoding(GatewayFlowEchoToolInput(text: "p.txt")),
                autonomyMode: .auto_bounded_mutate,
                metadata: session.map { ["conversation_session_id": $0.rawValue] } ?? [:]
            )
        }

        let record = try await host.invokeProgram(try invocation(session: session))
        try Expect.equal(record.outcome, .succeeded, "the Program completes")
        try Expect.equal(try String(contentsOf: file, encoding: .utf8), "original\n", "its change is staged, not written")
        let review = try Expect.notNil(
            try await host.reviewCoordinatedMutations(session: session),
            "the change is in the session's review"
        )
        try Expect.equal(review.origins.flatMap(\.paths), ["p.txt"], "the review names the file")
        _ = try await host.publishCoordinatedMutations(reviewID: review.id, decision: .approved)
        try Expect.equal(try String(contentsOf: file, encoding: .utf8), "changed\n", "publishing writes it")

        do {
            _ = try await host.invokeProgram(try invocation(session: nil))
            try Expect.true(false, "a Program with no session has no review to stage into")
        } catch AgentHost.Local.Failure.coordinatedProgramExecutionNotConfigured {}
        return []
    }
}
