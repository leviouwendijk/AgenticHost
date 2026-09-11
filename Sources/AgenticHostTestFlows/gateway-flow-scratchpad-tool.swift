import Agentic
import AgenticExecution
import AgenticWorkspace
import Primitives
import Schema
import SchemaMacros

actor GatewayFlowScratchpadStore {
    private var values: [String] = []

    func append(
        _ value: String
    ) -> Int {
        values.append(
            value
        )

        return values.count
    }

    func all() -> [String] {
        values
    }
}

struct GatewayFlowScratchpadReadTool: AgentTool {
    typealias Input = GatewayFlowScratchpadReadInput
    typealias Output = GatewayFlowScratchpadReadOutput

    static let identifier: AgentToolIdentifier = .init(
        "adapter_scratchpad_read"
    )
    static let description = "Reads notes from an in-memory test scratchpad."
    static let risk: ActionRisk = .observe

    var identifier: AgentToolIdentifier {
        Self.identifier
    }

    var description: String {
        Self.description
    }

    var risk: ActionRisk {
        Self.risk
    }

    let store: GatewayFlowScratchpadStore

    func call(
        _ input: Input,
        context _: AgentToolExecutionContext
    ) async throws -> Output {
        _ = input

        let values = await store.all()

        return GatewayFlowScratchpadReadOutput(
            values: values,
            count: values.count
        )
    }
}

struct GatewayFlowScratchpadTool: AgentTool {
    typealias Input = GatewayFlowScratchpadPutInput
    typealias Output = GatewayFlowScratchpadPutOutput

    static let identifier: AgentToolIdentifier = .init(
        "adapter_scratchpad_put"
    )
    static let description = "Stores a note in an in-memory test scratchpad."
    static let risk: ActionRisk = .boundedmutate

    var identifier: AgentToolIdentifier {
        Self.identifier
    }

    var description: String {
        Self.description
    }

    var risk: ActionRisk {
        Self.risk
    }

    let store: GatewayFlowScratchpadStore

    func call(
        _ input: Input,
        context _: AgentToolExecutionContext
    ) async throws -> Output {
        let count = await store.append(
            input.text
        )

        return GatewayFlowScratchpadPutOutput(
            text: input.text,
            count: count
        )
    }
}

@JSONSchema
struct GatewayFlowScratchpadReadInput: Sendable, Codable, Hashable {
    init() {}
}

struct GatewayFlowScratchpadReadOutput: Sendable, Codable, Hashable {
    var values: [String]
    var count: Int
}

@JSONSchema
struct GatewayFlowScratchpadPutInput: Sendable, Codable, Hashable {
    var text: String
}

struct GatewayFlowScratchpadPutOutput: Sendable, Codable, Hashable {
    var text: String
    var count: Int
}
