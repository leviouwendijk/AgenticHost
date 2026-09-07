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
            toolCall: pendingApproval.toolCall,
            preflight: pendingApproval.preflight,
            requirement: pendingApproval.requirement,
            metadata: metadata
        )
    }
}
