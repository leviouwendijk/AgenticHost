import Agentic
import Foundation
import Workspace

package actor ToolPlanRunController {
    let executor: ToolPlan.RunExecutor
    let workspace: WorkspaceContext?
    let approvalHandler: (any ToolApprovalHandler)?
    let maximumRecoveryDepth: Int

    private var runsByID: [String: ToolPlan.Run] = [:]
    private var runOrder: [String] = []
    private var executionPoliciesByRunID: [String: ToolPlan.ExecutionPolicy] = [:]
    private var pauseRequestedRunIDs: Set<String> = []
    private var activeRunIDs: Set<String> = []

    package init(
        invoker: ToolInvoker,
        workspace: WorkspaceContext? = nil,
        approvalHandler: (any ToolApprovalHandler)? = nil,
        maximumRecoveryDepth: Int = 4
    ) {
        self.executor = ToolPlan.RunExecutor(
            invoker: invoker
        )
        self.workspace = workspace
        self.approvalHandler = approvalHandler
        self.maximumRecoveryDepth = max(
            0,
            maximumRecoveryDepth
        )
    }

    package func runs() -> [ToolPlan.Run] {
        runOrder.compactMap { runID in
            runsByID[runID]
        }
    }

    package func run(
        id: String
    ) throws -> ToolPlan.Run {
        guard let run = runsByID[id] else {
            throw ToolPlanRunControllerError.missingRun(
                id
            )
        }

        return run
    }

    package func recoveries(
        of parentRunID: String
    ) -> [ToolPlan.Run] {
        runOrder.compactMap { runID in
            guard let run = runsByID[runID],
                  case .recovery(
                    parentRunID: let candidateParentID
                  ) = run.relationship,
                  candidateParentID == parentRunID
            else {
                return nil
            }

            return run
        }
    }

    package func activeRecovery(
        of parentRunID: String
    ) -> ToolPlan.Run? {
        recoveries(
            of: parentRunID
        )
        .last { run in
            if case .interrupted = run.state {
                return true
            }

            return false
        }
    }

    package func recoveryDepth(
        of runID: String
    ) throws -> Int {
        var depth = 0
        var current = try run(
            id: runID
        )
        var visited: Set<String> = [
            current.id,
        ]

        while case .recovery(
            parentRunID: let parentRunID
        ) = current.relationship {
            guard visited.insert(
                parentRunID
            ).inserted else {
                break
            }

            depth += 1
            current = try run(
                id: parentRunID
            )
        }

        return depth
    }

    @discardableResult
    package func requestPause(
        runID: String
    ) -> Bool {
        guard activeRunIDs.contains(runID) else {
            return false
        }

        pauseRequestedRunIDs.insert(
            runID
        )
        return true
    }

    package func start(
        _ plan: ToolPlan,
        runID: String = UUID().uuidString,
        executionPolicy: ToolPlan.ExecutionPolicy = .continuous,
        relationship: ToolPlan.Run.Relationship = .root
    ) async throws -> ToolPlan.Run {
        guard runsByID[runID] == nil, !activeRunIDs.contains(runID) else {
            throw ToolPlanRunControllerError.duplicateRun(
                runID
            )
        }

        activeRunIDs.insert(runID)
        defer {
            activeRunIDs.remove(runID)
            pauseRequestedRunIDs.remove(runID)
            if runsByID[runID] == nil {
                executionPoliciesByRunID.removeValue(forKey: runID)
            }
        }
        executionPoliciesByRunID[runID] = executionPolicy

        var run = try await executor.start(
            plan,
            runID: runID,
            relationship: relationship,
            executionPolicy: .single_step,
            workspace: workspace,
            approvalHandler: approvalHandler
        )

        store(
            run
        )

        run = try await settle(
            run,
            executionPolicy: executionPolicy
        )

        store(
            run
        )
        return run
    }

    package func resume(
        runID: String,
        expectedRevision: Int,
        executionPolicy: ToolPlan.ExecutionPolicy? = nil
    ) async throws -> ToolPlan.Run {
        var run = try currentRun(
            runID: runID,
            expectedRevision: expectedRevision
        )
        activeRunIDs.insert(runID)
        defer {
            activeRunIDs.remove(runID)
            pauseRequestedRunIDs.remove(runID)
        }
        let effectivePolicy = executionPolicy
            ?? executionPoliciesByRunID[runID]
            ?? .continuous

        executionPoliciesByRunID[runID] = effectivePolicy

        guard case .interrupted(let interruption) = run.state else {
            throw ToolPlan.Run.Error.runNotInterrupted
        }

        switch interruption.reason {
        case .policy:
            run = try await executor.resume(
                run,
                executionPolicy: .single_step,
                workspace: workspace,
                approvalHandler: approvalHandler
            )

        case .continuation_required:
            run = try await executor.resume(
                run,
                workspace: workspace,
                approvalHandler: approvalHandler
            )

        case .failure,
             .human_review:
            throw ToolPlan.Run.Error.interruptionNotResolved
        }

        store(
            run
        )

        run = try await settle(
            run,
            executionPolicy: effectivePolicy
        )

        store(
            run
        )
        return run
    }

    package func retry(
        runID: String,
        expectedRevision: Int
    ) async throws -> ToolPlan.Run {
        try requireNoActiveRecovery(
            parentRunID: runID
        )

        var run = try currentRun(
            runID: runID,
            expectedRevision: expectedRevision
        )
        activeRunIDs.insert(runID)
        defer {
            activeRunIDs.remove(runID)
            pauseRequestedRunIDs.remove(runID)
        }

        run = try await executor.retry(
            run,
            workspace: workspace,
            approvalHandler: approvalHandler
        )

        store(
            run
        )

        run = try await settle(
            run,
            executionPolicy:
                executionPoliciesByRunID[runID]
                    ?? .continuous
        )

        store(
            run
        )
        return run
    }

    package func skip(
        runID: String,
        expectedRevision: Int
    ) async throws -> ToolPlan.Run {
        try requireNoActiveRecovery(
            parentRunID: runID
        )

        var run = try currentRun(
            runID: runID,
            expectedRevision: expectedRevision
        )
        activeRunIDs.insert(runID)
        defer {
            activeRunIDs.remove(runID)
            pauseRequestedRunIDs.remove(runID)
        }

        run = try executor.skip(
            run
        )

        store(
            run
        )

        run = try await settle(
            run,
            executionPolicy:
                executionPoliciesByRunID[runID]
                    ?? .continuous
        )

        store(
            run
        )
        return run
    }

    package func decide(
        runID: String,
        expectedRevision: Int,
        decision: ApprovalDecision
    ) async throws -> ToolPlan.Run {
        var run = try currentRun(
            runID: runID,
            expectedRevision: expectedRevision
        )
        activeRunIDs.insert(runID)
        defer {
            activeRunIDs.remove(runID)
            pauseRequestedRunIDs.remove(runID)
        }

        run = try await executor.retry(
            run,
            workspace: workspace,
            approvalHandler: ToolPlanRunDecisionHandler(
                decision: decision
            )
        )

        store(
            run
        )

        run = try await settle(
            run,
            executionPolicy:
                executionPoliciesByRunID[runID]
                    ?? .continuous
        )

        store(
            run
        )
        return run
    }

    package func recover(
        parentRunID: String,
        expectedParentRevision: Int,
        plan: ToolPlan,
        runID: String = UUID().uuidString
    ) async throws -> ToolPlan.Run {
        _ = try currentRun(
            runID: parentRunID,
            expectedRevision: expectedParentRevision
        )

        try requireNoActiveRecovery(
            parentRunID: parentRunID
        )

        let depth = try recoveryDepth(
            of: parentRunID
        ) + 1

        guard depth <= maximumRecoveryDepth else {
            throw ToolPlanRunControllerError
                .maximumRecoveryDepthExceeded(
                    parentRunID: parentRunID,
                    maximumDepth: maximumRecoveryDepth
                )
        }

        return try await start(
            plan,
            runID: runID,
            executionPolicy:
                executionPoliciesByRunID[parentRunID]
                    ?? .continuous,
            relationship: .recovery(
                parentRunID: parentRunID
            )
        )
    }
}

private extension ToolPlanRunController {
    func requireNoActiveRecovery(
        parentRunID: String
    ) throws {
        guard let child = activeRecovery(
            of: parentRunID
        ) else {
            return
        }

        throw ToolPlanRunControllerError.activeRecoveryChild(
            parentRunID: parentRunID,
            childRunID: child.id
        )
    }

    func currentRun(
        runID: String,
        expectedRevision: Int
    ) throws -> ToolPlan.Run {
        guard !activeRunIDs.contains(runID) else {
            throw ToolPlanRunControllerError.runBusy(runID)
        }
        guard let run = runsByID[runID] else {
            throw ToolPlanRunControllerError.missingRun(
                runID
            )
        }

        guard run.revision == expectedRevision else {
            throw ToolPlanRunControllerError.staleRevision(
                runID: runID,
                expected: expectedRevision,
                actual: run.revision
            )
        }

        return run
    }

    func store(
        _ run: ToolPlan.Run
    ) {
        if runsByID[run.id] == nil {
            runOrder.append(
                run.id
            )
        }

        runsByID[run.id] = run
    }

    func settle(
        _ initialRun: ToolPlan.Run,
        executionPolicy: ToolPlan.ExecutionPolicy
    ) async throws -> ToolPlan.Run {
        switch executionPolicy {
        case .single_step:
            return initialRun

        case .continuous:
            break
        }

        var run = initialRun

        while true {
            if pauseRequestedRunIDs.contains(run.id),
               case .interrupted(let interruption) = run.state,
               case .policy = interruption.reason
            {
                pauseRequestedRunIDs.remove(
                    run.id
                )

                run = ToolPlan.Run(
                    id: run.id,
                    plan: run.plan,
                    relationship: run.relationship,
                    attempts: run.attempts,
                    resolutions: run.resolutions,
                    revision: run.revision + 1,
                    state: .interrupted(
                        ToolPlan.Run.Interruption(
                            point: interruption.point,
                            reason: .policy(
                                .requested
                            )
                        )
                    )
                )

                store(
                    run
                )
                return run
            }

            switch run.state {
            case .terminal:
                pauseRequestedRunIDs.remove(
                    run.id
                )
                return run

            case .interrupted(let interruption):
                switch interruption.reason {
                case .policy:
                    run = try await executor.resume(
                        run,
                        executionPolicy: .single_step,
                        workspace: workspace,
                        approvalHandler: approvalHandler
                    )

                case .continuation_required:
                    run = try await executor.resume(
                        run,
                        workspace: workspace,
                        approvalHandler: approvalHandler
                    )

                case .failure,
                     .human_review:
                    return run
                }

                store(
                    run
                )
            }
        }
    }
}

private struct ToolPlanRunDecisionHandler:
    ToolApprovalHandler
{
    let decision: ApprovalDecision

    func decide(
        on review: ToolInvocation.Review
    ) async throws -> ApprovalDecision {
        _ = review
        return decision
    }
}

package enum ToolPlanRunControllerError:
    Error,
    Sendable,
    LocalizedError
{
    case duplicateRun(String)
    case missingRun(String)
    case runBusy(String)
    case staleRevision(
        runID: String,
        expected: Int,
        actual: Int
    )
    case activeRecoveryChild(
        parentRunID: String,
        childRunID: String
    )
    case maximumRecoveryDepthExceeded(
        parentRunID: String,
        maximumDepth: Int
    )

    package var errorDescription: String? {
        switch self {
        case .duplicateRun(let runID):
            return "ToolPlan run '\(runID)' already exists."

        case .runBusy(let runID):
            return "ToolPlan run '\(runID)' is executing an operation."

        case .missingRun(let runID):
            return "ToolPlan run '\(runID)' does not exist."

        case .staleRevision(
            let runID,
            let expected,
            let actual
        ):
            return "ToolPlan run '\(runID)' revision changed from \(expected) to \(actual)."

        case .activeRecoveryChild(
            let parentRunID,
            let childRunID
        ):
            return "ToolPlan run '\(parentRunID)' is gated by active recovery child '\(childRunID)'."

        case .maximumRecoveryDepthExceeded(
            let parentRunID,
            let maximumDepth
        ):
            return "ToolPlan recovery below '\(parentRunID)' exceeds maximum depth \(maximumDepth)."
        }
    }
}