import Agentic
import AgenticHost
import AgenticRuntime
import Foundation
import Macros
import Primitives
import Schema
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
        } catch ProgramExecutionError.registrationUnavailable {
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