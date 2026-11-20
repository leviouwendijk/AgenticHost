import Agentic
import Workspace
import Primitives
import Schema
import Macros

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

struct GatewayFlowScratchpadReadTool: Tool {
    typealias Input = GatewayFlowScratchpadReadInput
    typealias Output = GatewayFlowScratchpadReadOutput

    static let definition = ToolDefinition(
        identifier: .init(rawValue: "adapter_scratchpad_read"),
        purpose: "Reads notes from an in-memory test scratchpad.",
        risk: .observe
    )

    static var identifier: ToolIdentifier {
        definition.identifier
    }

    let store: GatewayFlowScratchpadStore

    func call(
        _ input: Input,
        in _: ToolContext
    ) async throws -> Output {
        _ = input

        let values = await store.all()

        return GatewayFlowScratchpadReadOutput(
            values: values,
            count: values.count
        )
    }
}

struct GatewayFlowScratchpadTool: Tool {
    typealias Input = GatewayFlowScratchpadPutInput
    typealias Output = GatewayFlowScratchpadPutOutput

    static let definition = ToolDefinition(
        identifier: .init(rawValue: "adapter_scratchpad_put"),
        purpose: "Stores a note in an in-memory test scratchpad.",
        risk: .boundedmutate
    )

    static var identifier: ToolIdentifier {
        definition.identifier
    }

    let store: GatewayFlowScratchpadStore

    func call(
        _ input: Input,
        in _: ToolContext
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
struct GatewayFlowScratchpadReadInput: HashableSource {
    init() {}
}

@JSONSchema
struct GatewayFlowScratchpadReadOutput: HashableResult {
    var values: [String]
    var count: Int
}

@JSONSchema
struct GatewayFlowScratchpadPutInput: HashableSource {
    var text: String
}

@JSONSchema
struct GatewayFlowScratchpadPutOutput: HashableResult {
    var text: String
    var count: Int
}
