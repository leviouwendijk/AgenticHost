import Foundation

import Foundation

enum FileContentComposer {
    static func compose(
        workspaceRoot: URL,
        generatedMiddle: PhilosophicalMiddleFragment,
        mutationToolName: String = "mutate_files"
    ) -> String {
        compose(
            workspaceRoot: workspaceRoot,
            middleLines: middleLines(
                generatedMiddle
            ),
            mutationToolName: mutationToolName
        )
    }

    static func seed(
        workspaceRoot: URL,
        mutationToolName: String = "mutate_files"
    ) -> String {
        compose(
            workspaceRoot: workspaceRoot,
            middleLines: [
                "--------------------------------",
                "The Dance of Awareness",
                "",
                "\"In the ordinary world, attention shapes agency into fleeting moments of choice.\"",
                "",
                "Every choice is a whisper in the vastness of attention, guiding the dance of agency through the fabric of the ordinary.",
                "--------------------------------",
            ],
            mutationToolName: mutationToolName
        )
    }

    static func middleLines(
        _ generatedMiddle: PhilosophicalMiddleFragment
    ) -> [String] {
        [
            "--------------------------------",
            generatedMiddle.title,
            "",
            "\"\(generatedMiddle.quote)\"",
            "",
            generatedMiddle.reflection,
            "--------------------------------",
        ]
    }

    private static func compose(
        workspaceRoot: URL,
        middleLines: [String],
        mutationToolName: String
    ) -> String {
        """
        hello from AgenticInterfaces

        This file was written through:
        model tool call -> AgentRunner suspension -> Terminal approval -> AgentRunner resume -> \(mutationToolName).

        Apple-generated middle fragment
        \(middleLines.joined(separator: "\n"))

        Workspace root: \(workspaceRoot.path)
        Generated at: \(Date().formatted(.iso8601))

        """
    }
}
