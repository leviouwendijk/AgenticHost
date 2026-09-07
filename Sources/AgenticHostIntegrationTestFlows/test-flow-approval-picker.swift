import Agentic
import AgenticInterfaces
import Difference
// import DifferenceTerminal
import Foundation
import TestFlows
import Terminal

struct TestFlowApprovalPicker: Sendable {
    var interaction: any TestFlowInteraction
    var presenter: (any AgenticRunPresenter)?

    init(
        interaction: any TestFlowInteraction,
        presenter: (any AgenticRunPresenter)? = nil
    ) {
        self.interaction = interaction
        self.presenter = presenter
    }

    func pick(
        _ prompt: AgenticApprovalPrompt
    ) async throws -> AgenticApprovalChoice {
        try await presenter?.present(
            .approvalRequested(
                prompt
            )
        )

        while true {
            let choice = try await pickChoice(
                prompt
            )

            try await presenter?.present(
                .approvalChoice(
                    choice
                )
            )

            switch choice {
            case .inspect_details:
                renderDetails(
                    prompt
                )

            case .show_diff:
                renderDiff(
                    prompt
                )

            case .approve,
                 .deny,
                 .skip,
                 .stop_run:
                return choice
            }
        }
    }
}

private extension TestFlowApprovalPicker {
    func pickChoice(
        _ prompt: AgenticApprovalPrompt
    ) async throws -> AgenticApprovalChoice {
        let choice: TestFlowChoice

        do {
            choice = try await interaction.choose(
                .init(
                    key: "approval-choice",
                    title: "\(prompt.title): \(prompt.toolName)",
                    summary: prompt.preflight.summary,
                    choices: AgenticApprovalChoice.allCases.map { choice in
                        TestFlowChoice(
                            id: choice.title,
                            title: choice.title,
                            summary: choice.summary
                        )
                    },
                    allowsCancel: true
                )
            )
        } catch let error as TestFlowInteractionError {
            if case .cancelled = error {
                return .stop_run
            }

            throw error
        }

        if let approvalChoice = AgenticApprovalChoice.allCases.first(where: { $0.title == choice.id }) {
            return approvalChoice
        }

        if let approvalChoice = AgenticApprovalChoice(
            rawValue: choice.id
        ) {
            return approvalChoice
        }

        throw TestFlowInteractionError.unknown_choice(
            key: "approval-choice",
            value: choice.id,
            available: AgenticApprovalChoice.allCases.map(\.title)
        )
    }

    func renderDetails(
        _ prompt: AgenticApprovalPrompt
    ) {
        let document = prompt.preflight.inspectionDocument(
            title: "Staged intent details",
            toolName: prompt.toolName,
            toolCallID: prompt.toolCall?.id,
            requirement: prompt.requirement
        )

        Terminal.write(
            AgenticTerminalInspectionRenderer.render(
                document,
                stream: .standardError,
                theme: .agentic,
                layout: .agentic
            ),
            to: .standardError
        )
    }

    func renderDiff(
        _ prompt: AgenticApprovalPrompt
    ) {
        guard let diffPreview = prompt.preflight.diffPreview,
              !diffPreview.isEmpty else {
            write(
                """

                no diff preview available

                """
            )

            return
        }

        let renderedDiff: String

        if let layout = diffPreview.layout,
           !layout.isEmpty {
            renderedDiff = TerminalDifferenceRenderer.render(
                layout,
                options: TerminalDifferenceRenderOptions(
                    base: DifferenceRenderOptions(
                        showHeader: true,
                        showUnchangedLines: false,
                        contextLineCount: diffPreview.contextLineCount
                    )
                )
            )
        } else {
            renderedDiff = diffPreview.text
        }

        guard !renderedDiff.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            write(
                """

                \(diffPreview.title ?? "diff preview")
                format: \(diffPreview.format)
                context lines: \(diffPreview.contextLineCount)
                changes: +\(diffPreview.insertedLineCount) -\(diffPreview.deletedLineCount)

                diff preview body was empty even though preflight reported a diff preview

                """
            )

            return
        }

        write(
            """

            \(diffPreview.title ?? "diff preview")
            format: \(diffPreview.format)
            context lines: \(diffPreview.contextLineCount)
            changes: +\(diffPreview.insertedLineCount) -\(diffPreview.deletedLineCount)

            \(renderedDiff)

            """
        )
    }

    func write(
        _ text: String
    ) {
        fputs(
            text,
            stderr
        )
    }
}
