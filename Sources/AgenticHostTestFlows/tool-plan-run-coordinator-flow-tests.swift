import Agentic
import AgenticExecution
import AgenticRuntime
import Primitives
import Schema
import SchemaMacros
import TestFlows

enum AgenticRuntimeToolPlanFlowTesting {
    static func runDeferredPause() async throws -> [TestFlowDiagnostic] {
        let fixture = try makeFixture()
        let runID = "runtime-deferred-pause"
        let plan = AgentToolPlan(
            id: "runtime-deferred-pause-plan",
            root: .sequence(
                [
                    .call(
                        try call(
                            id: "hold",
                            marker: "hold"
                        )
                    ),
                    .call(
                        try call(
                            id: "second",
                            marker: "second"
                        )
                    ),
                    .call(
                        try call(
                            id: "third",
                            marker: "third"
                        )
                    ),
                ]
            )
        )

        let execution = Task {
            try await fixture.coordinator.start(
                plan,
                runID: runID,
                executionPolicy: .continuous
            )
        }

        while !(await fixture.probe.hasInvoked(
            "hold"
        )) {
            await Task.yield()
        }

        let pauseAccepted = await fixture.coordinator.requestPause(
            runID: runID
        )

        try Expect.equal(
            pauseAccepted,
            true,
            "continuous run accepts pause while current tool is executing"
        )

        await fixture.probe.releaseHold()

        let paused = try await execution.value

        guard case .paused(let pause) = paused.state,
              pause.afterPath == "root.sequence[0]",
              pause.afterCallID == "hold",
              pause.attemptNumber == 1,
              pause.reason == .requested else {
            throw RuntimeToolPlanFlowError.unexpectedRunState
        }

        try Expect.equal(
            await fixture.probe.invocationLog(),
            "hold",
            "deferred pause finishes the first current call and does not start following call"
        )

        let completed = try await fixture.coordinator.resume(
            runID: paused.id,
            expectedRevision: paused.revision,
            executionPolicy: .continuous
        )

        guard case .completed = completed.state else {
            throw RuntimeToolPlanFlowError.unexpectedRunState
        }

        try Expect.equal(
            await fixture.probe.invocationLog(),
            "hold,second,third",
            "continuous resume executes untouched suffix after requested first-call pause"
        )

        try Expect.equal(
            completed.revision,
            3,
            "three executed authored calls advance the run to revision three"
        )

        return [
            .field(
                "paused-after",
                pause.afterCallID
            ),
            .field(
                "pause-reason",
                pause.reason.rawValue
            ),
            .field(
                "executed",
                await fixture.probe.invocationLog()
            ),
            .field(
                "revision",
                "\(completed.revision)"
            ),
        ]
    }

    static func runSingleStepResolutionPolicy() async throws -> [TestFlowDiagnostic] {
        let fixture = try makeFixture()
        let runID = "runtime-single-step-resolution-policy"
        let plan = AgentToolPlan(
            id: "runtime-single-step-resolution-policy-plan",
            root: .sequence(
                [
                    .call(
                        try call(
                            id: "repair",
                            marker: "repair"
                        )
                    ),
                    .call(
                        try call(
                            id: "suffix",
                            marker: "suffix"
                        )
                    ),
                ]
            )
        )

        let interrupted = try await fixture.coordinator.start(
            plan,
            runID: runID,
            executionPolicy: .single_step
        )

        guard case .suspended(let suspension) = interrupted.state,
              suspension.callID == "repair",
              case .failure = suspension.reason else {
            throw RuntimeToolPlanFlowError.unexpectedRunState
        }

        try Expect.equal(
            await fixture.probe.invocationLog(),
            "repair",
            "single-step run stops at semantic failure"
        )

        let retried = try await fixture.coordinator.retry(
            runID: runID,
            expectedRevision: interrupted.revision
        )

        guard case .paused(let pause) = retried.state,
              pause.afterPath == "root.sequence[0]",
              pause.afterCallID == "repair",
              pause.attemptNumber == 2,
              pause.reason == .single_step else {
            throw RuntimeToolPlanFlowError.unexpectedRunState
        }

        try Expect.equal(
            await fixture.probe.invocationLog(),
            "repair,repair",
            "successful retry inherits single-step policy and does not execute suffix"
        )

        let completed = try await fixture.coordinator.resume(
            runID: runID,
            expectedRevision: retried.revision,
            executionPolicy: .continuous
        )

        guard case .completed = completed.state else {
            throw RuntimeToolPlanFlowError.unexpectedRunState
        }

        try Expect.equal(
            await fixture.probe.invocationLog(),
            "repair,repair,suffix",
            "explicit continuous resume executes untouched suffix"
        )

        try Expect.equal(
            completed.revision,
            3,
            "retry and later suffix execution advance revisions without replay"
        )

        return [
            .field(
                "paused-after",
                pause.afterCallID
            ),
            .field(
                "policy",
                pause.reason.rawValue
            ),
            .field(
                "executed",
                await fixture.probe.invocationLog()
            ),
            .field(
                "revision",
                "\(completed.revision)"
            ),
        ]
    }

    static func runRecoveryThenRetry() async throws -> [TestFlowDiagnostic] {
        let fixture = try makeFixture()
        let parent = try await fixture.coordinator.start(
            fixture.parentPlan,
            runID: "parent-retry"
        )

        try requireFailureSuspension(
            parent
        )

        try Expect.equal(
            await fixture.probe.invocationLog(),
            "prefix,repair",
            "parent suspends before suffix"
        )

        let recovery = try await fixture.coordinator.recover(
            parentRunID: parent.id,
            expectedParentRevision: parent.revision,
            plan: fixture.recoveryPlan,
            runID: "recovery-retry"
        )

        guard case .recovery(
            parentRunID: let recoveryParentID
        ) = recovery.relationship else {
            throw RuntimeToolPlanFlowError.unexpectedRelationship
        }

        try Expect.equal(
            recoveryParentID,
            parent.id,
            "recovery child links to suspended parent"
        )

        guard case .completed = recovery.state else {
            throw RuntimeToolPlanFlowError.unexpectedRunState
        }

        let unchangedParent = try await fixture.coordinator.run(
            id: parent.id
        )

        try requireFailureSuspension(
            unchangedParent
        )

        try Expect.equal(
            unchangedParent.revision,
            parent.revision,
            "successful recovery does not mutate parent"
        )

        try Expect.equal(
            await fixture.probe.invocationLog(),
            "prefix,repair,fix",
            "recovery executes independently from parent"
        )

        let recoveries = await fixture.coordinator.recoveries(
            of: parent.id
        )

        try Expect.equal(
            recoveries.count,
            1,
            "runtime retains recovery relationship in memory"
        )

        let retried = try await fixture.coordinator.retry(
            runID: parent.id,
            expectedRevision: unchangedParent.revision
        )

        guard case .completed = retried.state else {
            throw RuntimeToolPlanFlowError.unexpectedRunState
        }

        try Expect.equal(
            await fixture.probe.invocationLog(),
            "prefix,repair,fix,repair,suffix",
            "post-fix retry continues untouched suffix"
        )

        return [
            .field(
                "parent",
                retried.id
            ),
            .field(
                "recovery",
                recovery.id
            ),
            .field(
                "revision",
                "\(retried.revision)"
            ),
        ]
    }

    static func runRecoveryThenSkip() async throws -> [TestFlowDiagnostic] {
        let fixture = try makeFixture()
        let parent = try await fixture.coordinator.start(
            fixture.parentPlan,
            runID: "parent-skip"
        )

        try requireFailureSuspension(
            parent
        )

        let recovery = try await fixture.coordinator.recover(
            parentRunID: parent.id,
            expectedParentRevision: parent.revision,
            plan: fixture.recoveryPlan,
            runID: "recovery-skip"
        )

        guard case .completed = recovery.state else {
            throw RuntimeToolPlanFlowError.unexpectedRunState
        }

        let unchangedParent = try await fixture.coordinator.run(
            id: parent.id
        )

        try requireFailureSuspension(
            unchangedParent
        )

        let skipped = try await fixture.coordinator.skip(
            runID: parent.id,
            expectedRevision: unchangedParent.revision
        )

        guard case .completed = skipped.state else {
            throw RuntimeToolPlanFlowError.unexpectedRunState
        }

        try Expect.equal(
            await fixture.probe.invocationLog(),
            "prefix,repair,fix,suffix",
            "skip avoids replaying repaired node and continues untouched suffix"
        )

        do {
            _ = try await fixture.coordinator.skip(
                runID: parent.id,
                expectedRevision: unchangedParent.revision
            )

            throw RuntimeToolPlanFlowError.expectedStaleRevision
        } catch let error as AgentToolPlanRunCoordinatorError {
            guard case .staleRevision(
                runID: let runID,
                expected: let expected,
                actual: let actual
            ) = error else {
                throw error
            }

            try Expect.equal(
                runID,
                parent.id,
                "stale control identifies parent run"
            )
            try Expect.equal(
                expected,
                unchangedParent.revision,
                "stale control retains supplied revision"
            )
            try Expect.equal(
                actual,
                skipped.revision,
                "stale control reports live revision"
            )
        }

        return [
            .field(
                "parent",
                skipped.id
            ),
            .field(
                "resolution",
                "skipped"
            ),
            .field(
                "revision",
                "\(skipped.revision)"
            ),
        ]
    }

    static func runRecoveryHierarchyAndGating() async throws -> [TestFlowDiagnostic] {
        let fixture = try makeFixture()
        let parent = try await fixture.coordinator.start(
            fixture.parentPlan,
            runID: "hierarchy-parent"
        )
        try requireFailureSuspension(parent)

        let child = try await fixture.coordinator.recover(
            parentRunID: parent.id,
            expectedParentRevision: parent.revision,
            plan: try plan(id: "child-plan", marker: "child"),
            runID: "hierarchy-child"
        )
        try requireFailureSuspension(child)
        try Expect.equal(
            try await fixture.coordinator.recoveryDepth(of: child.id),
            1,
            "first recovery has depth one"
        )
        try Expect.equal(
            try await fixture.coordinator.activeRecovery(of: parent.id)?.id,
            child.id,
            "suspended child gates its exact parent suspension"
        )
        try await requireActiveRecoveryGate(
            parent: parent,
            child: child,
            coordinator: fixture.coordinator
        )

        do {
            _ = try await fixture.coordinator.recover(
                parentRunID: parent.id,
                expectedParentRevision: parent.revision,
                plan: fixture.recoveryPlan,
                runID: "second-child"
            )
            throw RuntimeToolPlanFlowError.expectedActiveRecoveryGate
        } catch let error as AgentToolPlanRunCoordinatorError {
            guard case .activeRecoveryChild = error else {
                throw error
            }
        }

        let grandchild = try await fixture.coordinator.recover(
            parentRunID: child.id,
            expectedParentRevision: child.revision,
            plan: fixture.recoveryPlan,
            runID: "hierarchy-grandchild"
        )
        guard case .completed = grandchild.state else {
            throw RuntimeToolPlanFlowError.unexpectedRunState
        }
        try Expect.equal(
            try await fixture.coordinator.recoveryDepth(of: grandchild.id),
            2,
            "nested recovery is allowed below the default depth cap"
        )

        let limited = try makeFixture(maximumRecoveryDepth: 1)
        let limitedParent = try await limited.coordinator.start(
            limited.parentPlan,
            runID: "depth-parent"
        )
        let limitedChild = try await limited.coordinator.recover(
            parentRunID: limitedParent.id,
            expectedParentRevision: limitedParent.revision,
            plan: try plan(id: "depth-child-plan", marker: "child"),
            runID: "depth-child"
        )
        try requireFailureSuspension(limitedChild)

        do {
            _ = try await limited.coordinator.recover(
                parentRunID: limitedChild.id,
                expectedParentRevision: limitedChild.revision,
                plan: limited.recoveryPlan,
                runID: "depth-grandchild"
            )
            throw RuntimeToolPlanFlowError.expectedRecoveryDepthLimit
        } catch let error as AgentToolPlanRunCoordinatorError {
            guard case .maximumRecoveryDepthExceeded(
                parentRunID: let parentRunID,
                maximumDepth: let maximumDepth
            ) = error,
            parentRunID == limitedChild.id,
            maximumDepth == 1 else {
                throw error
            }
        }

        return [
            .field("nested-depth", "2"),
            .field("maximum-depth", "1"),
        ]
    }
}

private extension AgenticRuntimeToolPlanFlowTesting {
    struct Fixture {
        let coordinator: AgentToolPlanRunCoordinator
        let parentPlan: AgentToolPlan
        let recoveryPlan: AgentToolPlan
        let probe: RuntimeToolPlanProbe
    }

    static func makeFixture(maximumRecoveryDepth: Int = 4) throws -> Fixture {
        let probe = RuntimeToolPlanProbe()
        let tool = RuntimeToolPlanProbeTool(
            probe: probe
        )
        let invoker = ToolInvoker(
            registry: try ToolRegistry {
                tool
            },
            policy: ToolExecutionPolicy(
                autonomyMode: .auto_observe
            )
        )
        let coordinator = AgentToolPlanRunCoordinator(
            invoker: invoker,
            context: AgentToolExecutionContext(
                sessionID: "runtime-tool-plan-session"
            ),
            maximumRecoveryDepth: maximumRecoveryDepth
        )
        let parentPlan = AgentToolPlan(
            id: "runtime-parent-plan",
            root: .sequence(
                [
                    .call(
                        try call(
                            id: "prefix",
                            marker: "prefix"
                        )
                    ),
                    .call(
                        try call(
                            id: "repair",
                            marker: "repair"
                        )
                    ),
                    .call(
                        try call(
                            id: "suffix",
                            marker: "suffix"
                        )
                    ),
                ]
            )
        )
        let recoveryPlan = AgentToolPlan(
            id: "runtime-recovery-plan",
            root: .call(
                try call(
                    id: "fix",
                    marker: "fix"
                )
            )
        )

        return Fixture(
            coordinator: coordinator,
            parentPlan: parentPlan,
            recoveryPlan: recoveryPlan,
            probe: probe
        )
    }

    static func plan(id: String, marker: String) throws -> AgentToolPlan {
        AgentToolPlan(
            id: id,
            root: .call(try call(id: "call-\(marker)", marker: marker))
        )
    }

    static func requireActiveRecoveryGate(
        parent: AgentToolPlanRun,
        child: AgentToolPlanRun,
        coordinator: AgentToolPlanRunCoordinator
    ) async throws {
        do {
            _ = try await coordinator.retry(
                runID: parent.id,
                expectedRevision: parent.revision
            )
            throw RuntimeToolPlanFlowError.expectedActiveRecoveryGate
        } catch let error as AgentToolPlanRunCoordinatorError {
            guard case .activeRecoveryChild(
                parentRunID: let parentRunID,
                childRunID: let childRunID
            ) = error,
            parentRunID == parent.id,
            childRunID == child.id else {
                throw error
            }
        }

        do {
            _ = try await coordinator.skip(
                runID: parent.id,
                expectedRevision: parent.revision
            )
            throw RuntimeToolPlanFlowError.expectedActiveRecoveryGate
        } catch let error as AgentToolPlanRunCoordinatorError {
            guard case .activeRecoveryChild = error else { throw error }
        }
    }

    static func call(
        id: String,
        marker: String
    ) throws -> AgentToolCall {
        AgentToolCall(
            id: id,
            name: "runtime_tool_plan_probe",
            input: try JSONToolBridge.encode(
                RuntimeToolPlanProbeInput(
                    marker: marker
                )
            )
        )
    }

    static func requireFailureSuspension(
        _ run: AgentToolPlanRun
    ) throws {
        guard case .suspended(let suspension) = run.state,
              case .failure = suspension.reason
        else {
            throw RuntimeToolPlanFlowError.unexpectedRunState
        }
    }

    static func requireContinuationRequired(
        _ run: AgentToolPlanRun
    ) throws {
        guard case .suspended(let suspension) = run.state,
              case .continuation_required = suspension.reason
        else {
            throw RuntimeToolPlanFlowError.unexpectedRunState
        }
    }
}

private actor RuntimeToolPlanProbe {
    private var invocations: [String] = []
    private var failedMarkers: Set<String> = []
    private var holdContinuation: CheckedContinuation<Void, Never>?

    func invoke(
        _ input: RuntimeToolPlanProbeInput
    ) async throws -> RuntimeToolPlanProbeInput {
        invocations.append(
            input.marker
        )

        if input.marker == "hold" {
            await withCheckedContinuation { continuation in
                holdContinuation = continuation
            }
        }

        if ["repair", "child"].contains(input.marker),
           failedMarkers.insert(input.marker).inserted {
            throw RuntimeToolPlanProbeError.firstRepairAttempt
        }

        return input
    }

    func hasInvoked(
        _ marker: String
    ) -> Bool {
        invocations.contains(
            marker
        )
    }

    func releaseHold() {
        holdContinuation?.resume()
        holdContinuation = nil
    }

    func invocationLog() -> String {
        invocations.joined(
            separator: ","
        )
    }
}

@JSONSchema
private struct RuntimeToolPlanProbeInput:
    Sendable,
    Codable,
    Hashable
{
    let marker: String
}

private struct RuntimeToolPlanProbeTool: AgentTool {
    typealias Input = RuntimeToolPlanProbeInput
    typealias Output = RuntimeToolPlanProbeInput

    let identifier: AgentToolIdentifier = "runtime_tool_plan_probe"
    let description = "Records plan-run execution order and fails the first repair call."
    let risk: ActionRisk = .observe
    let probe: RuntimeToolPlanProbe

    func call(
        _ input: Input,
        context _: AgentToolExecutionContext
    ) async throws -> Output {
        try await probe.invoke(
            input
        )
    }
}

private enum RuntimeToolPlanProbeError: Error {
    case firstRepairAttempt
}

private enum RuntimeToolPlanFlowError: Error {
    case unexpectedRelationship
    case unexpectedRunState
    case expectedStaleRevision
    case expectedActiveRecoveryGate
    case expectedRecoveryDepthLimit
}