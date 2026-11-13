import AgenticInterfaces
import AgenticRuntime

public extension AgenticApprovalPrompt {
    init(
        pendingApproval: PendingApproval,
        title: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.init(
            title: title,
            functionCall: pendingApproval.functionCall,
            preflight: pendingApproval.preflight,
            requirement: pendingApproval.requirement,
            metadata: metadata
        )
    }
}
