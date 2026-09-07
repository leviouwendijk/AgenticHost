import Agentic
import AgenticInterfaces
import AgenticRuntime
import AgenticExecution
import AgenticWorkspace
import AgenticIO
import AgenticTools
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
                title: "Core",
                defaultExposure: .included
            ) {
                CoreFileToolSet()
            }
        }

        skills {
            AgentSkill(
                identifier: "runtime-fixture-skill",
                name: "Runtime Fixture Skill",
                summary: "Proves runtime skill realization.",
                body: "Runtime realizes application declarations without selecting concrete domain packages."
            )
        }
    }
}

enum AgenticRuntimeFlowTesting {
    static func runToolCatalogRealization()
        async throws -> [TestFlowDiagnostic]
    {
        let runtime = try await AgenticRuntime.resolve(
            RuntimeFixtureApplication.self
        )
        let core = try Expect.notNil(
            runtime.toolCatalog.collection(
                identifiedBy: .init(
                    rawValue: "runtime.core"
                )
            ),
            "runtime retains declared Core tool collection"
        )
        let intrinsics = try Expect.notNil(
            runtime.toolCatalog.collection(
                identifiedBy:
                    AgentToolCollectionMetadata
                        .intrinsics
                        .identifier
            ),
            "runtime exposes one semantic Intrinsics collection"
        )

        try Expect.equal(
            core.title,
            "Core",
            "runtime retains application collection title"
        )
        try Expect.equal(
            core.defaultExposure,
            .included,
            "runtime retains application collection default exposure"
        )
        try Expect.equal(
            core.toolIdentifiers.contains(
                ReadFileTool.identifier
            ),
            true,
            "runtime Core collection resolves to exact tool identifiers"
        )

        try Expect.equal(
            intrinsics.defaultExposure,
            .excluded,
            "runtime intrinsics remain default excluded"
        )
        try Expect.equal(
            intrinsics.toolIdentifiers.contains(
                InspectToolRegistryTool.identifier
            ),
            true,
            "registry intrinsic remains catalogued"
        )
        try Expect.equal(
            intrinsics.toolIdentifiers.contains(
                FindToolsTool.identifier
            ),
            true,
            "runtime catalogs find_tools before executor installation"
        )
        try Expect.equal(
            intrinsics.toolIdentifiers.contains(
                InspectToolExposureTool.identifier
            ),
            true,
            "runtime catalogs exposure inspection before executor installation"
        )

        let findToolsEntry = try Expect.notNil(
            runtime.toolCatalog.entry(
                identifiedBy: FindToolsTool.identifier
            ),
            "find_tools has an addressable runtime catalog entry"
        )
        let exposureEntry = try Expect.notNil(
            runtime.toolCatalog.entry(
                identifiedBy: InspectToolExposureTool.identifier
            ),
            "inspect_tool_exposure has an addressable runtime catalog entry"
        )

        try Expect.equal(
            findToolsEntry.origin,
            .intrinsic,
            "find_tools is runtime intrinsic rather than application declared"
        )
        try Expect.equal(
            exposureEntry.origin,
            .intrinsic,
            "inspect_tool_exposure is runtime intrinsic rather than application declared"
        )

        try Expect.equal(
            runtime.tools.registeredTool(
                identifiedBy: FindToolsTool.identifier
            ) == nil,
            true,
            "cataloging find_tools does not install its executor-bound instance into the base registry"
        )
        try Expect.equal(
            runtime.tools.registeredTool(
                identifiedBy: InspectToolExposureTool.identifier
            ) == nil,
            true,
            "cataloging exposure inspection does not install its executor-bound instance into the base registry"
        )

        try Expect.equal(
            runtime.toolCatalog.defaultExposedIdentifiers.contains(
                ReadFileTool.identifier
            ),
            true,
            "included application collections contribute to default exposure"
        )
        try Expect.equal(
            runtime.toolCatalog.defaultExposedIdentifiers.contains(
                FindToolsTool.identifier
            ),
            false,
            "runtime intrinsics do not silently enter default exposure"
        )
        try Expect.equal(
            runtime.toolCatalog.defaultExposedIdentifiers.contains(
                InspectToolExposureTool.identifier
            ),
            false,
            "runtime exposure inspection does not silently enter default exposure"
        )

        return [
            .field(
                "collections",
                String(runtime.toolCatalog.collections.count)
            ),
            .field(
                "entries",
                String(runtime.toolCatalog.entries.count)
            ),
            .field(
                "intrinsics",
                String(intrinsics.toolIdentifiers.count)
            ),
            .field(
                "default_exposed",
                String(
                    runtime.toolCatalog
                        .defaultExposedIdentifiers
                        .count
                )
            ),
        ]
    }

    static func runApplicationRealization()
        async throws -> [TestFlowDiagnostic]
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

        try Expect.equal(
            runtime.skills.count,
            1,
            "runtime realized application skills"
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
            .field(
                "skills",
                String(runtime.skills.count)
            ),
        ]
    }

    static func runHostParity()
        async throws -> [TestFlowDiagnostic]
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
        async throws -> [TestFlowDiagnostic]
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

        let workspace = try AgentWorkspace(
            root: workspaceRoot
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
