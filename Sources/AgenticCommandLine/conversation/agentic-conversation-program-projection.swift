import AgenticInterfaces
import AgenticPrograms
import AgenticRuntime
import Foundation
import Primitives

package enum AgenticConversationProgramProjection {
    package static func project(
        _ record: AgentProgramExecutionRecord,
        descriptor: AgentProgramDescriptor,
        id: String
    ) -> AgenticConversationProgramExecutionPresentation {
        AgenticConversationProgramExecutionPresentation(
            id: id,
            program: record.programIdentifier,
            title: descriptor.title,
            summary: descriptor.summary,
            realization: record.realizationIdentifier,
            outcome: outcome(record.outcome),
            input: render(record.input),
            output: record.output.map { output in
                render(output)
            },
            steps: record.steps.map { step in
                stepPresentation(step)
            },
            failure: record.failure?.message,
            durationMilliseconds: record.durationMilliseconds
        )
    }

    private static func outcome(
        _ outcome: AgentProgramExecutionOutcome
    ) -> AgenticConversationProgramExecutionOutcome {
        switch outcome {
        case .succeeded:
            return .succeeded
        case .failed:
            return .failed
        }
    }

    private static func stepPresentation(
        _ step: AgentProgramStepRecord
    ) -> AgenticConversationProgramStepPresentation {
        let title: String
        let semanticDetail: String?

        switch step.kind {
        case .inference(let site, let inference):
            title = "inference · \(site.rawValue)"
            semanticDetail = inference.rawValue

        case .tool(let identifier):
            title = "tool · \(identifier.rawValue)"
            semanticDetail = nil

        case .program(let identifier):
            title = "program · \(identifier.rawValue)"
            semanticDetail = nil
        }

        let details = [
            semanticDetail,
            step.failure?.message,
        ].compactMap { value in
            value
        }

        return AgenticConversationProgramStepPresentation(
            index: step.index,
            title: title,
            detail: details.isEmpty
                ? nil
                : details.joined(separator: " · "),
            failed: step.failure != nil,
            durationMilliseconds: step.durationMilliseconds
        )
    }

    private static func render(
        _ value: JSONValue
    ) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
        ]

        guard let data = try? encoder.encode(value),
              let text = String(
                data: data,
                encoding: .utf8
              ) else {
            return String(
                describing: value
            )
        }

        return text
    }
}
