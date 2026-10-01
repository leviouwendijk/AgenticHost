import Foundation

struct AgenticInterfaceRunOptions: Sendable, Hashable {
    var verbose: Bool
    var raw: Bool

    init(
        verbose: Bool = false,
        raw: Bool = false
    ) {
        self.verbose = verbose
        self.raw = raw
    }

    static let standard = Self()

    static func extract(
        from arguments: [String]
    ) throws -> AgenticInterfaceRunOptionsExtraction {
        guard let executable = arguments.first else {
            return .init(
                options: .standard,
                arguments: []
            )
        }

        var options = AgenticInterfaceRunOptions.standard
        var filtered: [String] = [
            executable
        ]

        for argument in arguments.dropFirst() {
            switch argument {
            case "--verbose",
                 "-v":
                options.verbose = true

            case "--raw":
                options.raw = true

            default:
                filtered.append(
                    argument
                )
            }
        }

        return .init(
            options: options,
            arguments: filtered
        )
    }
}

struct AgenticInterfaceRunOptionsExtraction: Sendable, Hashable {
    var options: AgenticInterfaceRunOptions
    var arguments: [String]
}
