import AgenticInterfaces
import AgenticCommandLine
import TestFlows

enum AgenticRuntimeHostStatusFlowTesting {
    enum Failure:
        Error
    {
        case workDidNotBegin
        case missingCompletion
        case missingStatus
        case missingGlobalStatus
    }

    static func runPersistentFailureStatus() async throws -> [TestFlowDiagnostic] {
        let work = HostWork()
        let diagnostic = "Automatic continuation from 'root.sequence[1]' is not supported because the next authored operation requires a different execution boundary."

        guard await work.begin(
            runID: "status-run",
            stepID: "status-step",
            label: "executing step"
        ) else {
            throw Failure.workDidNotBegin
        }

        await work.fail(
            diagnostic,
            title: "Execution attempt failed"
        )

        guard let completion = await work.takeCompletion() else {
            throw Failure.missingCompletion
        }

        try Expect.equal(
            completion,
            "Execution attempt failed · Status available",
            "failure completion remains concise"
        )

        let first = await work.project(
            AgenticHostConsoleSnapshot()
        )

        guard let status = first.statuses.first else {
            throw Failure.missingStatus
        }

        try Expect.equal(
            status.runID,
            "status-run",
            "status keeps run association"
        )
        try Expect.equal(
            status.stepID,
            "status-step",
            "status keeps step association"
        )
        try Expect.equal(
            status.kind,
            .error,
            "failure status kind"
        )
        try Expect.equal(
            status.title,
            "Execution attempt failed",
            "failure status title"
        )
        try Expect.equal(
            status.summary,
            "executing step",
            "failure status activity summary"
        )
        try Expect.equal(
            status.body,
            diagnostic,
            "failure status preserves complete diagnostic"
        )

        let second = await work.project(
            AgenticHostConsoleSnapshot()
        )

        try Expect.equal(
            second.statuses,
            first.statuses,
            "status persists after completion is consumed"
        )

        let globalNote = await work.recordStatus(
            "The clipboard did not contain a valid ToolPlan.",
            title: "Clipboard input failed",
            summary: "loading ToolPlan"
        )

        try Expect.equal(
            globalNote,
            "Clipboard input failed · Status available",
            "non-execution status feedback remains concise"
        )

        let third = await work.project(
            AgenticHostConsoleSnapshot()
        )

        guard let globalStatus = third.statuses.last else {
            throw Failure.missingGlobalStatus
        }

        try Expect.equal(
            third.statuses.count,
            2,
            "execution and global statuses coexist"
        )
        try Expect.equal(
            globalStatus.runID,
            Optional<String>.none,
            "global status does not invent a run association"
        )
        try Expect.equal(
            globalStatus.stepID,
            Optional<String>.none,
            "global status does not invent a step association"
        )
        try Expect.equal(
            globalStatus.title,
            "Clipboard input failed",
            "global status title"
        )
        try Expect.equal(
            globalStatus.summary,
            "loading ToolPlan",
            "global status operation summary"
        )
        try Expect.equal(
            globalStatus.body,
            "The clipboard did not contain a valid ToolPlan.",
            "global status preserves complete diagnostic"
        )

        return [
            .field(
                "status",
                status.title
            ),
            .field(
                "persistent",
                "true"
            ),
        ]
    }
}
