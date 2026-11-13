import Agentic
import AgenticInterfaces

package enum ToolObservationPresentation {
    static func streams(
        _ observations: [ToolResultObservation],
        runID: String,
        stepID: String,
        prefix: String
    ) -> [AgenticHostConsoleDocumentPresentation] {
        let streams: [(ToolResultObservation.Kind, AgenticHostConsoleDocumentKind)] = [
            (.standard_output, .stdout),
            (.standard_error, .stderr),
        ]
        return streams.map { source, document in
            let body = observations.filter { $0.kind == source }.map(\.content).joined()
            return .init(
                id: "\(prefix):\(document.rawValue)",
                runID: runID,
                stepID: stepID,
                kind: document,
                body: body.isEmpty ? "\(document.rawValue) is empty." : body
            )
        }
    }

    static func details(_ observations: [ToolResultObservation]) -> String {
        observations.compactMap { observation in
            switch observation.kind {
            case .standard_output, .standard_error:
                return nil
            case .diagnostic, .log, .detail:
                return [observation.label ?? observation.kind.rawValue, observation.content]
                    .joined(separator: "\n")
            }
        }.joined(separator: "\n\n")
    }
}
