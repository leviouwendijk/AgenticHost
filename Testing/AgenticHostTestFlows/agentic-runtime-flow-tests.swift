import Agentic
import AgenticInterfaces
import AgenticRuntime
import Workspace
import AgenticIO
import AgenticStandard
import Foundation
import TestFlows

private struct RuntimeFixtureApplication:
    AgenticApplicationProviding
{
    static let application = Agentic.application(
        "runtime-fixture",
        title: "Runtime Fixture",
        metadata: [
            "fixture": "true",
        ]
    ) {
        tools {
            collection(
                "runtime.core",
                title: "Core"
            ) {
                CoreFileToolSet()
            }
        }

    }
}

enum AgenticRuntimeFlowTesting {
    static func runToolPresentationRealization()
        async throws -> [TestDiagnostic]
    {
        let runtime = try await AgenticRuntime.resolve(
            RuntimeFixtureApplication.self
        )
        let inventory = try runtime.toolPresentation()
        let core = try Expect.notNil(
            inventory.collection(
                identifiedBy: .init(
                    rawValue: "runtime.core"
                )
            ),
            "runtime retains declared Core tool collection in executable inventory"
        )
        let readFile = try Expect.notNil(
            inventory.entry(
                identifiedBy: SystemIO.Tools.ReadFile.identifier
            ),
            "read_file has an addressable executable inventory entry"
        )

        try Expect.equal(
            core.title,
            "Core",
            "runtime retains application collection title"
        )
        try Expect.equal(
            core.toolIdentifiers.contains(
                SystemIO.Tools.ReadFile.identifier
            ),
            true,
            "runtime Core inventory collection resolves exact tool identifiers"
        )
        try Expect.equal(
            readFile.collectionIdentifier,
            core.identifier,
            "runtime inventory entry retains executable collection membership"
        )
        try Expect.equal(
            readFile.isModelFacing,
            true,
            "derived presentation reflects model-facing Tool metadata"
        )
        try Expect.equal(
            runtime.installed.capabilities.tools.count,
            runtime.tools.count,
            "installed capability universe comes from executable bindings"
        )

        return [
            .field(
                "collections",
                String(inventory.collections.count)
            ),
            .field(
                "entries",
                String(inventory.entries.count)
            ),
        ]
    }

    static func runApplicationRealization()
        async throws -> [TestDiagnostic]
    {
        let runtime = try await AgenticRuntime.resolve(
            RuntimeFixtureApplication.self
        )

        try Expect.equal(
            runtime.application.identifier.rawValue,
            "runtime-fixture",
            "runtime application identifier"
        )

        try Expect.equal(
            runtime.tools.count,
            7,
            "runtime realized CoreFileToolSet"
        )

        return [
            .field(
                "application",
                runtime.application.identifier.rawValue
            ),
            .field(
                "tools",
                String(runtime.tools.count)
            ),
        ]
    }

    static func runHostParity()
        async throws -> [TestDiagnostic]
    {
        let runtime = try await AgenticRuntime.resolve(
            RuntimeFixtureApplication.self
        )

        let workspaceRoot = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "agentic-runtime-host-\(UUID().uuidString)",
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

        let host = try runtime.host(
            workspacePath: workspaceRoot.path,
            sessionID: "runtime-host-session"
        )

        let list = host.list()
        let manifest = try host.capabilityManifestText()

        try Expect.equal(
            list.action,
            .list,
            "host list action"
        )

        try Expect.contains(
            manifest,
            "runtime-host-session",
            "manifest session"
        )

        try Expect.contains(
            manifest,
            workspaceRoot.path,
            "manifest workspace"
        )

        try Expect.contains(
            manifest,
            "read_file",
            "manifest runtime tools"
        )

        return [
            .field(
                "workspace",
                workspaceRoot.path
            ),
            .field(
                "session",
                "runtime-host-session"
            ),
            .field(
                "tool_count",
                String(runtime.tools.count)
            ),
        ]
    }

    static func runWorkspaceResourceResolution()
        async throws -> [TestDiagnostic]
    {
        let workspaceRoot = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "agentic-resource-resolution-\(UUID().uuidString)",
                isDirectory: true
            )
        let fixtureURL = workspaceRoot.appendingPathComponent(
            "fixture.bin",
            isDirectory: false
        )
        let fixtureData = Data(
            "resource-fixture".utf8
        )

        try FileManager.default.createDirectory(
            at: workspaceRoot,
            withIntermediateDirectories: true
        )
        try fixtureData.write(
            to: fixtureURL,
            options: .atomic
        )

        defer {
            try? FileManager.default.removeItem(
                at: workspaceRoot
            )
        }

        let workspace = try AgenticRuntimeWorkspace.resolve(
            workspaceRoot.path
        )
        let resolver = WorkspaceAgentResourceResolver(
            workspace: workspace
        )

        let reference = try await resolver.resolve(
            AgentResource(
                id: "reference-fixture",
                modality: .document,
                source: .init(
                    kind: .reference,
                    value: "fixture.bin"
                ),
                contentType: "application/octet-stream"
            )
        )

        let uri = try await resolver.resolve(
            AgentResource(
                id: "uri-fixture",
                modality: .document,
                source: .init(
                    kind: .uri,
                    value: fixtureURL.absoluteString
                ),
                contentType: "application/octet-stream"
            )
        )

        try Expect.equal(
            reference.data,
            fixtureData,
            "workspace reference resource data"
        )

        try Expect.equal(
            reference.byteCount,
            fixtureData.count,
            "workspace reference resource byte count"
        )

        try Expect.equal(
            reference.resource.metadata.filename ?? "",
            "fixture.bin",
            "workspace reference resource filename"
        )

        try Expect.equal(
            uri.data,
            fixtureData,
            "workspace file URI resource data"
        )

        return [
            .field(
                "reference_bytes",
                String(reference.byteCount)
            ),
            .field(
                "uri_bytes",
                String(uri.byteCount)
            ),
        ]
    }
}
