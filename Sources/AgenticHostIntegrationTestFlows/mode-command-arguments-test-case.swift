import AgenticCommandLine
import AgenticHost
import Agentic
import AgenticInterfaces
import Foundation
import TestFlows

enum ModeCommandArgumentsTestCase {
    static func makeDefaultsToCoder() -> AgenticInterfaceTestCase {
        .init(
            id: "run-command-arguments-defaults-to-coder",
            summary: "Parse run command argv and default the mode to coder."
        ) { _ in
            try await runDefaultsToCoder()
        }
    }

    static func makeSelectsMode() -> AgenticInterfaceTestCase {
        .init(
            id: "run-command-arguments-selects-mode",
            summary: "Parse run command argv with an explicit mode."
        ) { _ in
            try await runSelectsMode()
        }
    }

    static func makeCapturesSystem() -> AgenticInterfaceTestCase {
        .init(
            id: "run-command-arguments-captures-system",
            summary: "Parse run command argv with a system instruction."
        ) { _ in
            try await runCapturesSystem()
        }
    }

    static func makeCapturesMetadata() -> AgenticInterfaceTestCase {
        .init(
            id: "run-command-arguments-captures-metadata",
            summary: "Parse repeated run command metadata entries."
        ) { _ in
            try await runCapturesMetadata()
        }
    }

    static func makeRejectsMissingPrompt() -> AgenticInterfaceTestCase {
        .init(
            id: "run-command-arguments-rejects-missing-prompt",
            summary: "Reject run command argv without a prompt."
        ) { _ in
            try await runRejectsMissingPrompt()
        }
    }

    static func makeRejectsUnknownMode() -> AgenticInterfaceTestCase {
        .init(
            id: "run-command-arguments-rejects-unknown-mode",
            summary: "Reject run command argv with an unknown mode."
        ) { _ in
            try await runRejectsUnknownMode()
        }
    }

    static func makeCodableRoundtrip() -> AgenticInterfaceTestCase {
        .init(
            id: "run-command-arguments-codable-roundtrip",
            summary: "Round-trip parsed run command arguments through Codable."
        ) { _ in
            try await runCodableRoundtrip()
        }
    }
}

private extension ModeCommandArgumentsTestCase {
    static func parser() throws -> AgenticRunCommandArgumentParser {
        try .standard()
    }

    static func runDefaultsToCoder() async throws {
        let invocation = try parser().parse(
            [
                "Patch the formatter."
            ]
        )

        try Expect.equal(
            invocation.arguments.modeID,
            .coder,
            "run command default mode"
        )

        try Expect.equal(
            invocation.command.modeID,
            .coder,
            "run command default command mode"
        )

        try Expect.equal(
            invocation.command.prompt,
            "Patch the formatter.",
            "run command prompt"
        )

        print(
            "mode \(invocation.command.modeID.rawValue)"
        )

        print(
            "run-command-arguments-defaults-to-coder ok"
        )
    }

    static func runSelectsMode() async throws {
        let invocation = try parser().parse(
            [
                "run",
                "--mode",
                "research",
                "Collect evidence."
            ]
        )

        try Expect.equal(
            invocation.command.modeID,
            .research,
            "run command selected mode"
        )

        try Expect.equal(
            invocation.command.prompt,
            "Collect evidence.",
            "run command selected mode prompt"
        )

        print(
            "mode \(invocation.command.modeID.rawValue)"
        )

        print(
            "run-command-arguments-selects-mode ok"
        )
    }

    static func runCapturesSystem() async throws {
        let invocation = try parser().parse(
            [
                "--system",
                "Answer tersely.",
                "Summarize the patch."
            ]
        )

        try Expect.equal(
            invocation.command.system,
            "Answer tersely.",
            "run command system"
        )

        try Expect.equal(
            invocation.command.prompt,
            "Summarize the patch.",
            "run command system prompt"
        )

        print(
            "system \(invocation.command.system ?? "")"
        )

        print(
            "run-command-arguments-captures-system ok"
        )
    }

    static func runCapturesMetadata() async throws {
        let invocation = try parser().parse(
            [
                "agentic",
                "run",
                "--metadata",
                "source=aginttest",
                "--metadata",
                "test_case=run-command-arguments",
                "Patch the formatter."
            ]
        )

        try Expect.equal(
            invocation.command.metadata["source"],
            "aginttest",
            "run command metadata source"
        )

        try Expect.equal(
            invocation.command.metadata["test_case"],
            "run-command-arguments",
            "run command metadata test case"
        )

        print(
            "metadata \(invocation.command.metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))"
        )

        print(
            "run-command-arguments-captures-metadata ok"
        )
    }

    static func runRejectsMissingPrompt() async throws {
        do {
            _ = try parser().parse(
                [
                    "--mode",
                    "coder"
                ]
            )

            throw ModeCommandArgumentsTestError.expectedMissingPrompt
        } catch AgenticRunCommandArgumentParserError.missingPrompt {
            print(
                "missing prompt rejected"
            )
        }

        print(
            "run-command-arguments-rejects-missing-prompt ok"
        )
    }

    static func runRejectsUnknownMode() async throws {
        do {
            _ = try parser().parse(
                [
                    "--mode",
                    "does_not_exist",
                    "Patch the formatter."
                ]
            )

            throw ModeCommandArgumentsTestError.expectedUnknownMode
        } catch AgenticRunCommandArgumentParserError.unknownMode(let mode, let available) {
            try Expect.equal(
                mode,
                "does_not_exist",
                "unknown mode value"
            )

            try Expect.true(
                available.contains(
                    "coder"
                ),
                "unknown mode available includes coder"
            )

            print(
                "unknown mode \(mode)"
            )
        }

        print(
            "run-command-arguments-rejects-unknown-mode ok"
        )
    }

    static func runCodableRoundtrip() async throws {
        let arguments = AgenticRunCommandArguments(
            modeID: .review,
            prompt: "Review the patch.",
            system: "Be strict.",
            metadata: [
                "source": "roundtrip"
            ]
        )

        let data = try JSONEncoder().encode(
            arguments
        )
        let decoded = try JSONDecoder().decode(
            AgenticRunCommandArguments.self,
            from: data
        )

        try Expect.equal(
            decoded,
            arguments,
            "run command arguments codable roundtrip"
        )

        print(
            "mode \(decoded.modeID.rawValue)"
        )

        print(
            "run-command-arguments-codable-roundtrip ok"
        )
    }
}

private enum ModeCommandArgumentsTestError: Error, Sendable, LocalizedError {
    case expectedMissingPrompt
    case expectedUnknownMode

    var errorDescription: String? {
        switch self {
        case .expectedMissingPrompt:
            return "Expected missing prompt rejection."

        case .expectedUnknownMode:
            return "Expected unknown mode rejection."
        }
    }
}
