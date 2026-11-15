import Agentic
import Foundation
import Primitives

public extension AgentHost {
    /// An installed Inference invoked directly by the owner, e.g. from the
    /// command bar; not a model-facing call.
    struct InferenceInvocationRequest: Sendable {
        public var inference: InferenceIdentifier
        public var input: JSONValue
        /// The conversation it was invoked from, for its log.
        public var session: Session.ID?

        public init(
            inference: InferenceIdentifier,
            input: JSONValue,
            session: Session.ID? = nil
        ) {
            self.inference = inference
            self.input = input
            self.session = session
        }
    }

    struct InferenceInvocationResult: Sendable {
        public var output: JSONValue
        public var record: InferenceExecutionRecord
    }
}
