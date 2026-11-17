import Agentic
import Foundation
import Writers

public extension AgentHost {
    struct CoordinatedMutationReview: Sendable, Identifiable {
        public let id: UUID
        /// The staged plan; nil when only written changes are under review.
        public let plan: StandardMutationPlan?
        public let submissionIDs: [UUID]
        /// The staged changes as one review diff, a section per file.
        public let difference: ToolPreflight.Preview.Difference?
        /// Which run staged each submission and what it changes.
        public let origins: [Origin]

        public init(
            id: UUID,
            plan: StandardMutationPlan?,
            submissionIDs: [UUID],
            difference: ToolPreflight.Preview.Difference? = nil,
            origins: [Origin] = []
        ) {
            self.id = id
            self.plan = plan
            self.submissionIDs = submissionIDs
            self.difference = difference
            self.origins = origins
        }

        public struct Origin: Sendable, Hashable {
            public let submissionID: UUID
            /// The run that staged it, e.g. a delegated worker's run.
            public let runID: String?
            /// Changed paths, relative to the workspace root where possible.
            public let paths: [String]
            /// This submission's changes alone, to be judged on their own.
            public let difference: ToolPreflight.Preview.Difference?
            /// Already written: keep or roll back. Its `submissionID` is then
            /// the publication's identity.
            public let isPublished: Bool

            public init(
                submissionID: UUID,
                runID: String?,
                paths: [String],
                difference: ToolPreflight.Preview.Difference? = nil,
                isPublished: Bool = false
            ) {
                self.isPublished = isPublished
                self.submissionID = submissionID
                self.runID = runID
                self.paths = paths
                self.difference = difference
            }
        }
    }
}
