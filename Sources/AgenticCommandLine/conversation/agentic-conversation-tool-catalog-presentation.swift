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
                        tool.id == Standard.Tools.FindTools.definition.identifier
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
        _ catalog: AgentHost.Capabilities.ToolCatalog
    ) -> AgenticConversationToolSelection {
        .init(
            identifiers: catalog.defaultExposedIdentifiers,
            dynamicDiscovery: true
        )
    }
}
