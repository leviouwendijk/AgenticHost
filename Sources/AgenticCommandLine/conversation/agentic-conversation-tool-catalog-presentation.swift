import AgenticExecution
import AgenticInterfaces
import AgenticTools

enum AgenticConversationToolCatalogPresentation {
    static func collections(
        _ catalog: AgentToolCatalog
    ) -> [AgenticConversationToolCollectionPresentation] {
        catalog.collections.compactMap { collection in
            let tools = collection.toolIdentifiers.compactMap {
                identifier -> AgenticConversationToolPresentation? in
                guard let entry = catalog.entry(
                    identifiedBy: identifier
                ), entry.isModelFacing else {
                    return nil
                }

                return .init(
                    id: entry.identifier,
                    title: entry.title,
                    summary: entry.description,
                    selectionRole:
                        entry.identifier == FindToolsTool.identifier
                            ? .dynamicDiscovery
                            : .selectable
                )
            }

            guard !tools.isEmpty else {
                return nil
            }

            return .init(
                id: collection.identifier.rawValue,
                title: collection.title,
                tools: tools
            )
        }
    }

    static func defaultSelection(
        _ catalog: AgentToolCatalog
    ) -> AgenticConversationToolSelection {
        .init(
            identifiers: catalog.defaultExposedIdentifiers,
            dynamicDiscovery: true
        )
    }
}
