import AgenticRuntime
import AgenticCommandLine
import AgenticWorkspace
import Foundation
import TestFlows

extension AgenticRuntimeFlowTesting {
    static func runWorkspaceSelectionIngress()
        throws -> [TestFlowDiagnostic]
    {
        let workspaceRoot =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "agentic-runtime-workspace-selection-\(UUID().uuidString)",
                    isDirectory: true
                )

        defer {
            try? FileManager.default.removeItem(
                at: workspaceRoot
            )
        }

        for subpath in [
            "Allowed/Public",
            "Allowed/Private",
            "Denied",
        ] {
            try FileManager.default.createDirectory(
                at: workspaceRoot.appendingPathComponent(
                    subpath,
                    isDirectory: true
                ),
                withIntermediateDirectories: true
            )
        }

        let arguments =
            AgenticRuntimeWorkspaceArguments()
        arguments.root = workspaceRoot.path
        arguments.exactPaths = [
            "Allowed",
        ]
        arguments.includeExpressions = [
            "Allowed/**",
        ]
        arguments.excludeExpressions = [
            "Allowed/Private",
            "Allowed/Private/**",
        ]

        let configuration =
            try arguments.configuration()
        let workspace =
            try AgenticRuntimeWorkspace.resolve(
                configuration
            )

        _ = try workspace.location(
            for: .init(
                subpath: "Allowed"
            )
        )
        _ = try workspace.location(
            for: .init(
                subpath: "Allowed/Public"
            )
        )

        try Expect.true(
            try selectionDenies(
                workspace,
                subpath: "Denied"
            ),
            "workspace selection excludes paths outside its positive selection"
        )
        try Expect.true(
            try selectionDenies(
                workspace,
                subpath: "Allowed/Private"
            ),
            "workspace selection exclusions override includes"
        )

        let exactOnly =
            try AgenticRuntimeWorkspace.resolve(
                AgenticRuntimeWorkspaceConfiguration(
                    path: workspaceRoot.path,
                    exactPaths: [
                        "Allowed",
                    ]
                )
            )

        _ = try exactOnly.location(
            for: .init(
                subpath: "Allowed"
            )
        )
        try Expect.true(
            try selectionDenies(
                exactOnly,
                subpath: "Allowed/Public"
            ),
            "workspace exact paths do not implicitly include descendants"
        )

        let defaults =
            try AgenticRuntimeWorkspaceArguments()
                .configuration()

        try Expect.equal(
            defaults.path,
            ".",
            "workspace CLI arguments preserve the current-directory default root"
        )
        try Expect.true(
            defaults.selection.isAll,
            "workspace CLI arguments preserve unrestricted selection when no selectors are supplied"
        )

        return [
            .field(
                "workspace",
                configuration.path
            ),
            .field(
                "exact_paths",
                "1"
            ),
            .field(
                "includes",
                "1"
            ),
            .field(
                "excludes",
                "2"
            ),
        ]
    }

    private static func selectionDenies(
        _ workspace: AgentWorkspace,
        subpath: String
    ) throws -> Bool {
        do {
            _ = try workspace.location(
                for: .init(
                    subpath: subpath
                )
            )
            return false
        } catch let error as WorkspaceAccessError {
            if case .selectionDenied = error {
                return true
            }

            throw error
        }
    }
}
