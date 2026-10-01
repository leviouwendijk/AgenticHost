import AgenticRuntime
import AgenticCommandLine
import Workspace
import Foundation
import TestFlows

extension AgenticRuntimeFlowTesting {
    static func runWorkspaceSelectionIngress()
        throws -> [TestDiagnostic]
    {
        let workspaceRoot =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "agentic-runtime-workspace-ingress-\(UUID().uuidString)",
                    isDirectory: true
                )

        defer {
            try? FileManager.default.removeItem(
                at: workspaceRoot
            )
        }

        try FileManager.default.createDirectory(
            at: workspaceRoot.appendingPathComponent(
                "Allowed/Public",
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )

        let arguments =
            AgenticRuntimeWorkspaceArguments()
        arguments.root = workspaceRoot.path

        let configuration =
            try arguments.configuration()

        try Expect.equal(
            configuration.path,
            workspaceRoot.path,
            "workspace CLI arguments preserve the selected physical root"
        )

        let workspace =
            try AgenticRuntimeWorkspace.resolve(
                configuration
            )
        let rootContext =
            try workspace.context()
        let nestedContext =
            try workspace.context(
                at: "Allowed/Public"
            )
        let expectedRoot =
            workspaceRoot
                .standardizedFileURL
                .resolvingSymlinksInPath()

        try Expect.equal(
            rootContext.rootURL.path,
            expectedRoot.path,
            "runtime workspace resolves the configured physical root"
        )
        try Expect.equal(
            nestedContext.rootIdentifier,
            rootContext.rootIdentifier,
            "nested workspace context preserves the configured root identity"
        )
        try Expect.equal(
            nestedContext.absoluteURL.path,
            expectedRoot
                .appendingPathComponent(
                    "Allowed/Public",
                    isDirectory: true
                )
                .standardizedFileURL
                .path,
            "workspace context resolves a root-relative descendant"
        )

        let defaults =
            try AgenticRuntimeWorkspaceArguments()
                .configuration()

        try Expect.equal(
            defaults.path,
            ".",
            "workspace CLI arguments retain current-directory default"
        )

        return [
            .field(
                "root",
                rootContext.rootURL.path
            ),
            .field(
                "root_id",
                rootContext.rootIdentifier.rawValue
            ),
            .field(
                "nested",
                nestedContext.absoluteURL.path
            ),
        ]
    }
}
