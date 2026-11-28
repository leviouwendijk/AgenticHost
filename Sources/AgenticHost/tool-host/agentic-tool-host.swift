import Agentic
import Foundation
import Workspace

public enum AgenticToolHostAction:
    String,
    Sendable,
    Codable,
    Hashable
{
    case list
    case describe
    case preflight
    case invoke
}

public struct AgenticToolHostRequest:
    Sendable,
    Codable,
    Hashable
{
    public let action: AgenticToolHostAction
    public let name: String?
    public let call: FunctionCall?
    public let calls: [FunctionCall]?
    public let plan: ToolPlan?
    public let execution: ToolInvocation.Target?

    public init(
        action: AgenticToolHostAction,
        name: String? = nil,
        call: FunctionCall? = nil,
        calls: [FunctionCall]? = nil,
        plan: ToolPlan? = nil,
        execution: ToolInvocation.Target? = nil
    ) {
        self.action = action
        self.name = name
        self.call = call
        self.calls = calls
        self.plan = plan
        self.execution = execution
    }
}

public struct AgenticToolHostEnvelope:
    Sendable,
    Codable,
    Hashable
{
    public let action: AgenticToolHostAction
    public let definitions: [ToolDescriptor]?
    public let definition: ToolDescriptor?
    public let review: ToolInvocation.Review?
    public let invocation: ToolInvocation.Result?
    public let planResult: ToolPlan.Result?

    public init(
        action: AgenticToolHostAction,
        definitions: [ToolDescriptor]? = nil,
        definition: ToolDescriptor? = nil,
        review: ToolInvocation.Review? = nil,
        invocation: ToolInvocation.Result? = nil,
        planResult: ToolPlan.Result? = nil
    ) {
        self.action = action
        self.definitions = definitions
        self.definition = definition
        self.review = review
        self.invocation = invocation
        self.planResult = planResult
    }
}

public enum AgenticToolHostError:
    Error,
    LocalizedError,
    Sendable,
    Equatable
{
    case missingTool(String)
    case missingName(AgenticToolHostAction)
    case missingCall(AgenticToolHostAction)
    case invalidInvocationPayload(String)

    public var errorDescription: String? {
        switch self {
        case .missingTool(let name):
            return "No registered Agentic tool named '\(name)'."

        case .missingName(let action):
            return "Tool host action '\(action.rawValue)' requires a tool name."

        case .missingCall(let action):
            return "Tool host action '\(action.rawValue)' requires an FunctionCall."

        case .invalidInvocationPayload(let message):
            return message
        }
    }
}

public struct AgenticToolHost {
    public let registry: ToolRegistry
    public let tools: ToolExecutor
    public let workspace: WorkspaceContext?
    public let sessionID: String?
    public let approvalHandler: (any ToolApprovalHandler)?

    public init(
        registry: ToolRegistry,
        policy: ToolExecutionPolicy,
        workspace: WorkspaceContext? = nil,
        sessionID: String? = nil,
        approvalHandler: (any ToolApprovalHandler)? = nil
    ) {
        self.registry = registry
        self.tools = ToolExecutor(
            registry: registry,
            policy: policy
        )
        self.workspace = workspace
        self.sessionID = sessionID
        self.approvalHandler = approvalHandler
    }

    public func execute(
        _ request: AgenticToolHostRequest
    ) async throws -> AgenticToolHostEnvelope {
        switch request.action {
        case .list:
            return list()

        case .describe:
            guard let name = request.name else {
                throw AgenticToolHostError.missingName(
                    request.action
                )
            }

            return try describe(
                name
            )

        case .preflight:
            guard let call = request.call else {
                throw AgenticToolHostError.missingCall(
                    request.action
                )
            }

            return try await preflight(
                call,
                execution: request.execution
            )

        case .invoke:
            return try await invokePayload(
                request
            )
        }
    }

    public func list() -> AgenticToolHostEnvelope {
        .init(
            action: .list,
            definitions: registry.inspect().tools.map {
                ToolDescriptor(
                    identifier: $0.identifier,
                    description: $0.description,
                    risk: $0.risk
                )
            }
        )
    }

    public func describe(
        _ name: String
    ) throws -> AgenticToolHostEnvelope {
        guard let entry = registry.inspect().tools.first(
            where: {
                $0.identifier.rawValue == name
            }
        ) else {
            throw AgenticToolHostError.missingTool(
                name
            )
        }

        return .init(
            action: .describe,
            definition: ToolDescriptor(
                identifier: entry.identifier,
                description: entry.description,
                risk: entry.risk
            )
        )
    }

    public func preflight(
        _ call: FunctionCall,
        execution: ToolInvocation.Target? = nil
    ) async throws -> AgenticToolHostEnvelope {
        let review = try await tools.review(
            ToolInvocation(
                id: call.id,
                tool: ToolIdentifier(call.name),
                arguments: call.input,
                execution: execution
            ),
            context: context()
        )

        return .init(
            action: .preflight,
            review: review
        )
    }

    public func invoke(
        _ call: FunctionCall,
        execution: ToolInvocation.Target? = nil
    ) async throws -> AgenticToolHostEnvelope {
        let invocation = try await tools.invoke(
            ToolInvocation(
                id: call.id,
                tool: ToolIdentifier(call.name),
                arguments: call.input,
                execution: execution
            ),
            context: context(),
            approvalHandler: approvalHandler
        )

        return .init(
            action: .invoke,
            review: invocation.review,
            invocation: invocation
        )
    }

    public func invoke(
        _ calls: [FunctionCall]
    ) async throws -> AgenticToolHostEnvelope {
        guard !calls.isEmpty else {
            throw AgenticToolHostError.invalidInvocationPayload(
                "Tool host batch invocation requires at least one FunctionCall."
            )
        }

        return try await invoke(
            ToolPlan(
                root: .batch(
                    calls.map {
                        .call(
                            $0
                        )
                    }
                )
            )
        )
    }

    public func invoke(
        _ plan: ToolPlan
    ) async throws -> AgenticToolHostEnvelope {
        let result = try await tools.invoke(
            plan,
            in: context(),
            approvalHandler: approvalHandler
        )

        return .init(
            action: .invoke,
            planResult: result
        )
    }
}

private extension AgenticToolHost {
    func context() -> CapabilityContext {
        .init(
            workspace: workspace
        )
    }
    func invokePayload(
        _ request: AgenticToolHostRequest
    ) async throws -> AgenticToolHostEnvelope {
        let payloadCount = [
            request.call != nil,
            request.calls != nil,
            request.plan != nil,
        ].filter {
            $0
        }.count

        guard payloadCount == 1 else {
            throw AgenticToolHostError.invalidInvocationPayload(
                "Tool host invoke requires exactly one of call, calls, or plan."
            )
        }

        if request.execution != nil,
           request.call == nil
        {
            throw AgenticToolHostError.invalidInvocationPayload(
                "Request-level execution is only valid for a single direct call; plans carry execution on their call nodes."
            )
        }

        if let call = request.call {
            return try await invoke(
                call,
                execution: request.execution
            )
        }

        if let calls = request.calls {
            return try await invoke(
                calls
            )
        }

        if let plan = request.plan {
            return try await invoke(
                plan
            )
        }

        throw AgenticToolHostError.invalidInvocationPayload(
            "Tool host invoke requires an FunctionCall, call batch, or ToolPlan."
        )
    }
}
