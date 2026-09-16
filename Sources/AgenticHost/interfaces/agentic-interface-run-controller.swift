import Agentic
import AgenticExecution
import AgenticInterfaces
import AgenticModels
import AgenticRuntime
import AgenticUsage
import AgenticWorkspace

public struct AgenticInterfaceRunControllerResult: Sendable {
    public var preparation: ModeRunPreparation
    public var initialResult: AgentRunResult
    public var finalResult: AgentRunResult?
    public var pendingApproval: PendingApproval?
    public var approvalChoice: AgenticApprovalChoice?
    public var pendingWorkspaceAccess: WorkspaceAccessRequest?
    public var workspaceAccessChoice: AgenticWorkspaceAccessChoice?
    public var stoppedReason: String?

    public init(
        preparation: ModeRunPreparation,
        initialResult: AgentRunResult,
        finalResult: AgentRunResult? = nil,
        pendingApproval: PendingApproval? = nil,
        approvalChoice: AgenticApprovalChoice? = nil,
        pendingWorkspaceAccess: WorkspaceAccessRequest? = nil,
        workspaceAccessChoice: AgenticWorkspaceAccessChoice? = nil,
        stoppedReason: String? = nil
    ) {
        self.preparation = preparation
        self.initialResult = initialResult
        self.finalResult = finalResult
        self.pendingApproval = pendingApproval
        self.approvalChoice = approvalChoice
        self.pendingWorkspaceAccess = pendingWorkspaceAccess
        self.workspaceAccessChoice = workspaceAccessChoice
        self.stoppedReason = stoppedReason
    }

    public var result: AgentRunResult {
        finalResult ?? initialResult
    }

    public var isCompleted: Bool {
        result.isCompleted
    }

    public var isStopped: Bool {
        stoppedReason != nil
    }

    public var isAwaitingApproval: Bool {
        result.isAwaitingApproval
    }

    public var isAwaitingUserInput: Bool {
        result.isAwaitingUserInput
    }

    public var isAwaitingWorkspaceAccess: Bool {
        result.isAwaitingWorkspaceAccess
    }
}

public struct AgenticInterfaceRunController: Sendable {
    public var presenter: any AgenticRunPresenter
    public var approvalChooser: any AgenticApprovalChoosing
    public var workspaceAccessChooser: (any AgenticWorkspaceAccessChoosing)?

    public init(
        presenter: any AgenticRunPresenter,
        approvalChooser: any AgenticApprovalChoosing,
        workspaceAccessChooser: (any AgenticWorkspaceAccessChoosing)? = nil
    ) {
        self.presenter = presenter
        self.approvalChooser = approvalChooser
        self.workspaceAccessChooser = workspaceAccessChooser
    }

    public func run(
        _ preparation: ModeRunPreparation,
        model: AgentRuntimeServices.Model,
        sessionID: String? = nil,
        tooling: AgentRuntimeServices.Tooling = .init(),
        extensions: [any AgentHarnessExtension] = [],
        recording: AgentRuntimeServices.Recording = .init(),
        resumeMetadata: [String: String] = [:]
    ) async throws -> AgenticInterfaceRunControllerResult {
        let runner = preparation.runner(
            model: model,
            tooling: tooling,
            extensions: extensions,
            recording: recording
        )

        try await presenter.present(
            .modeRunStarted(
                preparation.command
            )
        )

        let initialResult: AgentRunResult

        if let sessionID {
            initialResult = try await runner.run(
                preparation.request,
                sessionID: sessionID
            )
        } else {
            initialResult = try await runner.run(
                preparation.request
            )
        }

        if let pendingWorkspaceAccess = initialResult.pendingWorkspaceAccess {
            try await presenter.present(
                AgenticRunPresentation(
                    initialResult
                )
            )

            guard let workspaceAccessChooser else {
                return .init(
                    preparation: preparation,
                    initialResult: initialResult,
                    pendingWorkspaceAccess: pendingWorkspaceAccess
                )
            }

            guard let interactionRequest = initialResult.interactionRequest,
                  interactionRequest.kind == .workspace_access
            else {
                preconditionFailure(
                    "Pending workspace access without a workspace-access interaction request."
                )
            }

            let choice = try await workspaceAccessChooser.choose(
                AgenticWorkspaceAccessPresentation.prompt(
                    pendingWorkspaceAccess
                )
            )
            let resolution: WorkspaceAccessResolution

            switch choice {
            case .grant_for_turn:
                resolution = .grant_for_turn

            case .grant_for_session:
                resolution = .grant_for_session

            case .deny:
                resolution = .deny
            }

            let interactionResponse = AgentInteraction.Response(
                request: interactionRequest,
                resolution: .workspace_access(
                    resolution
                ),
                metadata: resumeMetadata
            )
            let finalResult = try await runner.resume(
                interaction: interactionResponse
            )

            try await presenter.present(
                AgenticRunPresentation(
                    finalResult
                )
            )

            return .init(
                preparation: preparation,
                initialResult: initialResult,
                finalResult: finalResult,
                pendingWorkspaceAccess: pendingWorkspaceAccess,
                workspaceAccessChoice: choice
            )
        }

        guard let pendingApproval = initialResult.pendingApproval else {
            try await presenter.present(
                AgenticRunPresentation(
                    initialResult
                )
            )

            return .init(
                preparation: preparation,
                initialResult: initialResult
            )
        }

        try await presenter.present(
            .toolCallProposed(
                pendingApproval.toolCall
            )
        )

        try await presenter.present(
            .toolPreflight(
                pendingApproval.preflight
            )
        )

        try await presenter.present(
            AgenticRunPresentation(
                initialResult
            )
        )

        let approvalPrompt = AgenticApprovalPrompt(
            pendingApproval: pendingApproval,
            title: "Runtime suspended for approval"
        )
        guard let interactionRequest = initialResult.interactionRequest else {
            preconditionFailure(
                "Pending approval without an interaction request."
            )
        }

        let choice = try await approvalChooser.choose(
            approvalPrompt
        )

        switch choice {
        case .approve,
             .deny,
             .skip:
            let approvalDecision: ApprovalDecision

            switch choice {
            case .approve:
                approvalDecision = .approved

            case .deny:
                approvalDecision = .denied

            case .skip:
                approvalDecision = .skipped

            case .inspect_details,
                 .show_diff,
                 .stop_run:
                preconditionFailure(
                    "Non-resolution approval choice entered approval resume path."
                )
            }

            try await presenter.present(
                .approvalDecision(
                    approvalDecision
                )
            )

            let interactionResponse = AgentInteraction.Response(
                request: interactionRequest,
                resolution: .approval(
                    approvalDecision
                ),
                metadata: resumeMetadata
            )
            let finalResult = try await runner.resume(
                interaction: interactionResponse
            )

            try await presenter.present(
                AgenticRunPresentation(
                    finalResult
                )
            )

            return .init(
                preparation: preparation,
                initialResult: initialResult,
                finalResult: finalResult,
                pendingApproval: pendingApproval,
                approvalChoice: choice
            )

        case .stop_run:
            let reason = "User stopped the run from the approval picker."

            try await presenter.present(
                .runStopped(
                    reason: reason
                )
            )

            return .init(
                preparation: preparation,
                initialResult: initialResult,
                pendingApproval: pendingApproval,
                approvalChoice: choice,
                stoppedReason: reason
            )

        case .inspect_details,
             .show_diff:
            let reason = "Unexpected non-terminal picker choice escaped picker loop."

            try await presenter.present(
                .runStopped(
                    reason: reason
                )
            )

            return .init(
                preparation: preparation,
                initialResult: initialResult,
                pendingApproval: pendingApproval,
                approvalChoice: choice,
                stoppedReason: reason
            )
        }
    }
}
