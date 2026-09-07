import AgenticRuntime
import Arguments

public struct AgenticRuntimeWorkspaceArguments:
    ArgumentGroup
{
    @Opt(
        "workspace",
        short: "w",
        default: ".",
        help: "Physical workspace root. Defaults to the current directory."
    )
    public var root: String

    @Opts(
        "workspace-path",
        take: .many,
        help: "Exact root-relative workspace path to allow. Repeatable."
    )
    public var exactPaths: [String]

    @Opts(
        "workspace-include",
        take: .many,
        help: "Root-relative workspace path expression to allow. Quote shell wildcard expressions. Repeatable."
    )
    public var includeExpressions: [String]

    @Opts(
        "workspace-exclude",
        take: .many,
        help: "Root-relative workspace path expression to deny even when otherwise selected. Quote shell wildcard expressions. Repeatable."
    )
    public var excludeExpressions: [String]

    public init() {}

    public func configuration() throws
        -> AgenticRuntimeWorkspaceConfiguration
    {
        try AgenticRuntimeWorkspaceConfiguration(
            path: root,
            exactPaths: exactPaths,
            includeExpressions: includeExpressions,
            excludeExpressions: excludeExpressions
        )
    }
}
