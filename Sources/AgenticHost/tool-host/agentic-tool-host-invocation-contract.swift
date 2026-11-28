import Agentic
import Primitives
import Schema
import Macros

/// Canonical model-facing Agentic tool-call payload.
@JSONSchema
public struct AgenticToolHostCall:
    Sendable,
    Codable,
    Hashable
{
    /// Stable identifier for this tool call within the invocation or plan.
    public let id: String

    /// Exact identifier of one currently registered model-facing tool.
    public let name: String

    /// Input payload conforming to the selected tool's semantic input schema.
    public let input: JSONValue

    public init(
        id: String,
        name: String,
        input: JSONValue
    ) {
        self.id = id
        self.name = name
        self.input = input
    }

    public var agentToolCall: FunctionCall {
        .init(
            id: id,
            name: name,
            input: input
        )
    }
}

/// Execution metadata that remains outside semantic tool input.
///
/// The host consumes Agentic's canonical `ToolInvocation.Target` and
/// `WorkspaceTarget` directly rather than owning a parallel execution DTO or
/// JSON-decode bridge. `execution.workspace.subpath` is ordinary optional
/// invocation metadata for every model-facing tool; Workspace decides whether a
/// requested target is permitted. There is no per-tool targetable contract to
/// advertise here, so the host never encodes one.
///
/// Schema authority: the host's flattened wire grammar is `{ name, input,
/// execution }` (or `FunctionCall { id, tool, input }`), which intentionally
/// differs from Agentic's `{ arguments, execution? }` model-facing envelope. The
/// host therefore derives its `input` property from Agentic's authoritative
/// `semanticInputSchema`, and its `execution` property from Agentic's canonical
/// `ToolInvocation.Target.jsonschema`. No model-facing execution policy is
/// reconstructed by the host.

/// Canonical flattened direct invocation accepted by `agentic host bridge`.
@JSONSchema
public struct AgenticToolHostDirectInvocation:
    Sendable,
    Codable,
    Hashable
{
    /// Stable identifier for this tool call.
    public let id: String

    /// Exact identifier of one currently registered model-facing tool.
    public let name: String

    /// Input payload conforming to the selected tool's semantic input schema.
    public let input: JSONValue

    /// Optional invocation execution metadata. Workspace selects whether the
    /// requested target is permitted; every model-facing tool may carry it.
    public let execution: ToolInvocation.Target?

    public init(
        id: String,
        name: String,
        input: JSONValue,
        execution: ToolInvocation.Target? = nil
    ) {
        self.id = id
        self.name = name
        self.input = input
        self.execution = execution
    }

    public var call: FunctionCall {
        .init(
            id: id,
            name: name,
            input: input
        )
    }
}

/// Canonical recursive ToolPlan wire payload accepted by the host bridge.
public struct AgenticToolHostPlan:
    Sendable,
    Codable,
    Hashable
{
    public let id: String
    public let root: AgenticToolHostPlanNode
    public let references: [Reference]?

    public init(
        id: String,
        root: AgenticToolHostPlanNode,
        references: [Reference]? = nil
    ) {
        self.id = id
        self.root = root
        self.references = references
    }

    public func agentToolPlan(
        registry: ToolRegistry
    ) throws -> ToolPlan {
        let plan = try ToolPlan(
            id: id,
            root:
                try root.agentToolPlanNode(
                    registry: registry
                ),
            references:
                references ?? []
        )

        return plan
    }
}

/// Canonical recursive plan node. Execution is a sibling of `call`, never part of tool input.
public struct AgenticToolHostPlanNode:
    Sendable,
    Codable,
    Hashable
{
    public let kind: ToolPlan.Node.Kind
    public let call: AgenticToolHostCall?
    public let execution: ToolInvocation.Target?
    public let children: [AgenticToolHostPlanNode]
    public let onSuccess: [AgenticToolHostPlanNode]
    public let onFailure: [AgenticToolHostPlanNode]
    public let onDenied: [AgenticToolHostPlanNode]

    public init(
        kind: ToolPlan.Node.Kind,
        call: AgenticToolHostCall? = nil,
        execution: ToolInvocation.Target? = nil,
        children: [AgenticToolHostPlanNode] = [],
        onSuccess: [AgenticToolHostPlanNode] = [],
        onFailure: [AgenticToolHostPlanNode] = [],
        onDenied: [AgenticToolHostPlanNode] = []
    ) {
        self.kind = kind
        self.call = call
        self.execution = execution
        self.children = children
        self.onSuccess = onSuccess
        self.onFailure = onFailure
        self.onDenied = onDenied
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case call
        case execution
        case children
        case onSuccess
        case onFailure
        case onDenied
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(ToolPlan.Node.Kind.self, forKey: .kind)
        call = try container.decodeIfPresent(AgenticToolHostCall.self, forKey: .call)
        execution = try container.decodeIfPresent(ToolInvocation.Target.self, forKey: .execution)
        children = container.contains(.children)
            ? try container.decode([Self].self, forKey: .children)
            : []
        onSuccess = container.contains(.onSuccess)
            ? try container.decode([Self].self, forKey: .onSuccess)
            : []
        onFailure = container.contains(.onFailure)
            ? try container.decode([Self].self, forKey: .onFailure)
            : []
        onDenied = container.contains(.onDenied)
            ? try container.decode([Self].self, forKey: .onDenied)
            : []
    }

    public func agentToolPlanNode(
        registry: ToolRegistry
    ) throws -> ToolPlan.Node {
        switch kind {
        case .call:
            guard let call,
                  children.isEmpty
            else {
                throw AgenticToolHostError
                    .invalidInvocationPayload(
                        "Call plan nodes require one call and cannot contain ordinary children."
                    )
            }

            guard registry.modelFacingDefinition(
                identifiedBy: ToolIdentifier(call.agentToolCall.name)
            ) != nil else {
                throw AgenticToolHostError.invalidInvocationPayload(
                    "Tool '\(call.name)' is not registered as model-facing."
                )
            }

            return .call(
                call.agentToolCall,
                execution: execution,
                onSuccess:
                    try onSuccess.map {
                        try $0.agentToolPlanNode(
                            registry: registry
                        )
                    },
                onFailure:
                    try onFailure.map {
                        try $0.agentToolPlanNode(
                            registry: registry
                        )
                    },
                onDenied:
                    try onDenied.map {
                        try $0.agentToolPlanNode(
                            registry: registry
                        )
                    }
            )

        case .sequence,
             .batch:
            guard call == nil,
                  execution == nil,
                  onSuccess.isEmpty,
                  onFailure.isEmpty,
                  onDenied.isEmpty
            else {
                throw AgenticToolHostError
                    .invalidInvocationPayload(
                        "\(kind.rawValue) plan nodes contain children only."
                    )
            }

            let nodes = try children.map {
                try $0.agentToolPlanNode(
                    registry: registry
                )
            }

            return
                kind == .sequence
                    ? .sequence(nodes)
                    : .batch(nodes)
        }
    }
}

/// Macro-derived nonrecursive structural source for recursive plan-node schemas.
///
/// Runtime composition replaces JSONValue placeholders with the recursive node
/// reference and exact registered-tool call variant. Core Agentic remains
/// Schema-free.
@JSONSchema
private struct AgenticToolHostPlanNodeSchemaShape:
    Codable
{
    let kind: String
    let call: JSONValue?
    let execution: ToolInvocation.Target?
    let children: [JSONValue]
    let onSuccess: [JSONValue]
    let onFailure: [JSONValue]
    let onDenied: [JSONValue]
}

/// Runtime-specialized host invocation contract generated from the registered ToolRegistry.
public enum AgenticToolHostInvocationContract {
    public static func schema(
        registryInspection capabilities: [ToolRegistryInspectionEntry]
    ) -> JSONSchema {
        let modelCapabilities = capabilities.filter(
            \.isModelFacing
        )

        let callDefinitions = Dictionary(
            uniqueKeysWithValues:
                modelCapabilities.map {
                    capability in

                    (
                        callDefinitionName(
                            capability
                        ),
                        callSchema(
                            for: capability
                        )
                    )
                }
        )

        let callUnion = callUnionSchema(
            modelCapabilities,
            description:
                "One FunctionCall specialized to model-facing tools registered for this host session."
        )

        let direct = JSONSchema.oneOf(
            modelCapabilities.map {
                directInvocationSchema(
                    for: $0
                )
            },
            description:
                "One direct model-facing registered-tool invocation."
        )

        let batch = JSONSchema.array(
            description:
                "Non-empty batch of independent FunctionCall values. Use ToolPlan when execution targeting or dependencies are needed.",
            items: .reference(
                "#/$defs/FunctionCall"
            ),
            minItems: 1
        )

        let plan = planSchema()
        let planNode = planNodeSchema(
            hasCalls:
                !modelCapabilities.isEmpty
        )

        var definitions = callDefinitions
        definitions["FunctionCall"] = callUnion
        definitions["AgentToolExecution"] =
            executionSchema()
        definitions["ToolPlanNode"] =
            planNode

        return JSONSchema.oneOf(
            [
                direct,
                batch,
                plan,
            ],
            description:
                "Canonical JSON accepted by agentic host bridge: direct invocation, non-empty call batch, or recursive ToolPlan."
        )
        .defining(
            definitions
        )
    }

    public static func canonicalPlanExample(
        registryInspection capabilities: [ToolRegistryInspectionEntry]
    ) -> ToolPlan? {
        guard let capability = exampleCapability(
            capabilities
        ) else {
            return nil
        }

        let input = exampleValue(
            for: semanticInputSchema(
                for: capability
            )
        )

        let call = FunctionCall(
            id: "example-call",
            name: capability.identifier.rawValue,
            input: input
        )

        let execution = ToolInvocation.Target(
            workspace: WorkspaceTarget(
                subpath: "DependentPackage"
            )
        )

        return try? ToolPlan(
            id: "example-plan",
            root: .sequence(
                [
                    .call(
                        call,
                        execution: execution
                    ),
                ]
            )
        )
    }
}

private extension AgenticToolHostInvocationContract {
    static func modelCapabilities(
        _ capabilities: [ToolRegistryInspectionEntry]
    ) -> [ToolRegistryInspectionEntry] {
        capabilities.filter(
            \.isModelFacing
        )
    }

    static func semanticInputSchema(
        for capability: ToolRegistryInspectionEntry
    ) -> JSONSchema {
        guard let inputSchema = capability.semanticInputSchema else {
            preconditionFailure(
                "Host invocation schema requested for host-only tool '\(capability.identifier.rawValue)'."
            )
        }

        return inputSchema
    }

    static func callDefinitionName(
        _ capability: ToolRegistryInspectionEntry
    ) -> String {
        "toolcall_\(capability.identifier.rawValue)"
    }

    static func callUnionSchema(
        _ capabilities: [ToolRegistryInspectionEntry],
        description: String
    ) -> JSONSchema {
        JSONSchema.oneOf(
            capabilities.map {
                JSONSchema.reference(
                    "#/$defs/\(callDefinitionName($0))"
                )
            },
            description: description
        )
    }

    static func callSchema(
        for capability: ToolRegistryInspectionEntry
    ) -> JSONSchema {
        specializeObject(
            AgenticToolHostCall.jsonschema,
            description:
                capability.description
        ) { property in
            switch property.name {
            case "name":
                return replacing(
                    property,
                    schema: .constant(
                        .string(
                            capability.identifier.rawValue
                        )
                    )
                )

            case "input":
                return replacing(
                    property,
                    schema:
                        semanticInputSchema(
                            for: capability
                        )
                )

            default:
                return property
            }
        }
    }

    static func directInvocationSchema(
        for capability: ToolRegistryInspectionEntry
    ) -> JSONSchema {
        specializeObject(
            AgenticToolHostDirectInvocation.jsonschema,
            description:
                capability.description
        ) { property in
            switch property.name {
            case "name":
                return replacing(
                    property,
                    schema: .constant(
                        .string(
                            capability.identifier.rawValue
                        )
                    )
                )

            case "input":
                return replacing(
                    property,
                    schema:
                        semanticInputSchema(
                            for: capability
                        )
                )

            case "execution":
                return property

            default:
                return property
            }
        }
    }

    static func executionSchema() -> JSONSchema {
        ToolInvocation.Target.jsonschema
    }

    static func planSchema() -> JSONSchema {
        JSONSchema.object(
            description: "Recursive ToolPlan plan. Call-node execution is a sibling of call; `execution.workspace.subpath` is optional invocation metadata available to every model-facing tool, and Workspace decides whether the target is permitted.",
            additionalProperties: .disallowed
        ) {
            JSONSchema.string(
                "id",
                required: true,
                description: "Stable plan identifier."
            )

            JSONSchema.property(
                "root",
                schema: JSONSchema.reference(
                    "#/$defs/ToolPlanNode"
                ),
                required: true,
                description: "Root recursive plan node."
            )

            JSONSchema.array(
                "references",
                description: "Optional references attached to the plan.",
                items: Reference.jsonschema
            )
        }
    }

    static func planNodeSchema(
        hasCalls: Bool
    ) -> JSONSchema {
        let shape =
            AgenticToolHostPlanNodeSchemaShape
                .jsonschema

        let recursiveArray = JSONSchema.array(
            description:
                "Recursive ToolPlanNode values.",
            items: .reference(
                "#/$defs/ToolPlanNode"
            )
        )
        let emptyRecursiveArray = JSONSchema.array(
            description:
                "This plan-node array must be empty for the selected node kind.",
            items: .reference(
                "#/$defs/ToolPlanNode"
            ),
            maxItems: 0
        )

        let sequence = specializeObject(
            shape,
            description:
                "Run children sequentially; later children execute only after earlier success."
        ) { property in
            switch property.name {
            case "kind":
                replacing(
                    property,
                    schema: .constant(
                        .string("sequence")
                    ),
                    isRequired: true
                )

            case "children":
                replacing(
                    property,
                    schema: recursiveArray,
                    isRequired: false
                )

            case "call",
                 "execution":
                nil

            case "onSuccess",
                 "onFailure",
                 "onDenied":
                replacing(
                    property,
                    schema: emptyRecursiveArray,
                    isRequired: false
                )

            default:
                property
            }
        }

        let batch = specializeObject(
            shape,
            description:
                "Run independent child nodes as a batch."
        ) { property in
            switch property.name {
            case "kind":
                replacing(
                    property,
                    schema: .constant(
                        .string("batch")
                    ),
                    isRequired: true
                )

            case "children":
                replacing(
                    property,
                    schema: recursiveArray,
                    isRequired: false
                )

            case "call",
                 "execution":
                nil

            case "onSuccess",
                 "onFailure",
                 "onDenied":
                replacing(
                    property,
                    schema: emptyRecursiveArray,
                    isRequired: false
                )

            default:
                property
            }
        }

        var variants: [JSONSchema] = [
            sequence,
            batch,
        ]

        if hasCalls {
            variants.append(
                callPlanNodeSchema(
                    shape: shape,
                    recursiveArray: recursiveArray
                )
            )
        }

        return .oneOf(
            variants,
            description:
                "Recursive ToolPlan node. Call nodes carry ordinary optional execution metadata through the shared canonical execution union."
        )
    }

    static func callPlanNodeSchema(
        shape: JSONSchema,
        recursiveArray: JSONSchema
    ) -> JSONSchema {
        let emptyRecursiveArray = JSONSchema.array(
            description:
                "Call plan nodes cannot contain ordinary children.",
            items: .reference(
                "#/$defs/ToolPlanNode"
            ),
            maxItems: 0
        )

        return specializeObject(
            shape,
            description:
                "Invoke one registered tool and optionally branch on outcome."
        ) { property in
            switch property.name {
            case "kind":
                replacing(
                    property,
                    schema: .constant(
                        .string("call")
                    ),
                    isRequired: true
                )

            case "call":
                replacing(
                    property,
                    schema: .reference(
                        "#/$defs/FunctionCall"
                    ),
                    isRequired: true
                )

            case "execution":
                replacing(
                    property,
                    schema: .reference(
                        "#/$defs/AgentToolExecution"
                    )
                )

            case "children":
                replacing(
                    property,
                    schema: emptyRecursiveArray,
                    isRequired: false
                )

            case "onSuccess",
                 "onFailure",
                 "onDenied":
                replacing(
                    property,
                    schema: recursiveArray,
                    isRequired: false
                )

            default:
                property
            }
        }
    }

    static func specializeObject(
        _ schema: JSONSchema,
        description: String?,
        transform: (JSONSchema.Property) -> JSONSchema.Property?
    ) -> JSONSchema {
        guard case let .object(
            properties,
            _
        ) = schema.form
        else {
            return schema.described(
                description
            )
        }

        return JSONSchema(
            form: .object(
                properties: properties.compactMap(
                    transform
                ),
                additionalProperties: .disallowed
            ),
            description: description,
            definitions: schema.definitions
        )
    }

    static func replacing(
        _ property: JSONSchema.Property,
        schema: JSONSchema,
        isRequired: Bool? = nil
    ) -> JSONSchema.Property {
        .init(
            name: property.name,
            schema: schema,
            required: isRequired ?? property.required,
            description: property.description
        )
    }

    static func exampleCapability(
        _ capabilities: [ToolRegistryInspectionEntry]
    ) -> ToolRegistryInspectionEntry? {
        let modelFacing = modelCapabilities(
            capabilities
        )

        return modelFacing.first
    }

    static func exampleValue(
        for schema: JSONSchema
    ) -> JSONValue {
        exampleValue(
            for: schema,
            definitions: schema.definitions
        )
    }

    static func exampleValue(
        for schema: JSONSchema,
        definitions: [String: JSONSchema]
    ) -> JSONValue {
        let availableDefinitions = definitions.merging(
            schema.definitions
        ) { _, new in
            new
        }

        switch schema.form {
        case .any:
            return .object([:])

        case .null:
            return .null

        case .boolean:
            return .bool(false)

        case .integer(let cases):
            return .int(
                cases.first ?? 0
            )

        case .number(let cases):
            return .double(
                cases.first ?? 0
            )

        case .string(let cases):
            return .string(
                cases.first ?? "value"
            )

        case let .array(
            items,
            minItems,
            _,
            _
        ):
            let count = minItems ?? 0
            return .array(
                (0..<count).map { _ in
                    exampleValue(
                        for: items,
                        definitions: availableDefinitions
                    )
                }
            )

        case let .object(
            properties,
            _
        ):
            return .object(
                Dictionary(
                    uniqueKeysWithValues:
                        properties
                            .filter(\.required)
                            .map { property in
                                (
                                    property.name,
                                    exampleValue(
                                        for: property.schema,
                                        definitions: availableDefinitions
                                    )
                                )
                            }
                )
            )

        case .oneOf(let schemas), .anyOf(let schemas):
            guard let first = schemas.first else {
                return .object([:])
            }

            return exampleValue(
                for: first,
                definitions: availableDefinitions
            )

        case .constant(let value):
            return value

        case .reference(let reference):
            let prefix = "#/$defs/"
            guard reference.hasPrefix(prefix) else {
                return .object([:])
            }

            let name = String(
                reference.dropFirst(
                    prefix.count
                )
            )

            guard let resolved = availableDefinitions[name] else {
                return .object([:])
            }

            return exampleValue(
                for: resolved,
                definitions: availableDefinitions
            )
        }
    }
}
