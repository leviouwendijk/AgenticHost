import Agentic
import AgenticIO
import AgenticInterfaces
import AgenticExecution
import AgenticRuntime
import AgenticCommandLine
import Foundation
import TestFlows

private struct PendingDocumentFixtureApplication:
    AgenticApplicationProviding
{
    static let application = Agentic.application(
        "pending-document-fixture",
        title: "Pending Document Fixture"
    ) {
        tools {
            CoreFileToolSet()
        }
    }
}

enum AgenticRuntimePendingDocumentFlowTesting {
    static func runReadyDocuments()
        async throws -> [TestFlowDiagnostic]
    {
        let runtime = try await AgenticRuntime.resolve(
            PendingDocumentFixtureApplication.self
        )
        let workspaceRoot = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "agentic-runtime-pending-document-\(UUID().uuidString)",
                isDirectory: true
            )

        try FileManager.default.createDirectory(
            at: workspaceRoot,
            withIntermediateDirectories: true
        )

        defer {
            try? FileManager.default.removeItem(
                at: workspaceRoot
            )
        }

        let targetName = "pending-preview.txt"
        let targetURL = workspaceRoot.appendingPathComponent(
            targetName
        )
        let host = try runtime.host(
            workspacePath: workspaceRoot.path,
            sessionID: "pending-document-session"
        )
        let call = AgentToolCall(
            id: "pending-create",
            name: MutateFilesTool.identifier.rawValue,
            input: try JSONToolBridge.encode(
                MutateFilesToolInput(
                    reason: "Prove READY diff inspection does not invoke mutation.",
                    entries: [
                        .init(
                            kind: .create_text,
                            path: targetName,
                            content: "pending preview\n"
                        ),
                    ]
                )
            )
        )
        let pending = HostPendingCall(
            runID: "pending-document-run",
            path: "root.sequence[0]",
            call: call,
            execution: nil
        )

        let details = try await HostPendingDocumentMaterializer.document(
            host: host,
            pending: pending,
            kind: .details
        )
        let stdout = try await HostPendingDocumentMaterializer.document(
            host: host,
            pending: pending,
            kind: .stdout
        )
        let stderr = try await HostPendingDocumentMaterializer.document(
            host: host,
            pending: pending,
            kind: .stderr
        )

        try Expect.contains(
            details.body,
            "Summary",
            "pending details structured summary"
        )
        try Expect.contains(
            details.body,
            "ready",
            "pending details state"
        )
        try Expect.contains(
            details.body,
            MutateFilesTool.identifier.rawValue,
            "pending details tool"
        )
        try Expect.contains(
            details.body,
            "root.sequence[0]",
            "pending details path"
        )
        try Expect.contains(
            details.body,
            "\"reason\"",
            "pending details pretty JSON input"
        )
        try Expect.false(
            details.body.contains(
                "JSONValue"
            ),
            "pending details avoid Swift JSONValue descriptions"
        )
        try Expect.equal(
            stdout.body,
            "No stdout available yet.",
            "pending stdout feedback"
        )
        try Expect.equal(
            stderr.body,
            "No stderr available yet.",
            "pending stderr feedback"
        )
        try Expect.false(
            FileManager.default.fileExists(
                atPath: targetURL.path
            ),
            "pending target absent before diff preview"
        )

        let diff = try await HostPendingDocumentMaterializer.document(
            host: host,
            pending: pending,
            kind: .diff
        )

        try Expect.contains(
            diff.body,
            "status     pre-execution preview",
            "pending diff provenance"
        )
        try Expect.contains(
            diff.body,
            "Preview may change before execution.",
            "pending diff staleness note"
        )
        try Expect.contains(
            diff.body,
            targetName,
            "pending diff target"
        )
        try Expect.contains(
            diff.body,
            "pending preview",
            "pending diff content"
        )
        try Expect.false(
            FileManager.default.fileExists(
                atPath: targetURL.path
            ),
            "pending diff review does not invoke mutation"
        )

        return [
            .field(
                "tool",
                call.name
            ),
            .field(
                "diff-bytes",
                String(diff.body.utf8.count)
            ),
            .field(
                "filesystem-mutated",
                "false"
            ),
        ]
    }

    static func runReviewBoundary()
        async throws -> [TestFlowDiagnostic]
    {
        let runtime = try await AgenticRuntime.resolve(
            PendingDocumentFixtureApplication.self
        )
        let workspaceRoot = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "agentic-runtime-host-review-\(UUID().uuidString)",
                isDirectory: true
            )

        try FileManager.default.createDirectory(
            at: workspaceRoot,
            withIntermediateDirectories: true
        )

        defer {
            try? FileManager.default.removeItem(
                at: workspaceRoot
            )
        }

        let targetName = "approved-review.txt"
        let futureName = "future-should-not-run.txt"
        let targetURL = workspaceRoot.appendingPathComponent(
            targetName
        )
        let futureURL = workspaceRoot.appendingPathComponent(
            futureName
        )
        let host = try runtime.host(
            workspacePath: workspaceRoot.path,
            sessionID: "host-review-boundary-session"
        )
        let call = AgentToolCall(
            id: "approved-review-create",
            name: MutateFilesTool.identifier.rawValue,
            input: try JSONToolBridge.encode(
                MutateFilesToolInput(
                    reason: "Prove the persistent host review boundary.",
                    entries: [
                        .init(
                            kind: .create_text,
                            path: targetName,
                            content: "approved mutation\n"
                        ),
                    ]
                )
            )
        )
        let futureCall = AgentToolCall(
            id: "future-batch-create",
            name: MutateFilesTool.identifier.rawValue,
            input: try JSONToolBridge.encode(
                MutateFilesToolInput(
                    reason: "This later batch call must not run during the first single-step boundary.",
                    entries: [
                        .init(
                            kind: .create_text,
                            path: futureName,
                            content: "future mutation\n"
                        ),
                    ]
                )
            )
        )
        let pending = HostPendingCall(
            runID: "host-review-boundary-run",
            path: "root.sequence[0]",
            call: call,
            execution: nil
        )

        let preExecutionDiff = try await HostPendingDocumentMaterializer.document(
            host: host,
            pending: pending,
            kind: .diff
        )

        try Expect.contains(
            preExecutionDiff.body,
            "status     pre-execution preview",
            "READY diff provenance"
        )
        try Expect.contains(
            preExecutionDiff.body,
            targetName,
            "READY diff target"
        )
        try Expect.false(
            FileManager.default.fileExists(
                atPath: targetURL.path
            ),
            "READY review does not mutate filesystem"
        )

        let plan = AgentToolPlan(
            id: "host-review-boundary-plan",
            root: .sequence(
                [
                    .call(
                        call
                    ),
                    .batch(
                        [
                            .call(
                                futureCall
                            ),
                        ]
                    ),
                ]
            )
        )
        let coordinator = AgentToolPlanRunCoordinator(
            invoker: host.invoker,
            context: host.context,
            approvalHandler: nil
        )
        let awaiting = try await coordinator.start(
            plan,
            runID: pending.runID,
            executionPolicy: .single_step
        )

        try Expect.false(
            FileManager.default.fileExists(
                atPath: targetURL.path
            ),
            "approval suspension does not mutate filesystem"
        )
        try Expect.false(
            FileManager.default.fileExists(
                atPath: futureURL.path
            ),
            "later batch does not execute before first call"
        )

        let stagedSnapshot = HostProjection.snapshot(
            runs: [
                awaiting,
            ],
            context: "host review boundary"
        )

        try Expect.equal(
            stagedSnapshot.interruptions.first?.kind,
            Optional(
                AgenticHostConsoleInterruptionKind.approval
            ),
            "run is awaiting approval"
        )

        let stagedDetails = stagedSnapshot.documents.first {
            $0.stepID == call.id
                && $0.kind == .details
        }
        let stagedDiff = stagedSnapshot.documents.first {
            $0.stepID == call.id
                && $0.kind == .diff
        }

        try Expect.equal(
            stagedDetails?.title,
            Optional(
                "Staged intent details"
            ),
            "authoritative details title"
        )
        try Expect.contains(
            stagedDetails?.body ?? "",
            call.id,
            "authoritative details call id"
        )
        try Expect.contains(
            stagedDiff?.body ?? "",
            "status     staged for approval",
            "authoritative diff provenance"
        )
        try Expect.contains(
            stagedDiff?.body ?? "",
            targetName,
            "authoritative diff target"
        )
        try Expect.false(
            FileManager.default.fileExists(
                atPath: targetURL.path
            ),
            "authoritative staged review still does not mutate filesystem"
        )

        let approved = try await coordinator.decide(
            runID: pending.runID,
            expectedRevision: awaiting.revision,
            decision: .approved
        )

        try Expect.equal(
            FileManager.default.fileExists(
                atPath: targetURL.path
            ),
            true,
            "approval invokes mutation"
        )
        try Expect.equal(
            try String(
                contentsOf: targetURL,
                encoding: .utf8
            ),
            "approved mutation\n",
            "approved mutation content"
        )
        try Expect.false(
            FileManager.default.fileExists(
                atPath: futureURL.path
            ),
            "single-step approval stops before later batch"
        )

        let executedSnapshot = HostProjection.snapshot(
            runs: [
                approved,
            ],
            context: "host review boundary approved"
        )
        let stdout = executedSnapshot.documents.first {
            $0.stepID == call.id
                && $0.kind == .stdout
        }
        let stderr = executedSnapshot.documents.first {
            $0.stepID == call.id
                && $0.kind == .stderr
        }

        try Expect.equal(
            stdout?.body,
            Optional(
                "stdout is empty."
            ),
            "approved zero-byte stdout"
        )
        try Expect.equal(
            stderr?.body,
            Optional(
                "stderr is empty."
            ),
            "approved zero-byte stderr"
        )

        return [
            .field(
                "ready-mutated",
                "false"
            ),
            .field(
                "awaiting-mutated",
                "false"
            ),
            .field(
                "approved-mutated",
                "true"
            ),
            .field(
                "future-batch-executed",
                "false"
            ),
        ]
    }
}
