import TestFlows
import AgenticIO

enum AgenticRuntimeFlowSuite: TestFlowRegistry {
    static let title = "AgenticRuntime flow tests"

    static let flows: [TestFlow] = [
        TestFlow(
            "interaction-contract",
            tags: [
                "agentic-runtime",
                "interaction",
                "suspension",
                "resume",
                "headless",
            ]
        ) {
            try await AgentInteractionContractFlowTesting
                .run()

            return []
        },
        // TestFlow(
        //     "application-realization",
        //     tags: [
        //         "agentic-runtime",
        //         "application",
        //         "realization",
        //     ]
        // ) {
        //     try await AgenticRuntimeFlowTesting
        //         .runApplicationRealization()
        // },
        TestFlow(
            "application-tool-catalog",
            tags: [
                "agentic-runtime",
                "application",
                "tools",
                "catalog",
                "exposure",
                "intrinsics",
            ]
        ) {
            try await AgenticRuntimeFlowTesting
                .runToolCatalogRealization()
        },
        TestFlow(
            "host-voice-input-provider",
            tags: [
                "agentic-host",
                "conversation",
                "voice",
                "provider",
                "composition",
            ]
        ) {
            try await AgenticRuntimeFlowTesting
                .runVoiceInputProvider()
        },
        TestFlow(
            "host-parity",
            tags: [
                "agentic-runtime",
                "host",
                "parity",
            ]
        ) {
            try await AgenticRuntimeFlowTesting
                .runHostParity()
        },
        TestFlow(
            "workspace-selection-ingress",
            tags: [
                "agentic-runtime",
                "workspace",
                "selection",
                "arguments",
                "authority",
            ]
        ) {
            try AgenticRuntimeFlowTesting
                .runWorkspaceSelectionIngress()
        },
        TestFlow(
            "workspace-resource-resolution",
            tags: [
                "agentic-runtime",
                "resource",
                "resolution",
                "workspace",
            ]
        ) {
            try await AgenticRuntimeFlowTesting
                .runWorkspaceResourceResolution()
        },
        TestFlow(
            "host-output-documents",
            tags: [
                "agentic-runtime",
                "host",
                "projection",
                "stdout",
                "stderr",
            ]
        ) {
            try AgenticRuntimeHostProjectionFlowTesting
                .runOutputDocuments()
        },
        TestFlow(
            "host-suspension-state-projection",
            tags: [
                "agentic-runtime",
                "host",
                "projection",
                "suspension",
                "recovery",
                "resume",
            ]
        ) {
            try AgenticRuntimeHostProjectionFlowTesting
                .runSuspensionStateProjection()
        },
        TestFlow(
            "host-empty-output-documents",
            tags: [
                "agentic-runtime",
                "host",
                "projection",
                "stdout",
                "stderr",
                "empty",
            ]
        ) {
            try AgenticRuntimeHostProjectionFlowTesting
                .runEmptyOutputDocuments()
        },
        TestFlow(
            "host-ready-documents",
            tags: [
                "agentic-runtime",
                "host",
                "pending",
                "preflight",
                "diff",
                "safety",
            ]
        ) {
            try await AgenticRuntimePendingDocumentFlowTesting
                .runReadyDocuments()
        },
        TestFlow(
            "host-authored-timeline",
            tags: [
                "agentic-runtime",
                "host",
                "projection",
                "tool-plan",
                "single-step",
                "paused",
            ]
        ) {
            try AgenticRuntimeHostAuthoredTimelineFlowTesting
                .runPausedFutureStepProjection()
        },
        TestFlow(
            "host-authored-branch-timeline",
            tags: [
                "agentic-runtime",
                "host",
                "projection",
                "tool-plan",
                "branch",
                "timeline",
                "history",
            ]
        ) {
            try AgenticRuntimeHostAuthoredTimelineFlowTesting
                .runActivatedFailureBranchProjection()
        },
        TestFlow(
            "host-authored-resume",
            tags: [
                "agentic-runtime",
                "host",
                "tool-plan",
                "single-step",
                "resume",
                "selection",
            ]
        ) {
            try await AgenticRuntimeHostAuthoredResumeFlowTesting
                .runResumeNextAuthoredOperation()
        },
        TestFlow(
            "host-review-boundary",
            tags: [
                "agentic-runtime",
                "host",
                "approval",
                "preflight",
                "diff",
                "single-step",
                "safety",
                "end-to-end",
            ]
        ) {
            try await AgenticRuntimePendingDocumentFlowTesting
                .runReviewBoundary()
        },
        TestFlow(
            "host-status-diagnostics",
            tags: [
                "agentic-runtime",
                "host",
                "status",
                "diagnostic",
                "persistence",
            ]
        ) {
            try await AgenticRuntimeHostStatusFlowTesting
                .runPersistentFailureStatus()
        },
        TestFlow(
            "host-run-copy",
            tags: [
                "agentic-runtime",
                "host",
                "copy",
                "input",
                "output",
                "bridge",
                "retention",
            ]
        ) {
            try await AgenticRuntimeHostRunCopyFlowTesting
                .runRetainedInputAndBridgeOutput()
        },
        TestFlow(
            "prepared-intent-tool-failure-persistence",
            tags: [
                "agentic-runtime",
                "prepared-intent",
                "tools",
                "failure",
                "phase",
                "persistence",
            ]
        ) {
            try await AgenticRuntimePreparedIntentFailureFlowTesting
                .run()
        },
        TestFlow(
            "tool-plan-deferred-pause",
            tags: [
                "agentic-runtime",
                "tool-plan",
                "execution-policy",
                "continuous",
                "pause",
                "boundary",
            ]
        ) {
            try await AgenticRuntimeToolPlanFlowTesting
                .runDeferredPause()
        },
        TestFlow(
            "tool-plan-single-step-resolution-policy",
            tags: [
                "agentic-runtime",
                "tool-plan",
                "execution-policy",
                "single-step",
                "recovery",
                "boundary",
            ]
        ) {
            try await AgenticRuntimeToolPlanFlowTesting
                .runSingleStepResolutionPolicy()
        },
        TestFlow(
            "tool-plan-recovery-retry",
            tags: [
                "agentic-runtime",
                "tool-plan",
                "recovery",
                "retry",
                "memory",
            ]
        ) {
            try await AgenticRuntimeToolPlanFlowTesting
                .runRecoveryThenRetry()
        },
        TestFlow(
            "tool-plan-recovery-skip",
            tags: [
                "agentic-runtime",
                "tool-plan",
                "recovery",
                "skip",
                "memory",
            ]
        ) {
            try await AgenticRuntimeToolPlanFlowTesting
                .runRecoveryThenSkip()
        },
        TestFlow(
            "tool-plan-recovery-hierarchy",
            tags: [
                "agentic-runtime",
                "tool-plan",
                "recovery",
                "hierarchy",
                "gating",
            ]
        ) {
            try await AgenticRuntimeToolPlanFlowTesting
                .runRecoveryHierarchyAndGating()
        },
        TestFlow(
            "adapter-stream-supported",
            tags: ["agentic-runtime", "adapter", "stream", "offline"]
        ) {
            try await AgenticRuntimeAdapterFlowTesting
                .runAdapterStreamSupported()
        },
        TestFlow(
            "adapter-tool-loop",
            tags: ["agentic-runtime", "adapter", "tool-use", "stream", "offline"]
        ) {
            try await AgenticRuntimeAdapterFlowTesting
                .runAdapterToolLoop()
        },
        TestFlow(
            "adapter-scratchpad-tool",
            tags: ["agentic-runtime", "adapter", "tool-use", "scratchpad", "offline"]
        ) {
            try await AgenticRuntimeAdapterFlowTesting
                .runAdapterScratchpadTool()
        },
        TestFlow(
            "adapter-scratchpad-read-write-loop",
            tags: ["agentic-runtime", "adapter", "tool-use", "scratchpad", "loop", "offline"]
        ) {
            try await AgenticRuntimeAdapterFlowTesting
                .runAdapterScratchpadReadWriteLoop()
        },



        TestFlow(
            "native-tool-invocation-lifecycle",
            tags: [
                "agentic-runtime",
                "tools",
                "resolver",
                "native",
                "approval",
                "discovery",
                "checkpoint",
            ]
        ) {
            try await AgenticRuntimeFlowTesting
                .runNativeToolInvocationLifecycle()
        },
        TestFlow(
            "tool-exposure-resolver",
            tags: [
                "agentic-runtime",
                "tools",
                "exposure",
                "resolver",
                "skills",
                "selection",
                "discovery",
            ]
        ) {
            try await AgenticRuntimeToolExposureFlowTesting
                .runResolverSemantics()
        },
        TestFlow(
            "tool-exposure-runtime-explicit",
            tags: [
                "agentic-runtime",
                "tools",
                "exposure",
                "explicit",
                "enforcement",
            ]
        ) {
            try await AgenticRuntimeToolExposureFlowTesting
                .runExplicitEnforcement()
        },
        TestFlow(
            "tool-exposure-runtime-skill-seeded",
            tags: [
                "agentic-runtime",
                "tools",
                "exposure",
                "skills",
                "discovery",
            ]
        ) {
            try await AgenticRuntimeToolExposureFlowTesting
                .runSkillSeededDiscovery()
        },
        TestFlow(
            "tool-exposure-runtime-approval-resume",
            tags: [
                "agentic-runtime",
                "tools",
                "exposure",
                "discovery",
                "approval",
                "checkpoint",
                "resume",
            ]
        ) {
            try await AgenticRuntimeToolExposureFlowTesting
                .runApprovalResumePersistence()
        },
        TestFlow(
            "tool-exposure-runtime-inspection",
            tags: [
                "agentic-runtime",
                "tools",
                "exposure",
                "inspection",
                "discovery",
            ]
        ) {
            try await AgenticRuntimeToolExposureFlowTesting
                .runExposureInspection()
        },
        TestFlow(
            "conversation-runtime-session",
            tags: ["agentic-runtime", "conversation", "agent-runner", "tool-use", "host-console", "discovery"]
        ) {
            try await AgenticRuntimeConversationFlowTesting.run()
        },
        TestFlow(
            "conversation-runtime-custom-tool-exposure",
            tags: [
                "agentic-runtime",
                "conversation",
                "tools",
                "catalog",
                "exposure",
                "custom",
                "skills",
                "discovery",
                "settings",
            ]
        ) {
            try await AgenticRuntimeConversationFlowTesting
                .runCustomToolExposureSelection()
        },
        TestFlow(
            "conversation-runtime-tool-exposure-selection",
            tags: [
                "agentic-runtime",
                "conversation",
                "tools",
                "exposure",
                "settings",
            ]
        ) {
            try await AgenticRuntimeConversationFlowTesting
                .runToolExposureSelection()
        },
        TestFlow(
            "conversation-runtime-recovered-tool-error",
            tags: [
                "agentic-runtime",
                "conversation",
                "agent-runner",
                "tools",
                "exposure",
                "recovery",
                "host-console",
                "observability",
            ]
        ) {
            try await AgenticRuntimeConversationFlowTesting
                .runRecoveredToolErrorProjection()
        },
        TestFlow(
            "conversation-runtime-failed-run",
            tags: [
                "agentic-runtime",
                "conversation",
                "agent-runner",
                "failure",
                "checkpoint",
                "host-console",
                "observability",
            ]
        ) {
            try await AgenticRuntimeConversationFlowTesting
                .runFailureObservability()
        },
        TestFlow(
            "conversation-runtime-live-state",
            tags: [
                "agentic-runtime",
                "conversation",
                "agent-runner",
                "streaming",
                "observability",
                "live-state",
            ]
        ) {
            try await AgenticRuntimeConversationFlowTesting
                .runLiveStateObservation()
        },




        TestFlow(
            "agent-host-local-service",
            tags: [
                "agentic-host",
                "local",
                "service",
                "headless",
                "observe",
                "transcript",
            ]
        ) {
            try await AgentHostLocalFlowTesting
                .runService()
        },
        TestFlow(
            "agent-host-local-approval-resume",
            tags: [
                "agentic-host",
                "local",
                "service",
                "approval",
                "interaction",
                "resume",
                "headless",
            ]
        ) {
            try await AgentHostLocalFlowTesting
                .runApprovalResume()
        },
    ]
}
