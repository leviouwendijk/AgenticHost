import Foundation
import TestFlows

enum AgenticInterfaceTestMenu {
    static func pick(
        _ tests: [AgenticInterfaceTestCase],
        interaction: any TestFlowInteraction
    ) async throws -> AgenticInterfaceTestCase {
        let sorted = tests.sorted {
            $0.id < $1.id
        }

        let displayIDs = Dictionary(
            uniqueKeysWithValues: sorted.map { test in
                (
                    displayTitle(
                        for: test
                    ),
                    test.id
                )
            }
        )

        let choice: TestFlowChoice

        do {
            choice = try await interaction.choose(
                .init(
                    key: "agentic-interface-case",
                    title: "Agentic interface test case",
                    summary: "Move with Ctrl-P/Ctrl-N or arrows. Enter picks. q/Esc cancels.",
                    choices: sorted.map { test in
                        let title = displayTitle(
                            for: test
                        )

                        return TestFlowChoice(
                            id: title,
                            title: title,
                            summary: test.summary
                        )
                    },
                    allowsCancel: true
                )
            )
        } catch let error as TestFlowInteractionError {
            if case .cancelled = error {
                throw AgenticInterfaceTestError.cancelled
            }

            throw error
        }

        guard let testID = displayIDs[choice.id],
              let test = sorted.first(where: { $0.id == testID }) else {
            throw AgenticInterfaceTestError.unknownTestCase(
                choice.id,
                available: sorted.map(\.id)
            )
        }

        return test
    }
}

private extension AgenticInterfaceTestMenu {
    static func displayTitle(
        for test: AgenticInterfaceTestCase
    ) -> String {
        test.id
            .split(
                separator: "-"
            )
            .map { part in
                if part.uppercased() == "AWS" {
                    return "AWS"
                }

                return part.prefix(1).uppercased() + part.dropFirst()
            }
            .joined(
                separator: " "
            )
    }
}
