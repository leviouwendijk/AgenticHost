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
    public var approvalResolution: AgenticInterfaceApprovalResolution?
    public var stoppedReason: String?

    public init(
        preparation: ModeRunPreparation,
        initialResult: AgentRunResult,
        finalResult: AgentRunResult? = nil,
        pendingApproval: PendingApproval? = nil,
        approvalResolution: AgenticInterfaceApprovalResolution? = nil,
        stoppedReason: String? = nil
    ) {
        self.preparation = preparation
        self.initialResult = initialResult
        self.finalResult = finalResult
        self.pendingApproval = pendingApproval
        self.approvalResolution = approvalResolution
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
}

public struct AgenticInterfaceRunController: Sendable {
    public var presenter: any AgenticRunPresenter
    public var approvalDecider: any AgenticInterfaceApprovalDecider

    public init(
        presenter: any AgenticRunPresenter,
        approvalDecider: any AgenticInterfaceApprovalDecider
    ) {
        self.presenter = presenter
        self.approvalDecider = approvalDecider
    }

    public func run(
        _ preparation: ModeRunPreparation,
        modelBroker: AgentModelBroker,
        sessionID: String? = nil,
        workspace: AgentWorkspace? = nil,
        historyStore: (any AgentHistoryStore)? = nil,
        extensions: [any AgentHarnessExtension] = [],
        eventSinks: [any AgentRunEventSink] = [],
        costTracker: AgentCostTracker? = nil,
        resumeMetadata: [String: String] = [:]
    ) async throws -> AgenticInterfaceRunControllerResult {
        let runner = preparation.runner(
            modelBroker: modelBroker,
            extensions: extensions,
            workspace: workspace,
            historyStore: historyStore,
            eventSinks: eventSinks,
            costTracker: costTracker
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
        let resolution = try await approvalDecider.decide(
            approvalPrompt
        )

        switch resolution {
        case .approved,
             .denied,
             .skipped:
            guard let approvalDecision = resolution.approvalDecision else {
                preconditionFailure("Approval resolution without approval decision.")
            }

            try await presenter.present(
                .approvalDecision(
                    approvalDecision
                )
            )

            let finalResult = try await runner.resume(
                sessionID: initialResult.sessionID,
                approvalDecision: approvalDecision,
                metadata: resumeMetadata
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
                approvalResolution: resolution
            )

        case .stopped(let reason):
            try await presenter.present(
                .runStopped(
                    reason: reason
                )
            )

            return .init(
                preparation: preparation,
                initialResult: initialResult,
                pendingApproval: pendingApproval,
                approvalResolution: resolution,
                stoppedReason: reason
            )
        }
    }
}
