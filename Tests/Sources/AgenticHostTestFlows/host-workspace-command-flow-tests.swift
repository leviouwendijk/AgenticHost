import Agentic
import AgenticConfiguration
@_spi(Testing) import AgenticConversation
@_spi(Testing) import AgenticHost
import AgenticIO
import AgenticInterfaces
import AgenticRuntime
@_spi(Testing) import AgenticTUI
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
            name: SystemIO.Tools.Find.identifier.rawValue,
            input: .object(["arguments": .object(["path": .string(notes.path)])])
        )
        let gateway = GatewayFlowScriptedModelGateway(bufferedResponses: [
            .init(message: .init(role: .assistant, content: .init(blocks: [.call(scan)])), stopReason: .tool_use),
            .init(message: .init(role: .assistant, text: "done"), stopReason: .end_turn),
        ])
        let host = AgentHost.Local(
            runtime: try await AgenticRuntime(application: Agentic.application(.init(rawValue: "host-workspace")) {
                tools { SystemIO.Tools.Find() }
                modelProvider(AgentHostLocalModelProvider(modelGateway: gateway))
            }),
            workspace: try AgenticRuntimeWorkspace.resolve(project.path),
            io: .blocking,
            logs: logs,
            pathSettings: {
                .init(scopes: ["drafts": PathScope(path: notes.path + "/drafts/**", readOnly: true)])
            }
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

        let complete = AgenticWorkspaceCommand.completer(
            directory: AgenticWorkingDirectory(fixture.path)
        )
        try Expect.equal(
            complete("path add no")?.candidates.map(\.text),
            ["notes/"],
            "path add completes directories relative to the working directory"
        )
        try Expect.equal(
            complete("path add \(fixture.path)/lo")?.candidates.map(\.title),
            ["loose.txt"],
            "path add completes files too, from an absolute path"
        )
        try Expect.equal(
            complete("cd ")?.candidates.map(\.title),
            ["notes/", "project/"],
            "cd completes directories only"
        )
        try Expect.true(complete("path deny x") == nil, "other commands take no completion")

        try Expect.equal(
            try AgenticWorkspaceCommand(parsing: "paths add notes --read"),
            .addScope("notes", readOnly: true),
            ":paths add names a PathScope"
        )
        let scoped = AgenticWorkspaceCommand.completer(
            directory: AgenticWorkingDirectory(fixture.path),
            scopes: { ["drafts", "notes"] }
        )
        try Expect.equal(
            scoped("paths add d")?.candidates.map(\.text),
            ["drafts"],
            ":paths add completes scope names"
        )

        let conversation = try await AgenticConversationSession(
            workspace: project.path,
            service: host,
            capabilities: try await host.capabilities(),
            sessionID: "workspace-scopes",
            textRendering: TerminalConversationTextRendering()
        )
        await conversation.runWorkspaceCommand("paths add drafts")
        let reply = await conversation.snapshot.messages.last?.body ?? ""
        try Expect.true(
            reply.hasPrefix(":paths add drafts\nadded drafts") && reply.contains("list, read, scan"),
            "a named scope is added read-only: \(reply)"
        )
        let drafts = await conversation.snapshot.workspaceRoots.first { $0.label == "drafts" }
        try Expect.true(
            drafts?.isRemovable == true && drafts?.source == "added"
                && drafts?.access.contains("read") == true,
            "the settings tree lists the added root: \(String(describing: drafts))"
        )
        try Expect.true(
            await conversation.snapshot.workspaceRoots.contains { $0.source == "configured" && !$0.isRemovable },
            "the configured root stays"
        )
        guard case .command(let added)? = await conversation.snapshot.messages.last?.attachments.first else {
            try Expect.true(false, "a command leaves a command card")
            return []
        }
        try Expect.true(
            !added.isRefused && added.contextEffect == .note
                && added.trace.contains { $0.hasPrefix("operator_command  :paths add drafts → added drafts") }
                && added.trace.contains { $0.hasPrefix("workspace_changed  added drafts") }
                && !added.trace.contains { $0.contains("settings:") },
            "the card carries the command's own trace, not the session start's: \(added.trace)"
        )
        await conversation.runWorkspaceCommand("paths add nothing")
        try Expect.true(
            (await conversation.snapshot.messages.last?.body ?? "").contains("No PathScope named 'nothing'"),
            "an unknown scope is refused"
        )
        guard case .command(let refused)? = await conversation.snapshot.messages.last?.attachments.first else {
            try Expect.true(false, "a refusal leaves a command card")
            return []
        }
        try Expect.true(
            refused.isRefused && refused.contextNote == nil
                && refused.trace == ["operator_command  :paths add nothing → refused: \(refused.outcome.dropFirst("refused: ".count))"],
            "a refusal is traced and changes nothing the model sees: \(refused.trace)"
        )

        let catalog = AgenticConsoleCommands.catalog
        try Expect.equal(
            catalog.names.count,
            catalog.definitions.count,
            "each command name is defined once"
        )
        try Expect.true(
            catalog.definition(for: "path add x")?.chapter == .workspace
                && catalog.definition(for: "interrupt next")?.chapter == .run
                && catalog.definition(for: "inference a {}")?.surfaces == [.conversation]
                && catalog.definition(for: "publish")?.chapter == .review,
            "dispatch reads the catalog"
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
        let refusals = try logs.read(session: "workspace-scopes").entries.compactMap { entry -> String? in
            guard case .state(let state) = entry.body, state.kind == .operator_command else { return nil }
            return state.summary
        }
        try Expect.true(
            refusals.contains { $0.hasPrefix(":paths add nothing → refused") },
            "an unknown scope is refused by the Host and traced: \(refusals)"
        )

        // settings.paths at session start: allow becomes a root, deny a
        // restriction on the root containing it; both traced.
        let configured = AgentHost.Local(
            runtime: try await AgenticRuntime(application: Agentic.application("host-workspace-settings") {
                modelProvider(AgentHostLocalModelProvider(modelGateway: gateway))
            }),
            workspace: try AgenticRuntimeWorkspace.resolve(project.path),
            io: .blocking,
            logs: logs,
            pathSettings: {
                .init(paths: .init(
                    allow: [PathScope(path: notes.path + "/**", readOnly: true)],
                    deny: [PathScope(path: project.path + "/secrets/**")]
                ))
            }
        )
        let started: AgentHost.Session.ID = "workspace-settings"
        _ = try await configured.start(.init(id: started))
        let startState = try await configured.workspace(started)
        try Expect.equal(
            startState.roots.first { $0.path == notes.path }?.source,
            .settings,
            "an allow scope is a root from settings"
        )
        try Expect.equal(
            startState.roots.first { $0.source == .configured }?.restrictions.map(\.pattern),
            ["secrets/**"],
            "a deny scope restricts the root containing it"
        )
        let startEffects = try logs.read(session: started.rawValue).entries.compactMap { entry -> String? in
            guard case .state(let state) = entry.body, state.kind == .workspace_changed else { return nil }
            return state.summary
        }
        try Expect.equal(startEffects.filter { $0.hasPrefix("settings: ") }.count, 2, "both traced: \(startEffects)")

        // In a conversation, what settings applied at start shows as a
        // workspace change, and `:context` lists it.
        let settingsConversation = try await AgenticConversationSession(
            workspace: project.path,
            service: configured,
            capabilities: try await configured.capabilities(),
            sessionID: "workspace-settings-conversation",
            textRendering: TerminalConversationTextRendering()
        )
        await settingsConversation.runWorkspaceCommand("path")
        let changes = await settingsConversation.changes()
        try Expect.true(
            changes.count == 1 && changes[0].kind == .workspace && changes[0].items.count == 2,
            "settings applied at start is one workspace change: \(changes.map(\.line))"
        )
        guard case .command(let listed)? = await settingsConversation.snapshot.messages.last?.attachments.first else {
            try Expect.true(false, "the listing leaves a card")
            return []
        }
        try Expect.true(listed.trace.isEmpty, "settings at start is not the listing's trace: \(listed.trace)")
        await settingsConversation.runContextCommand("context")
        try Expect.true(
            (await settingsConversation.snapshot.messages.last?.body ?? "").contains("workspace · 2 from settings.paths"),
            ":context lists the change"
        )
        await settingsConversation.runContextCommand("context everything")
        try Expect.true(
            (await settingsConversation.snapshot.messages.last?.body ?? "").contains("refused: usage: :context [all]"),
            ":context refuses an unknown argument"
        )
        return []
    }
}

private enum WorkspaceCommandFixtureError: Error {
    case notAChange(String)
}

extension AgentHostLocalFlowTesting {
    /// `:path add <dir> --ask`: the root exists but grants nothing; a call
    /// that needs it suspends for the operator like a requested grant, and
    /// a turn grant lets the model's retry through.
    static func runAskAccess() async throws -> [TestDiagnostic] {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("host-ask-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let project = fixture.appendingPathComponent("project", isDirectory: true)
        let notes = fixture.appendingPathComponent("notes", isDirectory: true)
        try FileSystem.default.directory.create(project)
        try FileSystem.default.directory.create(notes)
        defer { try? FileSystem.default.remove(fixture) }
        let note = notes.appendingPathComponent("a.md")
        try "the note\n".write(to: note, atomically: true, encoding: .utf8)

        func read(_ id: String) -> AgentResponse {
            .init(message: .init(role: .assistant, content: .init(blocks: [.call(FunctionCall(
                id: id,
                name: SystemIO.Tools.Read.identifier.rawValue,
                input: .object(["arguments": .object(["path": .string(note.path)])])
            ))])), stopReason: .tool_use)
        }
        let gateway = GatewayFlowScriptedModelGateway(bufferedResponses: [
            read("first-read"),
            read("retry"),
            .init(message: .init(role: .assistant, text: "read it"), stopReason: .end_turn),
        ])
        let host = AgentHost.Local(
            runtime: try await AgenticRuntime(application: Agentic.application("host-ask") {
                tools { SystemIO.Tools.Read() }
                modelProvider(AgentHostLocalModelProvider(modelGateway: gateway))
            }),
            workspace: try AgenticRuntimeWorkspace.resolve(project.path),
            io: .blocking
        )
        let session: AgentHost.Session.ID = "ask-access"
        _ = try await host.start(.init(id: session))

        guard case .change(let change) = try AgenticWorkspaceCommand(parsing: "path add \(notes.path) --ask") else {
            throw WorkspaceCommandFixtureError.notAChange("--ask")
        }
        let added = try await host.changeWorkspace(session, change, command: "path add --ask")
        try Expect.true(added.state.roots.contains { $0.path == notes.path && $0.asks }, "an ask root: \(added.state.listing)")

        let execution = AgentHost.Session.Execution(configuration: .init(autonomyMode: .auto_observe, responseDelivery: .buffered))
        let suspended = try await host.submit(.init(session: session, prompt: "read the note", execution: execution))
        let request = try Expect.notNil(suspended.interactionRequest, "the read asks the operator")
        guard case .workspace_access(let access) = request.requirement else {
            throw WorkspaceCommandFixtureError.notAChange("expected a workspace access request")
        }
        try Expect.equal(access.rootPath, notes.path, "for the ask root")
        try Expect.true(access.capabilities.contains(.read), "for the capability the call needed")

        let resumed = try await host.resume(.init(request: request, resolution: .workspace_access(.grant_for_turn)))
        try Expect.equal(resumed.response?.message.content.text, "read it", "the retry is let through")
        let toolResults = resumed.state.messages.filter { $0.role == .tool }.map { String(describing: $0.content) }
        try Expect.true(
            toolResults.contains { $0.contains("the note") },
            "the granted read returned the file"
        )
        return []
    }
}
