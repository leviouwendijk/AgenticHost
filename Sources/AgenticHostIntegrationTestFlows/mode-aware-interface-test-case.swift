import AgenticExecution
import AgenticHost
import AgenticRuntime
import Agentic
import AgenticInterfaces
import Foundation
import TestFlows

enum ModeAwareInterfaceTestCase {
    static func make() -> AgenticInterfaceTestCase {
        .init(
            id: "mode-aware-interface",
            summary: "Build a mode-aware run command model and request context."
        ) { _ in
            try await run()
        }
    }

    static func run() async throws {
        let fixture = try makeFixture()
        let presenter = AgenticInterfaceRuntimeFactory.presenter()

        try await presenter.present(
            .modeRunStarted(
                fixture.preparation.command
            )
        )

        print(
            fixture.preparation.screen.renderedHeader()
        )

        try await checksCommandModel(
            fixture
        )
        try await checksModeHeader(
            fixture
        )
        try await checksToolPreflightRendering(
            fixture
        )
        try await checksScriptedApprovalDecision(
            expected: .approved
        )
        try await checksScriptedApprovalDecision(
            expected: .denied
        )
        try await checksRequestContext(
            fixture
        )

        print(
            "mode-aware-interface ok"
        )
    }
}

private extension ModeAwareInterfaceTestCase {
    struct Fixture: Sendable {
        var preparation: ModeRunPreparation
    }

    static func makeFixture() throws -> Fixture {
        let sourceTools = try Agentic.tool.registry(
            toolSets: [
                CoreToolSet()
            ]
        )

        let skills = try Agentic.skill.registry(
            skills: [
                AgentSkill(
                    identifier: "safe-file-editing",
                    name: "Safe file editing",
                    summary: "Read before writing.",
                    body: "Read before writing. Prefer targeted edits and report concrete changed paths."
                )
            ]
        )

        let preparation = try ModeRunFactory
            .standard()
            .make(
                modeID: .coder,
                prompt: "Patch the formatter.",
                system: "Answer with a concrete implementation plan.",
                tools: sourceTools,
                skills: skills,
                metadata: [
                    "test_case": "mode-aware-interface"
                ]
            )

        return .init(
            preparation: preparation
        )
    }

    static func checksCommandModel(
        _ fixture: Fixture
    ) async throws {
        let command = fixture.preparation.command

        try Expect.equal(
            command.modeID,
            .coder,
            "interface mode command model id"
        )

        try Expect.equal(
            command.routePurpose,
            .coder,
            "interface mode command model route purpose"
        )

        try Expect.equal(
            command.exposedToolNames,
            [
                "mutate_files",
                "read_file",
                "scan_paths"
            ],
            "interface mode command model tools"
        )
    }

    static func checksModeHeader(
        _ fixture: Fixture
    ) async throws {
        let rendered = fixture.preparation.screen.renderedHeader()

        try Expect.true(
            rendered.contains("mode        coder"),
            "interface mode header contains mode id"
        )

        try Expect.true(
            rendered.contains("purpose     coder"),
            "interface mode header contains route purpose"
        )

        try Expect.true(
            rendered.contains("approval    review_bounded_mutation"),
            "interface mode header contains approval strictness"
        )
    }

    static func checksToolPreflightRendering(
        _ fixture: Fixture
    ) async throws {
        let preflight = ToolPreflight(
            toolName: "mutate_files",
            risk: .boundedmutate,
            workspaceRoot: nil,
            targetPaths: [
                "Sources/Foo.swift"
            ],
            summary: "Apply 1 file mutation.",
            estimatedWriteCount: 1,
            estimatedByteCount: 42,
            sideEffects: [
                "bounded mutation"
            ],
            rootIDs: [
                "project"
            ],
            capabilitiesRequired: [
                .write
            ],
            estimatedWriteBytes: 42,
            estimatedChangedLineCount: 1,
            isPreview: true,
            policyChecks: [
                "bounded_mutation"
            ],
            warnings: [],
            diffPreview: nil
        )
        let rendered = fixture.preparation.screen.renderedPreflight(
            preflight
        )

        try Expect.true(
            rendered.contains("tool        mutate_files"),
            "interface preflight render includes tool"
        )

        try Expect.true(
            rendered.contains("risk        boundedmutate"),
            "interface preflight render includes risk"
        )

        try Expect.true(
            rendered.contains("targets     Sources/Foo.swift"),
            "interface preflight render includes target"
        )
    }

    static func checksScriptedApprovalDecision(
        expected: ApprovalDecision
    ) async throws {
        let handler = ScriptedInterfaceApprovalHandler(
            decision: expected
        )
        let decision = try await handler.decide(
            on: ToolPreflight(
                toolName: "mutate_files",
                risk: .boundedmutate,
                workspaceRoot: nil,
                targetPaths: [],
                summary: "Apply mutation.",
                estimatedWriteCount: 1,
                estimatedByteCount: 1,
                sideEffects: [],
                rootIDs: [],
                capabilitiesRequired: [],
                estimatedWriteBytes: 1,
                estimatedChangedLineCount: nil,
                isPreview: true,
                policyChecks: [],
                warnings: [],
                diffPreview: nil
            ),
            requirement: .needs_human_review
        )

        try Expect.equal(
            decision,
            expected,
            "scripted approval handler decision"
        )
    }

    static func checksRequestContext(
        _ fixture: Fixture
    ) async throws {
        let request = fixture.preparation.request

        try Expect.equal(
            request.metadata["mode_id"],
            "coder",
            "interface mode request metadata"
        )

        try Expect.true(
            request.messages.contains { message in
                message.role == .system
                    && message.content.text.contains("Skill ID: safe-file-editing")
            },
            "interface mode request includes skill context"
        )

        try Expect.equal(
            request.tools.map(\.name).sorted(),
            [
                "mutate_files",
                "read_file",
                "scan_paths"
            ],
            "interface mode request uses filtered tools"
        )
    }
}

private struct ScriptedInterfaceApprovalHandler: ToolApprovalHandler {
    var decision: ApprovalDecision

    func decide(
        on preflight: ToolPreflight,
        requirement: ApprovalRequirement
    ) async throws -> ApprovalDecision {
        if requirement.isDenied {
            return .denied
        }

        if !requirement.requiresHumanReview {
            return .approved
        }

        _ = preflight
        return decision
    }
}
