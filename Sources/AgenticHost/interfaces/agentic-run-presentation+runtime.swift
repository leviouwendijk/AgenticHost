import AgenticInterfaces
import AgenticRuntime

public extension AgenticRunPresentation {
    init(
        _ result: AgentRunResult
    ) {
        if let pendingApproval = result.pendingApproval {
            self.init(
                sessionID: result.sessionID,
                state: .awaiting_approval,
                toolName: pendingApproval.toolCall.name,
                summary: pendingApproval.preflight.summary
            )
            return
        }

        if result.isAwaitingUserInput {
            self.init(
                sessionID: result.sessionID,
                state: .awaiting_user_input
            )
            return
        }

        if result.isCompleted {
            self.init(
                sessionID: result.sessionID,
                state: .completed,
                body: result.response?.message.content.text
            )
            return
        }

        self.init(
            sessionID: result.sessionID,
            state: .active
        )
    }
}


public extension AgenticRunPresenter {
    func present(
        _ result: AgentRunResult
    ) async throws {
        try await present(
            AgenticRunPresentation(
                result
            )
        )
    }
}
