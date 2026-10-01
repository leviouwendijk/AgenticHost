import Agentic
import AgenticExecution
import AgenticInterfaces
import AgenticRuntime
import Workspace
import Foundation

public extension AgenticRuntime {
    func host(
        workspace:
            AgenticRuntimeWorkspaceConfiguration,
        sessionID: String? = nil,
        metadata: [String: String] = [:],
        approvalHandler: (any ToolApprovalHandler)? = nil
    ) throws -> AgenticToolHost {
        try makeHost(
            workspace: AgenticRuntimeWorkspace.resolve(
                workspace
            ),
            sessionID: sessionID,
            metadata: metadata,
            approvalHandler: approvalHandler
        )
    }

    func host(
        workspacePath: String? = nil,
        sessionID: String? = nil,
        metadata: [String: String] = [:],
        approvalHandler: (any ToolApprovalHandler)? = nil
    ) throws -> AgenticToolHost {
        let workspace: Workspace?

        if let workspacePath {
            workspace = try AgenticRuntimeWorkspace.resolve(
                workspacePath
            )
        } else {
            workspace = nil
        }

        return try makeHost(
            workspace: workspace,
            sessionID: sessionID,
            metadata: metadata,
            approvalHandler: approvalHandler
        )
    }
}

private extension AgenticRuntime {
    func makeHost(
        workspace: Workspace?,
        sessionID: String?,
        metadata: [String: String],
        approvalHandler: (any ToolApprovalHandler)?
    ) throws -> AgenticToolHost {
        return AgenticToolHost(
            registry: tools,
            policy: ToolExecutionPolicy(
                autonomyMode: .auto_observe
            ),
            workspace: try workspace?.context(),
            sessionID: sessionID,
            approvalHandler: approvalHandler
        )
    }
}

public enum AgenticHostApprovalError:
    Error,
    Sendable,
    LocalizedError
{
    case stoppedRun

    public var errorDescription: String? {
        switch self {
        case .stoppedRun:
            return "The run was stopped from the approval picker."
        }
    }
}

public struct AgenticHostApprovalHandler:
    ToolApprovalHandler
{
    public let chooser: any AgenticApprovalChoosing

    public init(
        chooser: any AgenticApprovalChoosing
    ) {
        self.chooser = chooser
    }

    public static func wrapping(
        chooser: (any AgenticApprovalChoosing)?
    ) -> (any ToolApprovalHandler)? {
        guard let chooser else {
            return nil
        }

        return Self(
            chooser: chooser
        )
    }

    public func decide(
        on review: ToolInvocation.Review
    ) async throws -> ApprovalDecision {
        try await decide(
            AgenticApprovalPrompt(
                review: review
            )
        )
    }

    public func decide(
        on preflight: ToolPreflight,
        requirement: ApprovalRequirement
    ) async throws -> ApprovalDecision {
        try await decide(
            AgenticApprovalPrompt(
                preflight: preflight,
                requirement: requirement
            )
        )
    }

    private func decide(
        _ prompt: AgenticApprovalPrompt
    ) async throws -> ApprovalDecision {
        if prompt.requirement.isDenied {
            return .denied
        }

        if !prompt.requirement.requiresHumanReview {
            return .approved
        }

        switch try await chooser.choose(
            prompt
        ) {
        case .approve:
            return .approved

        case .deny:
            return .denied

        case .skip:
            return .skipped

        case .stop_run:
            throw AgenticHostApprovalError.stoppedRun

        case .inspect_details,
             .show_diff:
            return .needshuman
        }
    }
}
