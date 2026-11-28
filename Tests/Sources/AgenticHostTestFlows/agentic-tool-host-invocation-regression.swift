import Agentic
@_spi(Testing) import AgenticHost
import Foundation
import Schema

/// Focused I2 regression proof for the migrated tool-host model boundary.
///
/// Exercises `AgenticToolHostInvocationContract` (registry-sourced invocation
/// schema and manifest) and `AgenticToolHostInvocationParser` (untrusted JSON
/// classification) against a live `ToolRegistry` containing both a model-facing
/// and a host-only fixture tool. After the I1 semantic cleanup, execution is a
/// canonical `ToolInvocation.Target` for every model-facing tool and the
/// host never encodes per-tool targetability.
enum AgenticToolHostInvocationRegression {
    enum Failure: Error {
        case unexpectedModelFacingContract
        case unexpectedHostOnlyInContract
        case invocationSchemaNotADirectUnion
        case executionSchemaMissingWorkspaceSubpath
        case planSchemaTargetableWording
        case manifestMissingModelFacingTool
        case manifestIncludesHostOnlyTool
        case directParseMismatch
        case batchParseMismatch
        case planParseMismatch
        case expectedRejection
    }

    static func run() throws {
        let registry = try makeRegistry()
        let host = AgenticToolHost(
            registry: registry,
            policy: ToolExecutionPolicy(
                autonomyMode: .auto_observe
            )
        )

        try runContractProbe(host: host)
        try runManifestProbe(host: host)
        try runParserAcceptanceProbe(host: host)
        try runParserRejectionProbe(host: host)

        print(
            "tool host invocation regression passed"
        )
    }

    // MARK: - Contract / registry inspection

    private static func runContractProbe(
        host: AgenticToolHost
    ) throws {
        let inspection = host.registry.inspect()
        let entries = inspection.tools

        guard entries.contains(
            where: {
                $0.identifier.rawValue == EchoTool.identifier
                    && $0.isModelFacing
                    && $0.semanticInputSchema != nil
            }
        ) else {
            throw Failure.unexpectedModelFacingContract
        }

        guard entries.contains(
            where: {
                $0.identifier.rawValue == HostOnlyTool.identifier
                    && !$0.isModelFacing
            }
        ) else {
            throw Failure.unexpectedHostOnlyInContract
        }

        let invocationSchema = AgenticToolHostInvocationContract.schema(
            registryInspection: entries
        )

        guard case .oneOf(let forms) = invocationSchema.form,
              forms.count == 3
        else {
            throw Failure.invocationSchemaNotADirectUnion
        }

        let definitions = invocationSchema.definitions

        guard let execution = definitions["AgentToolExecution"],
              executionContainsWorkspaceSubpath(execution)
        else {
            throw Failure.executionSchemaMissingWorkspaceSubpath
        }

        guard !definitions.keys.contains(
            where: {
                $0.contains(HostOnlyTool.identifier)
            }
        ) else {
            throw Failure.unexpectedHostOnlyInContract
        }

        guard planSchemaHasNoTargetableWording(
            definitions
        ) else {
            throw Failure.planSchemaTargetableWording
        }
    }

    private static func executionContainsWorkspaceSubpath(
        _ schema: JSONSchema
    ) -> Bool {
        guard case .object(let properties, _) = schema.form,
              let workspace = properties.first(
                where: {
                    $0.name == "workspace"
                }
              ),
              case .object(let targetProperties, _) = workspace.schema.form,
              targetProperties.contains(
                where: {
                    $0.name == "subpath"
                }
              )
        else {
            return false
        }

        return true
    }

    private static func planSchemaHasNoTargetableWording(
        _ definitions: [String: JSONSchema]
    ) -> Bool {
        guard let planNode = definitions["ToolPlanNode"],
              case .oneOf(let variants) = planNode.form
        else {
            return true
        }

        let callVariant = variants.first {
            discriminator("kind", in: $0) == "call"
        }

        let texts = [
            planNode.description,
            callVariant?.description,
        ].compactMap {
            $0
        }

        return !texts.contains {
            $0.localizedCaseInsensitiveContains("targetable")
                || $0.localizedCaseInsensitiveContains("only on")
        }
    }

    private static func discriminator(
        _ name: String,
        in schema: JSONSchema
    ) -> String? {
        guard case .object(let properties, _) = schema.form,
              let property = properties.first(
                where: {
                    $0.name == name
                }
              ),
              case .constant(.string(let value)) = property.schema.form
        else {
            return nil
        }

        return value
    }

    // MARK: - Manifest

    private static func runManifestProbe(
        host: AgenticToolHost
    ) throws {
        let manifest = host.capabilityManifest()

        guard manifest.capabilities.contains(
            where: {
                $0.identifier.rawValue == EchoTool.identifier
                    && $0.isModelFacing
            }
        ) else {
            throw Failure.manifestMissingModelFacingTool
        }

        guard !manifest.capabilities.contains(
            where: {
                $0.identifier.rawValue == HostOnlyTool.identifier
                    && $0.isModelFacing
            }
        ) else {
            throw Failure.manifestIncludesHostOnlyTool
        }

        guard manifest.canonicalPlanExample != nil else {
            throw Failure.unexpectedModelFacingContract
        }

        let text = try host.capabilityManifestText()

        guard text.contains(EchoTool.identifier),
              text.contains("model_facing")
        else {
            throw Failure.manifestMissingModelFacingTool
        }

        guard !text.localizedCaseInsensitiveContains(
            "only on tool variants whose invocation schema advertises execution"
        ) else {
            throw Failure.planSchemaTargetableWording
        }
    }

    // MARK: - Parser acceptance paths

    private static func runParserAcceptanceProbe(
        host: AgenticToolHost
    ) throws {
        let parser = AgenticToolHostInvocationParser(
            registry: host.registry
        )

        let direct = try parser.parse(
            data(
                #"{"id":"positive-direct","name":"echo_fixture","input":{"text":"direct"},"execution":{"workspace":{"subpath":"AgenticMedia"}}}"#
            )
        )

        guard direct.action == .invoke,
              let directCall = direct.call,
              directCall.id == "positive-direct",
              directCall.name == EchoTool.identifier,
              try directCall.input.decode(EchoInput.self).text == "direct",
              direct.execution?.workspace?.subpath == "AgenticMedia",
              direct.calls == nil,
              direct.plan == nil
        else {
            throw Failure.directParseMismatch
        }

        let batch = try parser.parse(
            data(
                #"[{"id":"positive-batch-1","name":"echo_fixture","input":{"text":"one"}},{"id":"positive-batch-2","name":"echo_fixture","input":{"text":"two"}}]"#
            )
        )

        guard batch.action == .invoke,
              batch.call == nil,
              batch.plan == nil,
              let calls = batch.calls,
              calls.count == 2,
              calls[0].id == "positive-batch-1",
              calls[0].name == EchoTool.identifier,
              try calls[0].input.decode(EchoInput.self).text == "one",
              calls[1].id == "positive-batch-2",
              calls[1].name == EchoTool.identifier,
              try calls[1].input.decode(EchoInput.self).text == "two"
        else {
            throw Failure.batchParseMismatch
        }

        let plan = try parser.parse(
            data(
                #"{"id":"positive-plan","root":{"kind":"call","call":{"id":"positive-plan-call","name":"echo_fixture","input":{"text":"plan"}},"execution":{"workspace":{"subpath":"AgenticMedia"}},"children":[],"onSuccess":[],"onFailure":[],"onDenied":[]},"references":[]}"#
            )
        )

        guard plan.action == .invoke,
              plan.call == nil,
              plan.calls == nil,
              let materializedPlan = plan.plan,
              materializedPlan.id == "positive-plan",
              case .call(
                let planCall,
                let execution,
                _,
                _,
                _
              ) = materializedPlan.root,
              planCall.id == "positive-plan-call",
              planCall.name == EchoTool.identifier,
              try planCall.input.decode(EchoInput.self).text == "plan",
              execution?.workspace?.subpath == "AgenticMedia"
        else {
            throw Failure.planParseMismatch
        }

        // Sparse recursive plans must pass schema admission and DTO decoding.
        let sparse = try parser.parse(
            data(
                #"{"id":"sparse-plan","root":{"kind":"sequence","children":[{"kind":"call","call":{"id":"sparse-call","name":"echo_fixture","input":{"text":"sparse"}},"onSuccess":[{"kind":"call","call":{"id":"sparse-branch","name":"echo_fixture","input":{"text":"branch"}}}]},{"kind":"batch"}]}}"#
            )
        )
        guard let sparsePlan = sparse.plan,
              sparsePlan.references.isEmpty,
              case .sequence(let nodes) = sparsePlan.root,
              nodes.count == 2,
              case .call(let call, _, let success, let failure, let denied) = nodes[0],
              call.id == "sparse-call",
              success.count == 1,
              failure.isEmpty,
              denied.isEmpty,
              case .call(let branch, _, _, _, _) = success[0],
              branch.id == "sparse-branch",
              case .batch(let empty) = nodes[1],
              empty.isEmpty else {
            throw Failure.planParseMismatch
        }

        // All node arrays may be omitted, including children on an empty sequence.
        let emptySequence = try parser.parse(
            data(#"{"id":"empty-sequence","root":{"kind":"sequence"}}"#)
        )
        guard let emptyPlan = emptySequence.plan,
              case .sequence(let emptyChildren) = emptyPlan.root,
              emptyChildren.isEmpty else {
            throw Failure.planParseMismatch
        }
    }

    // MARK: - Parser rejection paths

    private static func runParserRejectionProbe(
        host: AgenticToolHost
    ) throws {
        let parser = AgenticToolHostInvocationParser(
            registry: host.registry
        )

        try expectRejected {
            try parser.parse(
                data(#"{"id":"x","name":"unknown_tool","input":{}}"#)
            )
        }

        try expectRejected {
            try parser.parse(
                data("[]")
            )
        }

        try expectRejected {
            try parser.parse(
                data(#"{"kind":"call","call":{"id":"c","name":"echo_fixture","input":{}}}"#)
            )
        }

        // Explicit null is invalid; an omitted array alone means [].
        try expectRejected {
            try parser.parse(
                data(#"{"id":"null-arrays","root":{"kind":"call","call":{"id":"c","name":"echo_fixture","input":{"text":"ok"}},"children":null}}"#)
            )
        }

        // Prohibited nonempty ordinary children on call nodes stay invalid.
        try expectRejected {
            try parser.parse(
                data(#"{"id":"illegal-children","root":{"kind":"call","call":{"id":"c","name":"echo_fixture","input":{"text":"ok"}},"children":[{"kind":"call","call":{"id":"nested","name":"echo_fixture","input":{"text":"no"}}}]}}"#)
            )
        }
    }

    private static func expectRejected(
        _ body: () throws -> AgenticToolHostRequest
    ) throws {
        do {
            _ = try body()
            throw Failure.expectedRejection
        } catch is AgenticToolHostJSONError {
            return
        }
    }

    // MARK: - Fixture tooling

    private static func makeRegistry() throws -> ToolRegistry {
        try ToolRegistry {
            EchoTool()
            ToolBinding(
                HostOnlyTool(),
                modelContract: .hostOnly
            )
        }
    }

    private static func data(
        _ string: String
    ) -> Data {
        Data(string.utf8)
    }
}

private struct EchoInput:
    Sendable,
    Codable,
    JSONSchemaProviding
{
    let text: String

    static var jsonschema: JSONSchema {
        .any
    }
}

private struct EchoOutput:
    Sendable,
    Codable,
    JSONSchemaProviding
{
    let echoed: String

    static var jsonschema: JSONSchema {
        .any
    }
}

private struct EchoTool: Tool {
    typealias Input = EchoInput
    typealias Output = EchoOutput

    static let identifier = "echo_fixture"

    static let definition = ToolDefinition(
        identifier: .init(rawValue: identifier),
        purpose: "Fixture echo tool for tool-host regression.",
        risk: .observe
    )

    func call(
        _ input: Input,
        in _: CapabilityContext
    ) async throws -> Output {
        .init(
            echoed: input.text
        )
    }
}

private struct HostOnlyTool: Tool {
    typealias Input = EchoInput
    typealias Output = EchoOutput

    static let identifier = "host_only_fixture"

    static let definition = ToolDefinition(
        identifier: .init(rawValue: identifier),
        purpose: "Fixture host-only tool for tool-host regression.",
        risk: .observe
    )

    func call(
        _ input: Input,
        in _: CapabilityContext
    ) async throws -> Output {
        .init(
            echoed: input.text
        )
    }
}
