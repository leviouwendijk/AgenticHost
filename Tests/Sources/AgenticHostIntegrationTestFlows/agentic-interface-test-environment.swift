import Foundation
import TestFlows

struct AgenticInterfaceTestRunContext: Sendable {
    let testID: String
    let arguments: [String]
    let files: TestFlowFiles
    let interaction: any TestFlowInteraction
    let options: AgenticInterfaceRunOptions

    func workspaceRoot() throws -> URL {
        try files.work.ensureDir()
    }

    @discardableResult
    func writeWorkspaceFile(
        _ content: String,
        to path: String
    ) throws -> URL {
        try files.work.write(
            content,
            to: path
        )
    }

    func readWorkspaceFile(
        _ path: String
    ) throws -> String {
        try files.work.read(
            path
        )
    }
}

enum AgenticInterfaceTestEnvironment {
    @TaskLocal
    static var current: AgenticInterfaceTestRunContext?

    static func run(
        test: AgenticInterfaceTestCase,
        arguments: [String],
        interaction: any TestFlowInteraction,
        options: AgenticInterfaceRunOptions = .standard
    ) async throws {
        let files = TestFlowFiles(
            flowName: test.id
        )

        try files.prepare()

        let context = AgenticInterfaceTestRunContext(
            testID: test.id,
            arguments: arguments,
            files: files,
            interaction: interaction,
            options: options
        )

        try await $current.withValue(
            context
        ) {
            try await test.run(
                arguments
            )
        }
    }

    static func require() throws -> AgenticInterfaceTestRunContext {
        guard let current else {
            throw AgenticInterfaceTestEnvironmentError.missingContext
        }

        return current
    }

    static var interaction: any TestFlowInteraction {
        if let current {
            return current.interaction
        }

        return TerminalTestFlowInteraction()
    }

    static var options: AgenticInterfaceRunOptions {
        current?.options ?? .standard
    }

    static func workspaceRoot() throws -> URL {
        try require().workspaceRoot()
    }

    @discardableResult
    static func writeWorkspaceFile(
        _ content: String,
        to path: String
    ) throws -> URL {
        try require().writeWorkspaceFile(
            content,
            to: path
        )
    }

    static func readWorkspaceFile(
        _ path: String
    ) throws -> String {
        try require().readWorkspaceFile(
            path
        )
    }
}

enum AgenticInterfaceTestEnvironmentError: Error, Sendable, LocalizedError {
    case missingContext

    var errorDescription: String? {
        switch self {
        case .missingContext:
            return "Agentic interface test environment was not installed for this run."
        }
    }
}
