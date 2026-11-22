import Agentic
import AgenticRuntime
import AgenticStandard
import TestFlows

extension AgenticRuntimeToolExposureFlowTesting {
    /// Rewritten onto the settled capability-state model. The old resolver
    /// (explicit/required/optional policy object) is gone; the equivalent semantic
    /// is capability construction followed by `reveal`, which moves identifiers
    /// from `available` into `visible` while preserving `visible ⊆ available ⊆ installed`.
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

        let installed = AgentCapabilitySet(
            tools: [
                selectedTool,
                requiredTool,
                optionalTool,
                Capabilities.Tools.Search.identifier,
            ]
        )
        let available = installed

        let discoveryState = AgentCapabilityState(
            installed: installed,
            available: available,
            visible: AgentCapabilitySet.none
        )
        await discoveryState.reveal(
            AgentCapabilitySet(
                tools: [
                    selectedTool,
                    requiredTool,
                    Capabilities.Tools.Search.identifier,
                ]
            )
        )
        let discoveryVisible = await discoveryState.snapshot().visible.tools

        let fixedState = AgentCapabilityState(
            installed: installed,
            available: available,
            visible: AgentCapabilitySet.none
        )
        await fixedState.reveal(
            AgentCapabilitySet(
                tools: [
                    selectedTool,
                    requiredTool,
                ]
            )
        )
        let fixedVisible = await fixedState.snapshot().visible.tools

        try Expect.equal(
            discoveryVisible,
            [
                selectedTool,
                requiredTool,
                Capabilities.Tools.Search.identifier,
            ],
            "discovery reveal deduplicates selection, overlays required tools, and appends capabilities_tool_search"
        )
        try Expect.equal(
            fixedVisible,
            [
                selectedTool,
                requiredTool,
            ],
            "fixed reveal strips capabilities_tool_search and does not seed optional tools"
        )

        return [
            .field(
                "discovery",
                discoveryVisible
                    .map(\.rawValue)
                    .joined(separator: ",")
            ),
            .field(
                "fixed",
                fixedVisible
                    .map(\.rawValue)
                    .joined(separator: ",")
            ),
        ]
    }
}
