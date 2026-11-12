import Foundation
import Writers

public extension AgentHost {
    struct CoordinatedMutationReview: Sendable, Identifiable {
        public let id: UUID
        public let plan: StandardMutationPlan
        public let submissionIDs: [UUID]

        public init(
            id: UUID,
            plan: StandardMutationPlan,
            submissionIDs: [UUID]
        ) {
            self.id = id
            self.plan = plan
            self.submissionIDs = submissionIDs
        }
    }
}
