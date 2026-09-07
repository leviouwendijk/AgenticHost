import Agentic
import AgenticExecution
import AgenticRuntime
import AgenticTools
import TestFlows

extension AgenticRuntimeToolExposureFlowTesting {
    static func runResolverSemantics()
        async throws -> [TestFlowDiagnostic]
    {
        let defaultTool = AgentToolIdentifier(
            rawValue: "resolver_default"
        )
        let selectedTool = AgentToolIdentifier(
            rawValue: "resolver_selected"
        )
        let requiredTool = AgentToolIdentifier(
            rawValue: "resolver_required"
        )
        let optionalTool = AgentToolIdentifier(
            rawValue: "resolver_optional"
        )
        let hostOnlyTool = AgentToolIdentifier(
            rawValue: "resolver_host_only"
        )
        let staleTool = AgentToolIdentifier(
            rawValue: "resolver_stale"
        )

        let defaultsCollection =
            AgentToolCollectionIdentifier(
                rawValue: "resolver.defaults"
            )
        let selectableCollection =
            AgentToolCollectionIdentifier(
                rawValue: "resolver.selectable"
            )
        let intrinsicCollection =
            AgentToolCollectionMetadata
                .intrinsics
                .identifier

        let catalog = AgentToolCatalog(
            collections: [
                .init(
                    identifier: defaultsCollection,
                    title: "Defaults",
                    defaultExposure: .included,
                    toolIdentifiers: [
                        defaultTool,
                        hostOnlyTool,
                    ]
                ),
                .init(
                    identifier: selectableCollection,
                    title: "Selectable",
                    defaultExposure: .excluded,
                    toolIdentifiers: [
                        selectedTool,
                        requiredTool,
                        optionalTool,
                    ]
                ),
                .init(
                    identifier: intrinsicCollection,
                    title: "Intrinsics",
                    defaultExposure: .excluded,
                    toolIdentifiers: [
                        FindToolsTool.identifier,
                    ]
                ),
            ],
            entries: [
                resolverCatalogEntry(
                    defaultTool,
                    collection: defaultsCollection,
                    defaultExposure: .included
                ),
                resolverCatalogEntry(
                    hostOnlyTool,
                    collection: defaultsCollection,
                    defaultExposure: .included,
                    isModelFacing: false
                ),
                resolverCatalogEntry(
                    selectedTool,
                    collection: selectableCollection,
                    defaultExposure: .excluded
                ),
                resolverCatalogEntry(
                    requiredTool,
                    collection: selectableCollection,
                    defaultExposure: .excluded
                ),
                resolverCatalogEntry(
                    optionalTool,
                    collection: selectableCollection,
                    defaultExposure: .excluded
                ),
                resolverCatalogEntry(
                    FindToolsTool.identifier,
                    collection: intrinsicCollection,
                    defaultExposure: .excluded,
                    origin: .intrinsic
                ),
            ]
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
                base: .catalogDefaults,
                skills: [
                    skill,
                ],
                dynamicDiscovery: true,
                catalog: catalog
            )
        let discoveryIdentifiers =
            try resolverDiscoverableIdentifiers(
                discovery
            )

        try Expect.equal(
            discoveryIdentifiers,
            [
                defaultTool,
                requiredTool,
                FindToolsTool.identifier,
            ],
            "discovery exposes catalog defaults plus required skill tools and find_tools"
        )

        let skillSeeded =
            AgentToolExposureResolver.resolve(
                base: .none,
                skills: [
                    skill,
                ],
                dynamicDiscovery: true,
                catalog: catalog
            )
        let skillSeededIdentifiers =
            try resolverDiscoverableIdentifiers(
                skillSeeded
            )

        try Expect.equal(
            skillSeededIdentifiers,
            [
                requiredTool,
                FindToolsTool.identifier,
            ],
            "skill-seeded exposure includes required tools but not optional tools"
        )

        let selectionAndSkillWithoutDiscovery =
            AgentToolExposureResolver.resolve(
                base: .selected(
                    [
                        selectedTool,
                        FindToolsTool.identifier,
                        hostOnlyTool,
                        staleTool,
                    ]
                ),
                skills: [
                    skill,
                ],
                dynamicDiscovery: false,
                catalog: catalog
            )
        let fixedIdentifiers =
            try resolverExplicitIdentifiers(
                selectionAndSkillWithoutDiscovery
            )

        try Expect.equal(
            fixedIdentifiers,
            [
                selectedTool,
                requiredTool,
            ],
            "fixed selection rejects stale and host-only tools, strips find_tools, and overlays required skill tools"
        )

        let selectionWithoutDiscovery =
            AgentToolExposureResolver.resolve(
                base: .selected(
                    [
                        selectedTool,
                    ]
                ),
                dynamicDiscovery: false,
                catalog: catalog
            )

        try Expect.equal(
            try resolverExplicitIdentifiers(
                selectionWithoutDiscovery
            ),
            [
                selectedTool,
            ],
            "selection-only discovery-off posture remains explicit"
        )

        let all =
            AgentToolExposureResolver.resolve(
                base: .all,
                skills: [
                    skill,
                ],
                dynamicDiscovery: false,
                catalog: catalog
            )

        guard case .all = all else {
            throw AgentToolExposureResolverFlowError
                .expectedAll
        }

        return [
            .field(
                "discovery",
                discoveryIdentifiers
                    .map(\.rawValue)
                    .joined(separator: ",")
            ),
            .field(
                "skill_seeded",
                skillSeededIdentifiers
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
    case expectedAll
}

private func resolverDiscoverableIdentifiers(
    _ policy: AgentToolExposurePolicy
) throws -> [AgentToolIdentifier] {
    guard case .discoverable(let identifiers) = policy else {
        throw AgentToolExposureResolverFlowError
            .expectedDiscoverable
    }

    return identifiers
}

private func resolverExplicitIdentifiers(
    _ policy: AgentToolExposurePolicy
) throws -> [AgentToolIdentifier] {
    guard case .explicit(let identifiers) = policy else {
        throw AgentToolExposureResolverFlowError
            .expectedExplicit
    }

    return identifiers
}

private func resolverCatalogEntry(
    _ identifier: AgentToolIdentifier,
    collection: AgentToolCollectionIdentifier,
    defaultExposure: AgentToolDefaultExposure,
    isModelFacing: Bool = true,
    origin: AgentToolOrigin = .declared
) -> AgentToolCatalogEntry {
    .init(
        identifier: identifier,
        title: identifier.rawValue,
        description: "Tool exposure resolver fixture.",
        risk: .observe,
        isModelFacing: isModelFacing,
        workingLocation: .fixed,
        origin: origin,
        collectionIdentifier: collection,
        defaultExposure: defaultExposure
    )
}
