import Agentic
import AgenticHost
import AgenticIO
import AgenticRuntime
import AgenticTUI
import Foundation
import IO
import Primitives
import TestFlows
import Workspace

extension AgentHostLocalFlowTesting {
    /// `:path` and `:cd` against a live session: each change and refusal
    /// is traced in the session log, and the model hears of changes on its
    /// next turn.
    static func runWorkspaceCommands() async throws -> [TestDiagnostic] {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("host-workspace-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let project = fixture.appendingPathComponent("project", isDirectory: true)
        let notes = fixture.appendingPathComponent("notes", isDirectory: true)
        try FileSystem.default.directory.create(project)
        try FileSystem.default.directory.create(notes)
        try FileSystem.default.directory.create(notes.appendingPathComponent("drafts", isDirectory: true))
        defer { try? FileSystem.default.remove(fixture) }

        let logs = Run.Log.Store(storage: .init(root: fixture.appendingPathComponent(".agentic")))
        // The run's context targets the project root; the notes root is
        // reached by absolute path.
        let scan = FunctionCall(
            id: "scan-added-root",
            name: SystemIO.Tools.ScanFilepaths.identifier.rawValue,
            input: .object(["arguments": .object(["path": .string(notes.path)])])
        )
        let gateway = GatewayFlowScriptedModelGateway(bufferedResponses: [
            .init(message: .init(role: .assistant, content: .init(blocks: [.call(scan)])), stopReason: .tool_use),
            .init(message: .init(role: .assistant, text: "done"), stopReason: .end_turn),
        ])
        let host = AgentHost.Local(
            runtime: try await AgenticRuntime(application: Agentic.application(.init(rawValue: "host-workspace")) {
                tools { SystemIO.Tools.ScanFilepaths() }
                modelProvider(AgentHostLocalModelProvider(modelGateway: gateway))
            }),
            workspace: try AgenticRuntimeWorkspace.resolve(project.path),
            io: .blocking,
            logs: logs
        )
        let session: AgentHost.Session.ID = "workspace-commands"
        _ = try await host.start(.init(id: session))

        func run(_ text: String) async throws -> AgentHost.WorkspaceChangeResult {
            guard case .change(let change) = try AgenticWorkspaceCommand(parsing: text) else {
                throw WorkspaceCommandFixtureError.notAChange(text)
            }
            return try await host.changeWorkspace(session, change, command: text)
        }
        func refused(_ text: String) async -> Bool {
            (try? await run(text)) == nil
        }
        func traced(_ kind: Run.Event.State.Kind) throws -> [String] {
            try logs.read(session: session.rawValue).entries.compactMap {
                if case .state(let state) = $0.body, state.kind == kind { return state.summary }
                return nil
            }
        }

        try Expect.equal(
            try AgenticWorkspaceCommand(parsing: "path"),
            .list,
            "bare :path lists"
        )
        try Expect.equal(
            try AgenticWorkspaceCommand(parsing: "path deny 'my secrets' --root project"),
            .change(.deny(pattern: "my secrets", root: "project")),
            "quotes keep spaces and --root names the root"
        )
        try Expect.true(
            (try? AgenticWorkspaceCommand(parsing: "path add")) == nil,
            "add without a directory is a usage error"
        )

        let added = try await run("path add \(notes.path) --read")
        let notesRoot = try Expect.notNil(
            added.state.roots.first { $0.path == notes.path },
            "the added directory is a root"
        )
        try Expect.equal(notesRoot.source, .operator_command, "the root is marked as added")
        try Expect.equal(
            notesRoot.capabilities,
            [.list, .read, .scan],
            "--read adds a read-only root"
        )
        try Expect.true(await refused("path add \(notes.path)"), "adding a root twice is refused")
        try Expect.true(await refused("path add /"), "the filesystem root is refused")

        let denied = try await run("path deny '*.secret'")
        try Expect.equal(
            denied.state.roots.first { $0.source == .configured }?.restrictions.map(\.pattern),
            ["*.secret"],
            "a restriction lands on the working directory's root"
        )

        let moved = try await run("cd \(notes.path)")
        try Expect.equal(moved.state.directory, notes.path, ":cd moves the working directory")
        try Expect.true(moved.state.summary.hasSuffix("· +1 root"), "the header counts added roots")
        try Expect.true(await refused("cd /"), ":cd outside every root is refused")
        try Expect.true(await refused("path rm project"), "a configured root cannot be removed")

        let removed = try await run("path rm \(notesRoot.id)")
        try Expect.equal(removed.state.roots.count, 1, "removing leaves the configured root")
        try Expect.equal(
            removed.state.directory,
            project.path,
            "a working directory under a removed root returns to the configured one"
        )

        _ = try await run("path add \(notes.path) --read")

        let loose = fixture.appendingPathComponent("loose.txt")
        try "loose\n".write(to: loose, atomically: true, encoding: .utf8)
        let file = try await run("path add \(loose.path)")
        let fileRoot = try Expect.notNil(
            file.state.roots.first { $0.files == [loose.path] },
            "a file is added as itself: \(file.state.listing)"
        )
        try Expect.equal(
            fileRoot.capabilities,
            [.edit, .read, .write],
            "a file root carries only file capabilities"
        )

        let commands = try traced(.operator_command)
        try Expect.equal(commands.count, 10, "every command is traced, refused ones too")
        try Expect.true(
            commands.contains { $0.hasPrefix(":path add /") && $0.contains("refused") },
            "a refusal is traced with its reason"
        )
        try Expect.true(
            try traced(.workspace_changed).contains { $0.hasPrefix("removed notes") },
            "each effect is traced"
        )

        let result = try await host.submit(.init(
            session: session,
            prompt: "hello",
            execution: .init(configuration: .init(responseDelivery: .buffered))
        ))
        try Expect.true(result.isCompleted, "the turn completes")
        let messages = try await host.transcript(session).messages
        let scanned = messages.first { $0.role == .tool }.map { String(describing: $0.content) } ?? ""
        try Expect.true(
            scanned.contains("drafts") && !scanned.contains("not a descendant"),
            "a tool reaches an added root by absolute path: \(scanned)"
        )
        let opening = messages.first { $0.role == .user }
        try Expect.true(
            opening?.content.text.contains("Workspace changed by the operator") == true
                && opening?.content.text.contains("hello") == true,
            "the model's next turn opens with the changes"
        )
        return []
    }
}

private enum WorkspaceCommandFixtureError: Error {
    case notAChange(String)
}
