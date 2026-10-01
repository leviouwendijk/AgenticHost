/// Shared command-line configuration for Apple mutation approval integration flows.
struct AppleMutationApprovalConfiguration: Sendable, Hashable {
    var targetPath: String

    static func parse(
        _ arguments: [String]
    ) throws -> Self {
        var targetPath = "agentic-interface-hello.txt"
        var iterator = arguments.makeIterator()

        while let argument = iterator.next() {
            switch argument {
            case "--path":
                targetPath = try requireNext(
                    &iterator,
                    after: argument
                )

            default:
                if argument.hasPrefix("--path=") {
                    targetPath = String(
                        argument.dropFirst(
                            "--path=".count
                        )
                    )
                } else if !argument.hasPrefix("-") {
                    targetPath = argument
                } else {
                    throw AgenticInterfaceTestError.unknownArgument(
                        argument
                    )
                }
            }
        }

        return .init(
            targetPath: targetPath
        )
    }
}
