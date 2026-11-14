import Agentic
import Primitives
import Terminal

/// What a row of the Work tree stands for.
package enum AgenticWorkEntry: Hashable, Sendable {
    case newConversation
    /// The conversations of one Agent.
    case agentConversations(String)
    case conversation(String)
    /// A namespace level of Agent identifiers, e.g. `swift_lang`.
    case namespace(String)
    case agent(String)
}

/// The Work view as trees: conversations grouped by Agent, and installed
/// Agents grouped by their identifier's namespaces.
package enum AgenticWorkTree {
    package typealias Item = TerminalTreeListItem<AgenticWorkEntry>
    package typealias Node = Tree<Item>.Node

    package struct Conversation {
        package let id: String
        package let agent: String
        package let number: Int
        package let mark: String
        package let headline: String
        package let detail: String
        package let tone: TerminalStyle

        package init(
            id: String,
            agent: String,
            number: Int,
            mark: String,
            headline: String,
            detail: String,
            tone: TerminalStyle = .none
        ) {
            self.id = id
            self.agent = agent
            self.number = number
            self.mark = mark
            self.headline = headline
            self.detail = detail
            self.tone = tone
        }
    }

    package static func conversations(
        _ conversations: [Conversation]
    ) -> Tree<Item> {
        var agents: [String] = []
        var byAgent: [String: [Conversation]] = [:]
        for conversation in conversations {
            if byAgent[conversation.agent] == nil {
                agents.append(conversation.agent)
            }
            byAgent[conversation.agent, default: []].append(conversation)
        }
        let groups = agents.map { agent -> Node in
            let members = byAgent[agent] ?? []
            let running = members.filter { $0.mark == "●" }.count
            return Node(
                Item(
                    id: .agentConversations(agent),
                    title: agent,
                    detail: "\(members.count) \(members.count == 1 ? "session" : "sessions")"
                        + (running > 0 ? " · \(running) running" : "")
                ),
                children: members.map { conversation in
                    Node(Item(
                        id: .conversation(conversation.id),
                        title: "\(conversation.number). \(conversation.headline)",
                        detail: conversation.detail + " · " + String(conversation.id.prefix(8)),
                        mark: conversation.mark,
                        style: conversation.tone,
                        searchText: [
                            conversation.agent,
                            conversation.headline,
                            conversation.detail,
                            conversation.id,
                        ].joined(separator: " ")
                    ))
                }
            )
        }
        return Tree(roots: [
            Node(Item(
                id: .newConversation,
                title: "+ new conversation",
                style: TerminalStyle(.brightCyan),
                searchText: "new conversation"
            )),
        ] + groups)
    }

    /// `swift_lang.agents.implementer` reads as `swift_lang ▸ agents ▸
    /// implementer`; an identifier without namespaces is a top-level row.
    package static func agents(
        _ definitions: [AgentDefinition]
    ) -> Tree<Item> {
        var roots: [Node] = []
        for definition in definitions.sorted(by: { $0.identifier.rawValue < $1.identifier.rawValue }) {
            let identifier = definition.identifier.rawValue
            let segments = identifier.split(separator: ".").map(String.init)
            let leaf = Node(Item(
                id: .agent(identifier),
                title: segments.last ?? identifier,
                detail: definition.purpose,
                searchText: identifier + " " + definition.purpose
            ))
            insert(leaf, at: Array(segments.dropLast()), prefix: [], into: &roots)
        }
        return Tree(roots: roots)
    }

    private static func insert(
        _ leaf: Node,
        at path: [String],
        prefix: [String],
        into nodes: inout [Node]
    ) {
        guard let head = path.first else {
            nodes.append(leaf)
            return
        }
        let namespace = (prefix + [head]).joined(separator: ".")
        let index = nodes.firstIndex { $0.value.id == .namespace(namespace) } ?? {
            nodes.append(Node(Item(id: .namespace(namespace), title: head)))
            return nodes.count - 1
        }()
        insert(leaf, at: Array(path.dropFirst()), prefix: prefix + [head], into: &nodes[index].children)
    }
}
