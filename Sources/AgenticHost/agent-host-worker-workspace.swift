import Foundation
import Path
import Selection
import Workspace

/// Host-issued isolation for one worker. The proposed scope is validated
/// against the root's current grants before any child execution is admitted.
/// A file assignment receives no sibling-file read or write authority.
func agentHostWorkerWorkspace(
    context: WorkspaceContext,
    requestedScope: String
) throws -> Workspace {
    let requested = requestedScope.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !requested.isEmpty else {
        throw AgentHostWorkerScopeError.emptyScope
    }
    let authorized = try context.authorize(requested, capability: .write)
    let target = authorized.authorizedPath.absoluteURL.standardizedFileURL
    var directoryFlag: ObjCBool = false
    let exists = FileManager.default.fileExists(
        atPath: target.path,
        isDirectory: &directoryFlag
    )
    let isDirectory = exists && directoryFlag.boolValue
    let rootPath = isDirectory ? target : target.deletingLastPathComponent()
    guard FileManager.default.fileExists(atPath: rootPath.path) else {
        throw AgentHostWorkerScopeError.missingParent(rootPath.path)
    }
    var allowed = Set(WorkspaceCapability.allCases.filter { capability in
        (try? context.authorize(requested, capability: capability)) != nil
    })
    if isDirectory {
        // An exact or line-scoped grant cannot be promoted to subtree access.
        let unrestricted = Set(context.grants.filter { grant in
            guard grant.rootIdentifier == context.rootIdentifier,
                  grant.scope.pathSelection == nil else { return false }
            return context.status(of: grant.id) == .active
        }.flatMap(\.capabilities))
        allowed.formIntersection(unrestricted)
    }
    guard allowed.contains(.write) else {
        throw AgentHostWorkerScopeError.writeNotGranted(requested)
    }
    let identifier = PathAccessRootIdentifier(rawValue: "worker_scope")
    let root = PathAccessRoot(
        id: identifier,
        label: "Worker scope",
        scope: try PathAccessScope(
            root: rootPath,
            policy: .defaults.workspace
        ),
        isDefault: true
    )
    let grant: WorkspaceGrant
    if isDirectory {
        grant = try WorkspaceGrant(
            id: WorkspaceGrantIdentifier("worker-directory"),
            rootIdentifier: identifier,
            capabilities: allowed
        )
    } else {
        let filePermissions = allowed.intersection([.read, .write, .edit])
        grant = try WorkspaceGrant(
            id: WorkspaceGrantIdentifier("worker-file"),
            rootIdentifier: identifier,
            scope: .selection(PathSelection(
                [.literal(target.lastPathComponent)],
                terminalHint: .file
            )),
            capabilities: filePermissions
        )
    }
    return try Workspace(root: root, grants: [grant])
}

public enum AgentHostWorkerScopeError: Error, Sendable {
    case emptyScope
    case missingParent(String)
    case writeNotGranted(String)
    case coordinatedExecutionRequired
    case workspaceNotConfigured
    case childWorkspaceExpansionUnsupported
}
