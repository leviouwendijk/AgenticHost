import Agentic
import AgenticExecution
import AgenticWorkspace
import Primitives
import Schema
import SchemaMacros

actor AdapterFlowScratchpadStore {
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

struct AdapterFlowScratchpadReadTool: AgentTool {
    typealias Input = AdapterFlowScratchpadReadInput
    typealias Output = AdapterFlowScratchpadReadOutput

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

    let store: AdapterFlowScratchpadStore

    func call(
        _ input: Input,
        context _: AgentToolExecutionContext
    ) async throws -> Output {
        _ = input

        let values = await store.all()

        return AdapterFlowScratchpadReadOutput(
            values: values,
            count: values.count
        )
    }
}

struct AdapterFlowScratchpadTool: AgentTool {
    typealias Input = AdapterFlowScratchpadPutInput
    typealias Output = AdapterFlowScratchpadPutOutput

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

    let store: AdapterFlowScratchpadStore

    func call(
        _ input: Input,
        context _: AgentToolExecutionContext
    ) async throws -> Output {
        let count = await store.append(
            input.text
        )

        return AdapterFlowScratchpadPutOutput(
            text: input.text,
            count: count
        )
    }
}

@JSONSchema
struct AdapterFlowScratchpadReadInput: Sendable, Codable, Hashable {
    init() {}
}

struct AdapterFlowScratchpadReadOutput: Sendable, Codable, Hashable {
    var values: [String]
    var count: Int
}

@JSONSchema
struct AdapterFlowScratchpadPutInput: Sendable, Codable, Hashable {
    var text: String
}

struct AdapterFlowScratchpadPutOutput: Sendable, Codable, Hashable {
    var text: String
    var count: Int
}
