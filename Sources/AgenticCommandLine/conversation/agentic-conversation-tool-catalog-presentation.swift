import AgenticHost
import AgenticInterfaces
import AgenticStandard

enum AgenticConversationToolCatalogPresentation {
    static func collections(
        _ catalog: AgentHost.Capabilities.ToolCatalog
    ) -> [AgenticConversationToolCollectionPresentation] {
        catalog.collections.compactMap { collection in
            let tools = collection.tools.map { tool in
                AgenticConversationToolPresentation(
                    id: tool.id,
                    title: tool.title,
                    summary: tool.summary,
                    selectionRole:
                        tool.id == Standard.Tools.FindCapabilities.identifier
                            ? .dynamicDiscovery
                            : .selectable
                )
            }

            guard !tools.isEmpty else {
                return nil
            }

            return .init(
                id: collection.id,
                title: collection.title,
                tools: tools
            )
        }
    }

    static func defaultSelection(
        _ catalog: AgentHost.Capabilities.ToolCatalog,
        execution: AgentHost.Session.Execution = .init()
    ) -> AgenticConversationToolSelection {
        let findCapabilities = Standard.Tools.FindCapabilities.identifier
        let available =
            execution.availableCapabilities?.tools
            ?? catalog.modelFacingIdentifiers
        let visible =
            execution.visibleCapabilities?.tools
            ?? catalog.defaultExposedIdentifiers

        return .init(
            availableIdentifiers: available.filter {
                $0 != findCapabilities
            },
            visibleIdentifiers: visible.filter {
                $0 != findCapabilities
            },
            dynamicDiscovery: true
        )
    }
}
