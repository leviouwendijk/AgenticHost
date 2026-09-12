import Agentic
import AgenticHost
import AgenticPrograms
import AgenticRuntime
import Foundation
import Primitives
import TestFlows

extension AgenticRuntimeFlowTesting {
    static func runHostProgramInvocation()
        async throws
        -> [TestFlowDiagnostic]
    {
        let defaultRealization =
            AgentProgramRealization<HostProgramFixture>(
                id: "fixture.host_default_realization",
                inferences: .empty,
                metadata: [
                    "source": "host_application",
                ]
            )

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
            capabilities.programs.count,
            1,
            "Host capabilities expose installed Programs as transport-safe semantic descriptors"
        )
        try Expect.equal(
            capabilities.programs[0].identifier,
            HostProgramFixture.descriptor.identifier,
            "Host Program capability preserves the semantic Program identifier"
        )
        try Expect.equal(
            capabilities.programs[0].title,
            HostProgramFixture.descriptor.title,
            "Host Program capability preserves its title"
        )
        try Expect.equal(
            capabilities.programs[0].summary,
            HostProgramFixture.descriptor.summary,
            "Host Program capability preserves its summary"
        )

        let input = try JSONToolBridge.encode(
            HostProgramFixture.Input(
                value: "host"
            )
        )
        let invocation = AgentHost.ProgramInvocation(
            program: HostProgramFixture.descriptor.identifier,
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
            AgentProgramExecutionOutcome.succeeded,
            "Host direct Program invocation delegates execution to Runtime"
        )
        try Expect.equal(
            defaultExecution.realizationIdentifier,
            defaultRealization.id,
            "Host direct Program invocation preserves the Runtime registration default realization"
        )
        try Expect.equal(
            defaultExecution.metadata[
                "transport"
            ],
            "host_service",
            "Host direct Program invocation preserves transport metadata"
        )

        let defaultOutput = try JSONToolBridge.decode(
            HostProgramFixture.Output.self,
            from: defaultExecution.output
                ?? .null
        )

        try Expect.equal(
            defaultOutput.value,
            "echo:host",
            "Host returns the Runtime Program execution record and erased output"
        )

        let explicitRealization =
            AgentProgramRealization<HostProgramFixture>(
                id: "fixture.host_explicit_realization",
                inferences: .empty,
                metadata: [
                    "source": "host_invocation",
                ]
            )
        let explicitExecution = try await service.invokeProgram(
            .init(
                program: HostProgramFixture.descriptor.identifier,
                input: input,
                realization: try JSONToolBridge.encode(
                    explicitRealization
                )
            )
        )

        try Expect.equal(
            explicitExecution.realizationIdentifier,
            explicitRealization.id,
            "Host transports an explicit typed Program realization through the erased Runtime boundary"
        )

        var unknownRejected = false

        do {
            _ = try await service.invokeProgram(
                .init(
                    program: "fixture.host_unknown_program",
                    input: input
                )
            )
        } catch AgentRuntimeProgramExecutionError
            .registrationUnavailable {
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
                "default_realization",
                defaultExecution
                    .realizationIdentifier?
                    .rawValue
                    ?? "none"
            ),
            .field(
                "explicit_realization",
                explicitExecution
                    .realizationIdentifier?
                    .rawValue
                    ?? "none"
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
        identifier: "fixture.host_program",
        title: "Host Program",
        summary: "Proves transport-safe Host Program discovery and direct invocation."
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
