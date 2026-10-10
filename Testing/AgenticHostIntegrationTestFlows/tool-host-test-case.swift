import Workspace
import Agentic
import AgenticInterfaces
import Foundation
import Primitives
import Schema
import Macros
import TestFlows

enum ToolHostTestCase {
    static func makeListDescribe() -> AgenticInterfaceTestCase {
        .init(
            id: "tool-host-list-describe",
            summary: "List and describe registered tools through AgenticToolHost."
        ) { _ in
            try await runListDescribe()
        }
    }

    static func makeJSONRoundtrip() -> AgenticInterfaceTestCase {
        .init(
            id: "tool-host-json-roundtrip",
            summary: "Round-trip tool-host request and response envelopes through JSON."
        ) { _ in
            try await runJSONRoundtrip()
        }
    }

    static func makeInvocationInputDecoding() -> AgenticInterfaceTestCase {
        .init(
            id: "tool-host-invocation-input-decoding",
            summary: "Decode bare calls, call arrays, and recursive plans into host invoke requests."
        ) { _ in
            try await runInvocationInputDecoding()
        }
    }

    static func makeInvokeBatch() -> AgenticInterfaceTestCase {
        .init(
            id: "tool-host-invoke-batch",
            summary: "Invoke independent ToolCall siblings through one host batch."
        ) { _ in
            try await runInvokeBatch()
        }
    }

    static func makeInvokePlan() -> AgenticInterfaceTestCase {
        .init(
            id: "tool-host-invoke-plan",
            summary: "Invoke a recursive AgentToolPlan through the governed host."
        ) { _ in
            try await runInvokePlan()
        }
    }

    static func makePreflightNoExecution() -> AgenticInterfaceTestCase {
        .init(
            id: "tool-host-preflight-no-execution",
            summary: "Preflight a host tool call without executing it."
        ) { _ in
            try await runPreflightNoExecution()
        }
    }

    static func makeInvokeObserve() -> AgenticInterfaceTestCase {
        .init(
            id: "tool-host-invoke-observe",
            summary: "Invoke an observe tool through governed host-call execution."
        ) { _ in
            try await runInvokeObserve()
        }
    }

    static func makeInvokeApprovedReview() -> AgenticInterfaceTestCase {
        .init(
            id: "tool-host-invoke-approved-review",
            summary: "Route approval-gated host invocation through ToolApprovalHandler."
        ) { _ in
            try await runInvokeApprovedReview()
        }
    }
    static func makeCapabilityManifest()
        -> AgenticInterfaceTestCase
    {
        .init(
            id: "tool-host-capability-manifest",
            summary:
                "Render the canonical registered-tool capability manifest."
        ) { _ in
            try await runCapabilityManifest()
        }
    }

}

private extension ToolHostTestCase {
    static func runCapabilityManifest() async throws {
        let probe =
            ToolHostProbe()

        let host =
            makeHost(
                risk: .privileged,
                autonomyMode: .auto_observe,
                probe: probe
            )

        let manifest =
            host.capabilityManifest()

        try Expect.equal(
            manifest.sessionID,
            Optional(
                "tool-host-session"
            ),
            "manifest retains host session identity"
        )

        guard
            manifest.capabilities.count == 1,
            let capability =
                manifest.capabilities.first
        else {
            throw toolHostAssertionFailure(
                "Expected exactly one tool capability in capability manifest fixture."
            )
        }

        try Expect.equal(
            capability.identifier.rawValue,
            "tool_host_probe",
            "manifest retains registered tool identifier"
        )

        try Expect.equal(
            capability.risk,
            ActionRisk.privileged,
            "manifest retains canonical tool risk"
        )

        guard
            let example = manifest.canonicalPlanExample,
            let exampleNode = example.root.children.first,
            let exampleCall = exampleNode.call
        else {
            throw toolHostAssertionFailure(
                "Expected capability manifest to generate one canonical AgentToolPlan example."
            )
        }

        try Expect.equal(
            example.root.kind,
            .sequence,
            "canonical manifest example uses AgentToolPlan sequence"
        )

        try Expect.equal(
            exampleCall.tool.rawValue,
            "tool_host_probe",
            "canonical manifest example derives its tool name from the live registry"
        )

        try Expect.equal(
            exampleNode.execution != nil,
            true,
            "canonical manifest example demonstrates workspace targeting for a targetable tool"
        )

        let rendered =
            try host.capabilityManifestText()

        let required = [
            "AGENTIC CAPABILITY MANIFEST",
            "Workspace authority root:",
            "Session:",
            "    tool-host-session",
            "Available tools (1):",
            "tool_host_probe",
            "    risk: privileged",
            "    workspace_targeting: supported",
            "Invocation schema:",
            "Canonical AgentToolPlan example:",
            "Protocol guidance:",
            "\"$defs\"",
            "\"oneOf\"",
            "\"const\"",
            "\"subpath\"",
            "DependentPackage",
            "Treat the Invocation schema as the authoritative local host-call grammar",
            "Do not invent action/request/tool_call/tool_calls wrappers",
            "For multi-step or dependent work, prefer one AgentToolPlan",
            "swift_package_update",
            "Use execution.workspace.subpath only on tool variants whose Invocation schema advertises execution.",
            "Treat Agentic invocation and AgentToolPlan results as authoritative execution state.",
        ]

        for token in required {
            guard rendered.contains(
                token
            ) else {
                throw toolHostAssertionFailure(
                    "Capability manifest missing expected text: \(token)"
                )
            }
        }
    }

    static func runListDescribe() async throws {
        let probe = ToolHostProbe()
        let host = makeHost(
            risk: .observe,
            autonomyMode: .auto_observe,
            probe: probe
        )

        let listed = try await host.execute(
            .init(
                action: .list
            )
        )

        guard let definitions = listed.definitions else {
            throw toolHostAssertionFailure(
                "Expected list action to return tool definitions."
            )
        }

        try Expect.equal(
            definitions.map(\.name),
            [
                "tool_host_probe"
            ],
            "tool host lists exact registry definitions"
        )

        let described = try await host.execute(
            .init(
                action: .describe,
                name: "tool_host_probe"
            )
        )

        guard let definition = described.definition else {
            throw toolHostAssertionFailure(
                "Expected describe action to return one definition."
            )
        }

        try Expect.equal(
            definition.name,
            "tool_host_probe",
            "tool host describes named tool"
        )
    }

    static func runJSONRoundtrip() async throws {
        let request = AgenticToolHostRequest(
            action: .describe,
            name: "tool_host_probe"
        )

        let requestData = try AgenticToolHostJSON.encode(
            request
        )

        let decodedRequest = try AgenticToolHostJSON.decodeRequest(
            requestData
        )

        try Expect.equal(
            decodedRequest,
            request,
            "tool host request JSON roundtrip"
        )

        let probe = ToolHostProbe()
        let host = makeHost(
            risk: .observe,
            autonomyMode: .auto_observe,
            probe: probe
        )

        let envelope = try await host.execute(
            decodedRequest
        )

        let envelopeData = try AgenticToolHostJSON.encode(
            envelope
        )

        let decodedEnvelope = try AgenticToolHostJSON.decodeEnvelope(
            envelopeData
        )

        try Expect.equal(
            decodedEnvelope,
            envelope,
            "tool host envelope JSON roundtrip"
        )

        let json = try AgenticToolHostJSON.encodeString(
            envelope
        )

        try Expect.equal(
            json.contains("\"action\":\"describe\""),
            true,
            "machine JSON includes action"
        )

        try Expect.equal(
            json.contains("\"tool_host_probe\""),
            true,
            "machine JSON includes tool identifier"
        )
    }

    static func runInvocationInputDecoding() async throws {
        let host = makeHost(
            risk: .observe,
            autonomyMode: .auto_observe,
            probe: ToolHostProbe()
        )

        let first = try makeCall(
            marker: "decode-first"
        )
        let second = try makeCall(
            marker: "decode-second"
        )

        let callData = try JSONEncoder().encode(
            first
        )
        let callRequest = try host
            .decodeInvocationRequest(
                callData
            )

        try Expect.equal(
            callRequest.call,
            Optional(
                first
            ),
            "bare ToolCall decodes as canonical direct invocation"
        )

        let targeted = AgenticToolHostDirectInvocation(
            id: first.id,
            name: first.tool.rawValue,
            input: first.input,
            execution: .init(
                workspace: .init(
                    subpath: "AgenticRuntime"
                )
            )
        )
        let targetedData = try JSONEncoder().encode(
            targeted
        )
        let targetedRequest = try host
            .decodeInvocationRequest(
                targetedData
            )

        try Expect.equal(
            targetedRequest.execution?.workspace?.subpath,
            Optional(
                "AgenticRuntime"
            ),
            "canonical direct invocation preserves execution.workspace.subpath"
        )

        let calls = [
            first,
            second,
        ]
        let callsData = try JSONEncoder().encode(
            calls
        )
        let callsRequest = try host
            .decodeInvocationRequest(
                callsData
            )

        try Expect.equal(
            callsRequest.calls,
            Optional(
                calls
            ),
            "ToolCall array decodes as canonical invoke batch"
        )

        let plan = try ToolPlan(
            id: "tool-host-decode-plan",
            root: .sequence(
                calls.map {
                    .call(
                        $0
                    )
                }
            )
        )
        let planData = try JSONEncoder().encode(
            plan
        )
        let planRequest = try host
            .decodeInvocationRequest(
                planData
            )

        try Expect.equal(
            planRequest.plan,
            Optional(
                plan
            ),
            "AgentToolPlan decodes through the canonical plan wire representation"
        )

        let wrapped = AgenticToolHostRequest(
            action: .invoke,
            call: first
        )
        let wrappedData = try AgenticToolHostJSON.encode(
            wrapped
        )

        do {
            _ = try host.decodeInvocationRequest(
                wrappedData
            )

            throw toolHostAssertionFailure(
                "Canonical invocation decoding must reject legacy action/invoke wrappers."
            )
        } catch AgenticToolHostJSONError.invalidInvocationRequest {
            // Expected: the manifest grammar is now the only canonical invocation envelope.
        }
    }

    static func runInvokeBatch() async throws {
        let probe = ToolHostProbe()
        let host = makeHost(
            risk: .observe,
            autonomyMode: .auto_observe,
            probe: probe
        )
        let calls = [
            try makeCall(
                marker: "batch-first"
            ),
            try makeCall(
                marker: "batch-second"
            ),
        ]

        let envelope = try await host.execute(
            .init(
                action: .invoke,
                calls: calls
            )
        )

        guard let result = envelope.planResult else {
            throw toolHostAssertionFailure(
                "Expected batch host invocation to return an AgentToolPlanResult."
            )
        }

        try Expect.equal(
            result.outcome,
            .succeeded,
            "batch host invocation succeeds"
        )

        try Expect.equal(
            result.records.map(\.call.id),
            calls.map(\.id),
            "batch host invocation preserves call order"
        )

        try Expect.equal(
            await probe.count(),
            2,
            "batch host invocation executes both calls"
        )
    }

    static func runInvokePlan() async throws {
        let probe = ToolHostProbe()
        let host = makeHost(
            risk: .observe,
            autonomyMode: .auto_observe,
            probe: probe
        )

        let first = try makeCall(
            marker: "plan-first"
        )
        let second = try makeCall(
            marker: "plan-second"
        )
        let nested = try makeCall(
            marker: "plan-nested"
        )

        let plan = try ToolPlan(
            id: "tool-host-recursive-plan",
            root: .sequence(
                [
                    .call(
                        first
                    ),
                    .call(
                        second,
                        onSuccess: [
                            .call(
                                nested
                            ),
                        ]
                    ),
                ]
            )
        )

        let envelope = try await host.execute(
            .init(
                action: .invoke,
                plan: plan
            )
        )

        guard let result = envelope.planResult else {
            throw toolHostAssertionFailure(
                "Expected recursive host invocation to return an AgentToolPlanResult."
            )
        }

        try Expect.equal(
            result.planID,
            plan.id,
            "host preserves plan identity"
        )

        try Expect.equal(
            result.outcome,
            .succeeded,
            "recursive host plan succeeds"
        )

        try Expect.equal(
            result.records.map(\.call.id),
            [
                first.id,
                second.id,
                nested.id,
            ],
            "recursive host plan preserves nested execution order"
        )

        try Expect.equal(
            await probe.count(),
            3,
            "recursive host plan executes every reachable call once"
        )
    }

    static func runPreflightNoExecution() async throws {
        let probe = ToolHostProbe()
        let host = makeHost(
            risk: .observe,
            autonomyMode: .auto_observe,
            probe: probe
        )
        let call = try makeCall(
            marker: "preflight"
        )

        let envelope = try await host.execute(
            .init(
                action: .preflight,
                call: call
            )
        )

        guard let review = envelope.review else {
            throw toolHostAssertionFailure(
                "Expected preflight action to return review."
            )
        }

        let executionCount = await probe.count()

        try Expect.equal(
            ToolCall(id: review.invocation.id, tool: review.invocation.tool, input: review.invocation.arguments),
            call,
            "preflight retains exact ToolCall"
        )

        try Expect.equal(
            review.requirement,
            .no_approval_needed,
            "observe preflight is automatically allowed"
        )

        try Expect.equal(
            executionCount,
            0,
            "preflight never executes"
        )
    }

    static func runInvokeObserve() async throws {
        let probe = ToolHostProbe()
        let host = makeHost(
            risk: .observe,
            autonomyMode: .auto_observe,
            probe: probe
        )
        let call = try makeCall(
            marker: "observe"
        )

        let envelope = try await host.execute(
            .init(
                action: .invoke,
                call: call
            )
        )

        guard
            let invocation = envelope.invocation,
            let toolResult = invocation.execution?.result
        else {
            throw toolHostAssertionFailure(
                "Expected observe host invocation to execute."
            )
        }

        let output = try toolResult.output.decode(
            ToolHostProbeOutput.self
        )

        let executionCount = await probe.count()

        try Expect.equal(
            invocation.decision,
            .approved,
            "observe host invocation approved"
        )

        try Expect.equal(
            invocation.executed,
            true,
            "observe host invocation reports execution"
        )

        try Expect.equal(
            executionCount,
            1,
            "observe host invocation executes once"
        )

        try Expect.equal(
            output.marker,
            "observe",
            "host transport preserves typed tool output"
        )

        try Expect.equal(
            toolResult.call.id,
            call.id,
            "host transport preserves tool call id"
        )

        try Expect.equal(
            toolResult.call.tool,
            call.tool,
            "host transport preserves tool identity"
        )
    }

    static func runInvokeApprovedReview() async throws {
        let probe = ToolHostProbe()
        let host = makeHost(
            risk: .boundedmutate,
            autonomyMode: .auto_observe,
            probe: probe,
            approvalHandler: StaticToolHostApprovalHandler(
                decision: .approved
            )
        )
        let call = try makeCall(
            marker: "approved"
        )

        let envelope = try await host.execute(
            .init(
                action: .invoke,
                call: call
            )
        )

        guard let invocation = envelope.invocation else {
            throw toolHostAssertionFailure(
                "Expected approval-gated host invocation result."
            )
        }

        let executionCount = await probe.count()

        try Expect.equal(
            invocation.review.requirement,
            .needs_human_review,
            "bounded mutation enters human review"
        )

        try Expect.equal(
            invocation.decision,
            .approved,
            "host approval handler decision is honored"
        )

        try Expect.equal(
            invocation.executed,
            true,
            "approved host invocation executes"
        )

        try Expect.equal(
            executionCount,
            1,
            "approved host invocation executes exactly once"
        )
    }
}

private actor ToolHostProbe {
    private var executionCount = 0

    func record() {
        executionCount += 1
    }

    func count() -> Int {
        executionCount
    }
}

private protocol ToolHostProbeRisk: Sendable {
    static var risk: ActionRisk { get }
}

private enum ToolHostObserveRisk: ToolHostProbeRisk {
    static let risk: ActionRisk = .observe
}

private enum ToolHostMutatingRisk: ToolHostProbeRisk {
    static let risk: ActionRisk = .boundedmutate
}

private struct ToolHostProbeTool<Risk: ToolHostProbeRisk>: Tool {
    typealias Input = ToolHostProbeInput
    typealias Output = ToolHostProbeOutput

    static var definition: ToolDefinition {
        ToolDefinition(
            identifier: .init(
                rawValue: "tool_host_probe"
            ),
            purpose: "Records one interface-hosted Agentic tool call.",
            risk: Risk.risk
        )
    }

    let probe: ToolHostProbe

    func call(
        _ input: Input,
        in _: ToolContext
    ) async throws -> Output {
        await probe.record()

        return ToolHostProbeOutput(
            marker: input.marker
        )
    }
}

@JSONSchema
private struct ToolHostProbeInput: HashableSource {
    let marker: String
}

@JSONSchema
private struct ToolHostProbeOutput: HashableResult {
    let marker: String
}

private struct StaticToolHostApprovalHandler: ToolApprovalHandler {
    let decision: ApprovalDecision

    func decide(
        on _: ToolInvocation.Review
    ) async throws -> ApprovalDecision {
        decision
    }
}

private extension ToolHostTestCase {
    static func makeHost(
        risk: ActionRisk,
        autonomyMode: AutonomyMode,
        probe: ToolHostProbe,
        approvalHandler: (any ToolApprovalHandler)? = nil
    ) -> AgenticToolHost {
        var registry = ToolRegistry()

        switch risk {
        case .observe:
            try! registry.register(
                ToolHostProbeTool<ToolHostObserveRisk>(
                    probe: probe
                )
            )

        case .boundedmutate:
            try! registry.register(
                ToolHostProbeTool<ToolHostMutatingRisk>(
                    probe: probe
                )
            )

        case .privileged,
             .forbidden:
            preconditionFailure(
                "ToolHostTestCase only exercises observe and bounded mutation risk."
            )
        }

        return AgenticToolHost(
            registry: registry,
            policy: .init(
                autonomyMode: autonomyMode
            ),
            approvalHandler: approvalHandler
        )
    }

    static func makeCall(
        marker: String
    ) throws -> ToolCall {
        ToolCall(
            id: "tool-host-\(marker)",
            tool: .init(
                rawValue: "tool_host_probe"
            ),
            input: try JSONValue.encoding(
                ToolHostProbeInput(
                    marker: marker
                )
            )
        )
    }
}

private func toolHostAssertionFailure(
    _ message: String
) -> TestFlowAssertionFailure {
    TestFlowAssertionFailure(
        label: "tool host",
        message: message
    )
}
