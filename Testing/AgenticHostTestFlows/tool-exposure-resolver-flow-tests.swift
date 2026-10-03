import Agentic
import AgenticRuntime
import AgenticStandard
import TestFlows

extension AgenticRuntimeToolExposureFlowTesting {
    static func runResolverSemantics()
        async throws -> [TestDiagnostic]
    {
        let selectedTool = ToolIdentifier(
            rawValue: "resolver_selected"
        )
        let requiredTool = ToolIdentifier(
            rawValue: "resolver_required"
        )
        let optionalTool = ToolIdentifier(
            rawValue: "resolver_optional"
        )

        let skill = AgentSkill(
            identifier: "resolver-skill",
            name: "Resolver skill",
            summary: "Exercises required and optional tools.",
            body: "Resolver fixture.",
            metadata: .init(
                tools: .init(
                    required: [
                        .tool(
                            requiredTool
                        ),
                    ],
                    optional: [
                        .tool(
                            optionalTool
                        ),
                    ]
                )
            )
        )

        let discovery =
            AgentToolExposureResolver.resolve(
                selectedIdentifiers: [
                    selectedTool,
                    selectedTool,
                    Standard.Tools.FindTools.identifier,
                ],
                skills: [
                    skill,
                ],
                dynamicDiscovery: true
            )
        let discoveryIdentifiers =
            try resolverDiscoverableIdentifiers(
                discovery
            )

        try Expect.equal(
            discoveryIdentifiers,
            [
                selectedTool,
                requiredTool,
                Standard.Tools.FindTools.identifier,
            ],
            "resolver deduplicates explicit selection, overlays required skill tools, and appends find_tools when discovery is enabled"
        )

        let fixed =
            AgentToolExposureResolver.resolve(
                selectedIdentifiers: [
                    selectedTool,
                    Standard.Tools.FindTools.identifier,
                ],
                skills: [
                    skill,
                ],
                dynamicDiscovery: false
            )
        let fixedIdentifiers =
            try resolverExplicitIdentifiers(
                fixed
            )

        try Expect.equal(
            fixedIdentifiers,
            [
                selectedTool,
                requiredTool,
            ],
            "resolver strips find_tools when discovery is disabled and does not seed optional skill tools"
        )

        return [
            .field(
                "discovery",
                discoveryIdentifiers
                    .map(\.rawValue)
                    .joined(separator: ",")
            ),
            .field(
                "fixed",
                fixedIdentifiers
                    .map(\.rawValue)
                    .joined(separator: ",")
            ),
        ]
    }
}

private enum AgentToolExposureResolverFlowError:
    Error
{
    case expectedDiscoverable
    case expectedExplicit
}

private func resolverDiscoverableIdentifiers(
    _ policy: AgentToolExposurePolicy
) throws -> [ToolIdentifier] {
    guard case .discoverable(let identifiers) = policy else {
        throw AgentToolExposureResolverFlowError
            .expectedDiscoverable
    }

    return identifiers
}

private func resolverExplicitIdentifiers(
    _ policy: AgentToolExposurePolicy
) throws -> [ToolIdentifier] {
    guard case .explicit(let identifiers) = policy else {
        throw AgentToolExposureResolverFlowError
            .expectedExplicit
    }

    return identifiers
}
