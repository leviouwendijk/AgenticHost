import Agentic
import AgenticExecution
import AgenticInterfaces
import AgenticRuntime
import Clipboard
import Foundation
import Terminal

enum HostConsoleError:
    Error,
    LocalizedError
{
    case toolPlanRequired

    var errorDescription: String? {
        switch self {
        case .toolPlanRequired:
            return "Clipboard input must contain an AgentToolPlan invocation."
        }
    }
}

enum HostConsole {
    static func run(
        host: AgenticToolHost,
        context: String
    ) async throws {
        let coordinator = AgentToolPlanRunCoordinator(
            invoker: host.invoker,
            context: host.context,
            approvalHandler: nil
        )
        let stream = TerminalStream.standardError
        let session = try TerminalSession(
            options: TerminalSession.Options(
                useAlternateScreen: true,
                hideCursor: true,
                useRawMode: true,
                useBracketedPaste: true,
                restoreOnInterrupt: true,
                outputStream: stream
            )
        )

        defer {
            session.restore()
        }

        let reader = TerminalKeyReader()
        var renderer = TerminalFrameRenderer(
            stream: stream
        )
        var size = Terminal.size(
            for: stream
        )
        var note = "p load clipboard ToolPlan"
        let work = HostWork()
        let pendingPlans = HostPendingPlans()
        let runArtifacts = HostRunArtifacts()
        var activityFrame = 0
        var console = AgenticHostConsoleWorkflowControl(
            snapshot: HostProjection.snapshot(
                runs: [],
                context: context,
                note: note
            )
        )

        func render() {
            var frame = TerminalFrame(
                rows: size.rows,
                columns: size.columns
            )

            console.render(
                into: &frame,
                in: TerminalRegion(
                    rows: size.rows,
                    columns: size.columns
                )
            )
            renderer.render(
                frame
            )
        }

        render()

        while true {
            let events = reader.readEvents(
                timeoutMilliseconds: 100,
                maximumCount: 128
            )

            if events.isEmpty {
                var needsRender = false
                let currentSize = Terminal.size(
                    for: stream
                )

                if currentSize != size {
                    size = currentSize
                    needsRender = true
                }

                if let completion = await work.takeCompletion() {
                    note = completion
                    activityFrame = 0
                    console.update(
                        await work.project(
                            await snapshot(
                                coordinator: coordinator,
                                pendingPlans: pendingPlans,
                                context: context,
                                note: note
                            )
                        )
                    )
                    needsRender = true
                } else if let activity = await work.current() {
                    note = activity.note(
                        frame: activityFrame
                    )
                    activityFrame += 1

                    console.update(
                        await work.project(
                            await snapshot(
                                coordinator: coordinator,
                                pendingPlans: pendingPlans,
                                context: context,
                                note: note
                            )
                        )
                    )
                    needsRender = true
                }

                if needsRender {
                    render()
                }

                continue
            }

            var shouldExit = false

            for event in events {
                guard case .key(let key) = event else {
                    continue
                }

                if key == .char("p"),
                   console.focus.current == .base {
                    do {
                        let input = try plan(
                            host: host
                        )
                        let runID = UUID().uuidString

                        await pendingPlans.insert(
                            input.plan,
                            runID: runID
                        )
                        await runArtifacts.retainInput(
                            input.source,
                            runID: runID
                        )
                        note = "ToolPlan ready"
                    } catch {
                        note = await work.recordStatus(
                            error.localizedDescription,
                            title: "Clipboard input failed",
                            summary: "loading ToolPlan"
                        )
                    }

                    console.update(
                        await work.project(
                            await snapshot(
                                coordinator: coordinator,
                                pendingPlans: pendingPlans,
                                context: context,
                                note: note
                            )
                        )
                    )

                    continue
                }

                if let event = console.handle(
                    key
                ) {
                    if event.requestsExit {
                        shouldExit = true
                        break
                    }

                    if case .feedbackRequested(
                        message: let message
                    ) = event {
                        note = message
                        console.update(
                            await work.project(
                                await snapshot(
                                    coordinator: coordinator,
                                    pendingPlans: pendingPlans,
                                    context: context,
                                    note: note
                                )
                            )
                        )
                        continue
                    }

                    if case .copyRequested(
                        text: let text,
                        title: let title
                    ) = event {
                        if Clipboard.system.write(
                            text
                        ) {
                            note = "Copied \(title.lowercased())."
                        } else {
                            note = await work.recordStatus(
                                "The host could not write \(title.lowercased()) to the system clipboard.",
                                title: "Clipboard write failed",
                                summary: "copying \(title.lowercased())"
                            )
                        }

                        console.update(
                            await work.project(
                                await snapshot(
                                    coordinator: coordinator,
                                    pendingPlans: pendingPlans,
                                    context: context,
                                    note: note
                                )
                            )
                        )
                        continue
                    }

                    let unavailableRunCopy: (
                        message: String,
                        runID: String
                    )?

                    switch event {
                    case .runInputCopyRequested(
                        runID: let runID
                    ):
                        unavailableRunCopy = (
                            "Run input is not available.",
                            runID
                        )

                    case .runOutputCopyRequested(
                        runID: let runID
                    ):
                        unavailableRunCopy = (
                            "Run output is not available yet.",
                            runID
                        )

                    default:
                        unavailableRunCopy = nil
                    }

                    if let unavailableRunCopy {
                        do {
                            if let copy = try await HostRunCopyMaterializer.materialize(
                                event,
                                inputs: runArtifacts,
                                runs: await coordinator.runs()
                            ) {
                                if Clipboard.system.write(
                                    copy.text
                                ) {
                                    note = "Copied run \(copy.title)."
                                } else {
                                    note = await work.recordStatus(
                                        "The host could not write the retained run \(copy.title) to the system clipboard.",
                                        title: "Clipboard write failed",
                                        summary: "copying run \(copy.title)",
                                        runID: unavailableRunCopy.runID
                                    )
                                }
                            } else {
                                note = unavailableRunCopy.message
                            }
                        } catch {
                            note = await work.recordStatus(
                                error.localizedDescription,
                                title: "Run copy failed",
                                summary: "materializing run copy",
                                runID: unavailableRunCopy.runID
                            )
                        }

                        console.update(
                            await work.project(
                                await snapshot(
                                    coordinator: coordinator,
                                    pendingPlans: pendingPlans,
                                    context: context,
                                    note: note
                                )
                            )
                        )
                        continue
                    }

                    if case .documentRequested(
                        runID: let runID,
                        stepID: let stepID,
                        kind: let kind
                    ) = event {
                        do {
                            if let pending = await pendingPlans.call(
                                runID: runID,
                                stepID: stepID
                            ) {
                                let document = try await HostPendingDocumentMaterializer.document(
                                    host: host,
                                    pending: pending,
                                    kind: kind
                                )

                                await pendingPlans.store(
                                    document
                                )
                                note = "Opened \(document.title.lowercased())"

                                console.update(
                                    await work.project(
                                        await snapshot(
                                            coordinator: coordinator,
                                            pendingPlans: pendingPlans,
                                            context: context,
                                            note: note
                                        )
                                    )
                                )

                                _ = console.handle(
                                    key
                                )
                            } else {
                                note = "Document is not available for this step."
                                console.update(
                                    await work.project(
                                        await snapshot(
                                            coordinator: coordinator,
                                            pendingPlans: pendingPlans,
                                            context: context,
                                            note: note
                                        )
                                    )
                                )
                            }
                        } catch {
                            note = await work.recordStatus(
                                error.localizedDescription,
                                title: "Document request failed",
                                summary: "opening run document",
                                runID: runID,
                                stepID: stepID
                            )
                            console.update(
                                await work.project(
                                    await snapshot(
                                        coordinator: coordinator,
                                        pendingPlans: pendingPlans,
                                        context: context,
                                        note: note
                                    )
                                )
                            )
                        }

                        continue
                    }

                    if case .runControlRequested(
                        runID: let runID,
                        control: let control
                    ) = event {
                        switch control {
                        case .pause:
                            if await coordinator.requestPause(
                                runID: runID
                            ) {
                                _ = await work.markPausePending(
                                    runID: runID
                                )
                                note = "pause requested"
                            } else {
                                note = "pause unavailable"
                            }

                            console.update(
                                await work.project(
                                    await snapshot(
                                        coordinator: coordinator,
                                        pendingPlans: pendingPlans,
                                        context: context,
                                        note: note
                                    )
                                )
                            )

                        case .execute_run,
                             .execute_step_and_wait:
                            let executionPolicy: AgentToolPlanExecutionPolicy
                            let label: String

                            switch control {
                            case .execute_run:
                                executionPolicy = .continuous
                                label = "executing run"

                            case .execute_step_and_wait:
                                executionPolicy = .single_step
                                label = "executing step"

                            case .pause:
                                continue
                            }

                            let pendingPlan = await pendingPlans.plan(
                                runID: runID
                            )
                            let expectedRevision = await coordinator.runs()
                                .first(
                                    where: {
                                        $0.id == runID
                                    }
                                )?
                                .revision
                            let activity = HostActivity(
                                runID: runID,
                                label: label
                            )

                            if await work.begin(
                                activity
                            ) {
                                note = activity.note(
                                    frame: activityFrame
                                )
                                activityFrame += 1

                                console.update(
                                    await work.project(
                                        await snapshot(
                                            coordinator: coordinator,
                                            pendingPlans: pendingPlans,
                                            context: context,
                                            note: note
                                        )
                                    )
                                )

                                Task {
                                    do {
                                        if let pendingPlan {
                                            _ = try await coordinator.start(
                                                pendingPlan,
                                                runID: runID,
                                                executionPolicy: executionPolicy
                                            )
                                            _ = await pendingPlans.take(
                                                runID: runID
                                            )
                                        } else if let expectedRevision {
                                            _ = try await coordinator.resume(
                                                runID: runID,
                                                expectedRevision: expectedRevision,
                                                executionPolicy: executionPolicy
                                            )
                                        } else {
                                            throw AgentToolPlanRunCoordinatorError.missingRun(
                                                runID
                                            )
                                        }

                                        await work.finish(
                                            executionPolicy == .continuous
                                                ? "Run execution finished"
                                                : "Step execution finished"
                                        )
                                    } catch {
                                        await work.fail(
                                            error.localizedDescription,
                                            title: "Execution attempt failed"
                                        )
                                    }
                                }
                            } else {
                                note = "host execution already in progress"

                                console.update(
                                    await work.project(
                                        await snapshot(
                                            coordinator: coordinator,
                                            pendingPlans: pendingPlans,
                                            context: context,
                                            note: note
                                        )
                                    )
                                )
                            }
                        }

                        continue
                    }

                    if case .actionRequested(
                        interruptionID: _,
                        runID: let runID,
                        stepID: let stepID,
                        action: let action
                    ) = event {
                        let activity = HostActivity.action(
                            action,
                            runID: runID,
                            stepID: stepID
                        )

                        if await work.begin(
                            activity
                        ) {
                            note = activity.note(
                                frame: activityFrame
                            )
                            activityFrame += 1

                            console.update(
                                await work.project(
                                    await snapshot(
                                        coordinator: coordinator,
                                        pendingPlans: pendingPlans,
                                        context: context,
                                        note: note
                                    )
                                )
                            )

                            do {
                                let recoveryInput:
                                    (plan: AgentToolPlan, source: String)?
                                let recoveryRunID: String?

                                if action == .createFixBranch {
                                    recoveryInput = try plan(
                                        host: host
                                    )
                                    recoveryRunID = UUID().uuidString
                                } else {
                                    recoveryInput = nil
                                    recoveryRunID = nil
                                }

                                Task {
                                    do {
                                        try await apply(
                                            action,
                                            runID: runID,
                                            recoveryPlan: recoveryInput?.plan,
                                            recoveryRunID: recoveryRunID,
                                            coordinator: coordinator
                                        )

                                        if let recoveryInput,
                                           let recoveryRunID
                                        {
                                            await runArtifacts.retainInput(
                                                recoveryInput.source,
                                                runID: recoveryRunID
                                            )
                                        }

                                        await work.finish(
                                            "Action applied"
                                        )
                                    } catch {
                                        await work.fail(
                                            error.localizedDescription,
                                            title: "Action failed"
                                        )
                                    }
                                }
                            } catch {
                                await work.fail(
                                    error.localizedDescription,
                                    title: "Action failed"
                                )
                            }
                        } else {
                            note = "host execution already in progress"

                            console.update(
                                await work.project(
                                    await snapshot(
                                        coordinator: coordinator,
                                        pendingPlans: pendingPlans,
                                        context: context,
                                        note: note
                                    )
                                )
                            )
                        }
                    }
                }
            }

            if shouldExit {
                return
            }

            size = Terminal.size(
                for: stream
            )
            render()
        }
    }
}

private extension HostConsole {
    static func snapshot(
        coordinator: AgentToolPlanRunCoordinator,
        pendingPlans: HostPendingPlans,
        context: String,
        note: String
    ) async -> AgenticHostConsoleSnapshot {
        var snapshot = HostProjection.snapshot(
            runs: await coordinator.runs(),
            context: context,
            note: note
        )
        let pending = await pendingPlans.presentations()
            .filter { pendingRun in
                !snapshot.runs.contains {
                    $0.id == pendingRun.id
                }
            }

        snapshot.runs.append(
            contentsOf: pending
        )

        let pendingRunIDs = Set(
            pending.map(\.id)
        )
        let pendingDocuments = await pendingPlans.documents()
            .filter {
                pendingRunIDs.contains(
                    $0.runID
                )
            }

        snapshot.documents.append(
            contentsOf: pendingDocuments
        )

        return snapshot
    }

    static func apply(
        _ action: AgenticHostConsoleAction,
        runID: String,
        recoveryPlan: AgentToolPlan?,
        recoveryRunID: String?,
        coordinator: AgentToolPlanRunCoordinator
    ) async throws {
        guard let run = await coordinator.runs().first(
            where: {
                $0.id == runID
            }
        ) else {
            throw AgentToolPlanRunCoordinatorError.missingRun(
                runID
            )
        }

        switch action {
        case .retry:
            _ = try await coordinator.retry(
                runID: runID,
                expectedRevision: run.revision
            )

        case .skip:
            _ = try await coordinator.skip(
                runID: runID,
                expectedRevision: run.revision
            )

        case .continueRun:
            _ = try await coordinator.resume(
                runID: runID,
                expectedRevision: run.revision
            )

        case .approve:
            _ = try await coordinator.decide(
                runID: runID,
                expectedRevision: run.revision,
                decision: .approved
            )

        case .deny:
            _ = try await coordinator.decide(
                runID: runID,
                expectedRevision: run.revision,
                decision: .denied
            )

        case .createFixBranch:
            guard let recoveryPlan,
                  let recoveryRunID
            else {
                throw HostConsoleError.toolPlanRequired
            }

            _ = try await coordinator.recover(
                parentRunID: runID,
                expectedParentRevision: run.revision,
                plan: recoveryPlan,
                runID: recoveryRunID
            )

        case .stopRun:
            return
        }
    }

    static func plan(
        host: AgenticToolHost
    ) throws -> (
        plan: AgentToolPlan,
        source: String
    ) {
        guard let text = Clipboard.system.read(),
              !text.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty
        else {
            throw AgenticRuntimeCommandError
                .missingClipboardInput
        }

        let request = try host.decodeInvocationRequest(
            Data(
                text.utf8
            )
        )

        guard request.action == .invoke,
              let plan = request.plan
        else {
            throw HostConsoleError.toolPlanRequired
        }

        return (
            plan: plan,
            source: text
        )
    }
}
