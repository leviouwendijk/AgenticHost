import Agentic
import AgenticIO
import AgenticRuntime
import Foundation
import IO
import Path
import PathParsing
import Workspace

public extension AgentHost {
    /// A session's workspace as the operator sees it: the configured roots
    /// and every change made on top of them.
    struct WorkspaceState: Sendable, Hashable {
        public struct Root: Sendable, Hashable, Identifiable {
            public enum Source: String, Sendable, Hashable {
                /// From the workspace configuration; cannot be removed here.
                case configured
                /// Added with `:path add`.
                case operator_command
                /// Requested by the model and approved.
                case request
            }

            public var id: String
            public var label: String
            public var path: String
            /// Absolute paths of the only files this root grants, when it
            /// was added for single files.
            public var files: [String]
            public var capabilities: [WorkspaceCapability]
            public var source: Source
            public var lifetime: WorkspaceAccessLifetime?
            public var expiresAt: Date?
            public var restrictions: [Restriction]
            public var isDefault: Bool
        }

        public struct Restriction: Sendable, Hashable, Identifiable {
            public var id: String
            public var pattern: String
        }

        public var roots: [Root]
        /// Where relative paths resolve.
        public var directory: String
        /// A run is in progress; changes apply when it resumes or at the
        /// next turn.
        public var isDeferred: Bool

        /// `~/main/swiftlibs · +1 root`, for a header.
        public var summary: String {
            let home = NSHomeDirectory()
            let shown = directory == home || directory.hasPrefix(home + "/")
                ? "~" + directory.dropFirst(home.count)
                : directory
            let extra = roots.count - 1
            guard extra > 0 else { return shown }
            return "\(shown) · +\(extra) root\(extra == 1 ? "" : "s")"
        }

        /// One line per root, then its restrictions.
        public var listing: String {
            var lines = ["directory  \(directory)"]
            for root in roots {
                let capabilities = root.capabilities.map(\.rawValue).joined(separator: ", ")
                let source: String
                switch root.source {
                case .configured: source = "configured"
                case .operator_command: source = "added · \(root.lifetime?.rawValue ?? "session")"
                case .request: source = "model request · \(root.lifetime?.rawValue ?? "session")"
                }
                let path = root.files.isEmpty ? root.path : root.files.joined(separator: ", ")
                lines.append(
                    "\(root.isDefault ? "*" : " ") \(root.id)  \(path)  [\(capabilities)]  \(source)"
                )
                for restriction in root.restrictions {
                    lines.append("    deny \(restriction.pattern)  (\(restriction.id.prefix(8)))")
                }
            }
            return lines.joined(separator: "\n")
        }
    }

    enum WorkspaceChange: Sendable, Hashable {
        /// A directory as a new root, for the session; or a single file,
        /// granted alone under a root at its directory.
        case add(path: String, capabilities: Set<WorkspaceCapability>)
        /// A root added this session (by id or path), or a restriction (by
        /// id or pattern). Configured roots stay.
        case remove(String)
        /// A deny rule on a root, the working directory's by default. A bare
        /// name denies that path component anywhere; anything else is a
        /// path expression relative to the root.
        case deny(pattern: String, root: String?)
        /// `nil` returns to the configured default root.
        case changeDirectory(String?)
    }

    struct WorkspaceChangeResult: Sendable, Hashable {
        /// What changed, as recorded in the session log.
        public var outcome: String
        public var state: WorkspaceState
    }
}

extension AgentHostLocalSessionState {
    func workspaceState() throws -> AgentHost.WorkspaceState {
        let leases = accessLeases.expiring()
        guard let effective = try leases.effectiveWorkspace(
            base: workspace,
            turnID: currentRunID
        ) else {
            throw AgentHost.Local.Failure.workspaceNotConfigured
        }
        let active = leases.active(for: currentRunID)
        let roots = effective.roots.map { root -> AgentHost.WorkspaceState.Root in
            let lease = active.last { $0.request.rootID == root.id.rawValue }
            let source: AgentHost.WorkspaceState.Root.Source
            if workspace?.root(identifier: root.id) != nil {
                source = .configured
            } else {
                source = lease?.origin == .operator_command ? .operator_command : .request
            }
            let capabilities = Set(
                effective.grants
                    .filter {
                        $0.rootIdentifier == root.id
                            && effective.status(of: $0.id) == .active
                    }
                    .flatMap(\.capabilities)
            )
            return .init(
                id: root.id.rawValue,
                label: root.label,
                path: root.rootPath,
                files: source == .configured ? [] : (lease?.request.files ?? []).map {
                    (root.rootPath as NSString).appendingPathComponent($0)
                },
                capabilities: capabilities.sorted { $0.rawValue < $1.rawValue },
                source: source,
                lifetime: source == .configured ? nil : lease?.lifetime,
                expiresAt: source == .configured ? nil : lease?.expiresAt,
                restrictions: leases.restrictions
                    .filter { $0.rootID == root.id.rawValue }
                    .map { .init(id: $0.id, pattern: $0.pattern) },
                isDefault: root.id == effective.defaultRootIdentifier
            )
        }
        .sorted { ($0.source == .configured ? 0 : 1, $0.path) < ($1.source == .configured ? 0 : 1, $1.path) }

        return .init(
            roots: roots,
            directory: leases.directory?.path
                ?? roots.first(where: \.isDefault)?.path
                ?? "",
            isDeferred: hasActiveMutationWork()
        )
    }

    /// Applies an operator's change and traces it: the command and its
    /// outcome, or its refusal, as `operator_command`; each effect as
    /// `workspace_changed`. The model is told on its next turn.
    func changeWorkspace(
        _ change: AgentHost.WorkspaceChange,
        command: String
    ) async throws -> AgentHost.WorkspaceChangeResult {
        do {
            let (next, effects) = try applying(change)
            accessLeases = next
            for effect in effects {
                await record(.workspace_changed, effect)
            }
            pendingWorkspaceNotes.append(contentsOf: effects)
            let state = try workspaceState()
            let outcome = effects.joined(separator: "; ")
                + (state.isDeferred ? " · takes effect when the run resumes or at the next turn" : "")
            await record(.operator_command, ":\(command) → \(outcome)")
            return .init(outcome: outcome, state: state)
        } catch {
            await record(.operator_command, ":\(command) → refused: \(error.localizedDescription)")
            throw error
        }
    }

    /// Takes `next` and records each lease it no longer holds: expired, or
    /// ended with its turn.
    func settleLeases(
        _ next: WorkspaceAccessLeases,
        run: String?
    ) async throws {
        let before = accessLeases
        accessLeases = next
        let kept = Set(next.values.map(\.id))
        for lease in before.values where !kept.contains(lease.id) {
            await record(.workspace_changed, "ended \(lease.summary)", run: run)
        }
        let previous = Set(before.values.map(\.id))
        for lease in next.values where !previous.contains(lease.id) {
            let origin = lease.origin == .request ? "model request" : "operator"
            await record(.workspace_changed, "granted \(lease.summary) (\(origin))", run: run)
        }
    }

    /// The model's next turn opens with this; admission clears the notes
    /// once the turn is committed.
    func workspaceNote() -> String? {
        let notes = pendingWorkspaceNotes
        guard !notes.isEmpty else { return nil }
        let directory = (try? workspaceState().directory).map { " Working directory: \($0)." } ?? ""
        return "[Workspace changed by the operator since your last turn: "
            + notes.joined(separator: "; ") + "." + directory
            + " Relative paths resolve against the working directory; reach other roots by absolute path.]"
    }

    func record(
        _ kind: Run.Event.State.Kind,
        _ summary: String,
        run: String? = nil
    ) async {
        _ = try? await log?.append(
            .state(.init(kind: kind, iteration: 0, summary: summary)),
            run: run
        )
    }

    private func applying(
        _ change: AgentHost.WorkspaceChange
    ) throws -> (WorkspaceAccessLeases, [String]) {
        let leases = accessLeases.expiring()
        let state = try workspaceState()

        switch change {
        case .add(let raw, let capabilities):
            let (item, isDirectory) = try Self.existingItem(resolve(raw, from: state.directory))
            try Self.requireAddable(item, isDirectory: isDirectory)
            // A file is granted alone; its directory becomes the root.
            let url = isDirectory ? item : item.deletingLastPathComponent()
            guard !state.roots.contains(where: { $0.path == url.path }) else {
                throw AgentHost.WorkspaceChangeError.alreadyRoot(url.path)
            }
            let lease = try WorkspaceAccessLease(
                request: WorkspaceAccessRequest(
                    rootID: Self.rootID(for: item, taken: Set(state.roots.map(\.id))),
                    rootPath: url.path,
                    label: item.lastPathComponent,
                    capabilities: (isDirectory ? capabilities : capabilities.intersection([.read, .edit, .write]))
                        .sorted { $0.rawValue < $1.rawValue },
                    reason: "added by the operator",
                    policyProfile: "workspace",
                    durationSeconds: nil,
                    files: isDirectory ? nil : [item.lastPathComponent]
                ),
                lifetime: .session,
                origin: .operator_command
            )
            let next = try leases.activating(
                lease,
                baseWorkspace: workspace,
                turnID: currentRunID
            )
            return (next, ["added \(lease.summary)"])

        case .remove(let raw):
            let resolved = resolve(raw, from: state.directory).path
            let matching = leases.values.filter {
                $0.id == raw || $0.request.rootID == raw || $0.request.rootPath == resolved
            }
            if !matching.isEmpty {
                let next = try matching.reduce(leases) { try $0.revoking($1.id) }
                return (next, matching.map { "removed \($0.summary)" })
            }
            let restrictions = leases.restrictions.filter {
                $0.id == raw || $0.id.hasPrefix(raw) && raw.count >= 8 || $0.pattern == raw
            }
            if !restrictions.isEmpty {
                let next = try restrictions.reduce(leases) { try $0.revoking($1.id) }
                return (next, restrictions.map { "removed deny \($0.pattern) on \($0.rootID)" })
            }
            if let root = state.roots.first(where: { $0.id == raw || $0.path == resolved }),
               root.source == .configured {
                throw AgentHost.WorkspaceChangeError.configuredRoot(root.id)
            }
            throw WorkspaceAccessLeasesError.lease_not_found(raw)

        case .deny(let pattern, let rootID):
            let root = rootID ?? state.roots.first(where: \.isDefault)?.id
            guard let root,
                  state.roots.contains(where: { $0.id == root }) else {
                throw WorkspaceAccessLeasesError.root_not_found(rootID ?? "default")
            }
            let restriction = try WorkspaceAccessRestriction(
                rootID: root,
                pattern: pattern,
                rule: .deny(
                    try Self.matcher(pattern),
                    reason: "denied by the operator"
                )
            )
            let next = try leases.restricting(
                restriction,
                baseWorkspace: workspace,
                turnID: currentRunID
            )
            return (next, ["denied \(pattern) on \(root)"])

        case .changeDirectory(let raw):
            let path = raw.map { resolve($0, from: state.directory).path }
            let next = try leases.changingDirectory(
                to: path,
                baseWorkspace: workspace,
                turnID: currentRunID
            )
            let directory = next.directory?.path
                ?? workspace.flatMap { base in
                    base.defaultRootIdentifier.flatMap { base.root(identifier: $0)?.rootPath }
                }
                ?? "configured root"
            return (next, ["directory \(directory)"])
        }
    }

    /// `~` expands; a relative path resolves against `directory`.
    private func resolve(
        _ raw: String,
        from directory: String
    ) -> URL {
        let expanded = (raw.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        return URL(
            fileURLWithPath: expanded,
            isDirectory: true,
            relativeTo: URL(fileURLWithPath: directory, isDirectory: true)
        )
        .standardizedFileURL
    }

    private static func existingDirectory(
        _ url: URL
    ) throws -> URL {
        let resolved = url.resolvingSymlinksInPath()
        guard (try? FileInspector(resolved).inspect().kind) == .directory else {
            throw AgentHost.WorkspaceChangeError.notDirectory(url.path)
        }
        return resolved
    }

    private static func existingItem(
        _ url: URL
    ) throws -> (URL, isDirectory: Bool) {
        let resolved = url.resolvingSymlinksInPath()
        switch try? FileInspector(resolved).inspect().kind {
        case .directory?: return (resolved, true)
        case .file?: return (resolved, false)
        default: throw AgentHost.WorkspaceChangeError.notFound(url.path)
        }
    }

    /// Not the filesystem root or the home directory itself, and nothing
    /// inside Agentic's own state. A single file may sit anywhere else.
    private static func requireAddable(
        _ url: URL,
        isDirectory: Bool = true
    ) throws {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard !isDirectory || (url.path != "/" && url.path != home.path) else {
            throw AgentHost.WorkspaceChangeError.tooBroad(url.path)
        }
        guard !url.pathComponents.contains(".agentic") else {
            throw AgentHost.WorkspaceChangeError.agenticState(url.path)
        }
    }

    private static func rootID(
        for url: URL,
        taken: Set<String>
    ) -> String {
        let base = url.lastPathComponent
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "_" }
            .reduce(into: "") { $0.append($1) }
        let name = base.isEmpty ? "root" : base
        var candidate = name
        var suffix = 2
        while taken.contains(candidate) {
            candidate = "\(name)_\(suffix)"
            suffix += 1
        }
        return candidate
    }

    /// A bare name is a path component anywhere under the root; anything
    /// with `/` or a wildcard is a path expression.
    static func matcher(
        _ pattern: String
    ) throws -> PathAccessMatcher {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw AgentHost.WorkspaceChangeError.emptyPattern
        }
        if trimmed.contains(where: { "/*?[{".contains($0) }) {
            return .expression(try PathExpressionParser.parse(trimmed))
        }
        return .component(trimmed)
    }
}

public extension AgentHost {
    enum WorkspaceChangeError: Error, Sendable, Hashable, LocalizedError {
        case notDirectory(String)
        case notFound(String)
        case tooBroad(String)
        case agenticState(String)
        case alreadyRoot(String)
        case configuredRoot(String)
        case emptyPattern

        public var errorDescription: String? {
            switch self {
            case .notDirectory(let path):
                return "\(path) is not an existing directory."
            case .notFound(let path):
                return "\(path) does not exist."
            case .tooBroad(let path):
                return "\(path) is too broad to add as a root."
            case .agenticState(let path):
                return "\(path) is inside Agentic's own state."
            case .alreadyRoot(let path):
                return "\(path) is already a root."
            case .configuredRoot(let id):
                return "'\(id)' is a configured root; change the workspace configuration to remove it."
            case .emptyPattern:
                return "A deny pattern is required."
            }
        }
    }
}
