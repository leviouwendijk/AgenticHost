import Agentic
import Primitives
import Schema

extension AgenticToolHostInvocationContract {
    static func diagnostics(
        _ value: JSONValue,
        capabilities: [ToolRegistryInspectionEntry]
    ) -> JSONDiagnostics {
        let contract = schema(
            registryInspection: capabilities
        )

        guard case .oneOf(let forms) = contract.form,
              forms.count == 3
        else {
            return contract.diagnostics(
                value
            )
        }

        switch value {
        case .array(let values):
            return batchDiagnostics(
                values,
                contract: contract,
                batch: forms[1],
                capabilities: capabilities
            )

        case .object(let object):
            if isPlanNode(object) {
                return JSONDiagnostics(
                    [
                        JSONIssue(
                            kind: .missing,
                            path: JSONCodingPath(
                                [
                                    .key("root"),
                                ]
                            ),
                            reason: "Received an ToolPlan node as the top-level invocation. Wrap the node in an ToolPlan containing id and root."
                        ),
                    ]
                )
            }

            if isPlanEnvelope(object) {
                return planDiagnostics(
                    value,
                    object: object,
                    plan: forms[2],
                    contract: contract,
                    capabilities: capabilities
                )
            }

            return directDiagnostics(
                value,
                object: object,
                direct: forms[0],
                contract: contract,
                capabilities: capabilities
            )

        default:
            return contract.diagnostics(
                value
            )
        }
    }
}

private extension AgenticToolHostInvocationContract {
    static func directDiagnostics(
        _ value: JSONValue,
        object: [String: JSONValue],
        direct: JSONSchema,
        contract: JSONSchema,
        capabilities: [ToolRegistryInspectionEntry]
    ) -> JSONDiagnostics {
        let structural = AgenticToolHostDirectInvocation
            .jsonschema
            .defining(
                contract.definitions
            )
            .diagnostics(
                value
            )

        guard case .string(let name) = object["name"] else {
            return structural
        }

        guard capability(
            named: name,
            in: capabilities
        ) != nil else {
            return JSONDiagnostics(
                structural.issues
                    + [
                        JSONIssue(
                            kind: .invalidValue,
                            path: JSONCodingPath(
                                [
                                    .key("name"),
                                ]
                            ),
                            reason: "No model-facing registered tool named '\(name)'."
                        ),
                    ]
            )
        }

        guard let branch = objectBranch(
            named: name,
            in: direct
        ) else {
            return structural
        }

        return branch
            .defining(
                contract.definitions
            )
            .diagnostics(
                value
            )
    }

    static func batchDiagnostics(
        _ values: [JSONValue],
        contract: JSONSchema,
        batch: JSONSchema,
        capabilities: [ToolRegistryInspectionEntry]
    ) -> JSONDiagnostics {
        if values.isEmpty {
            return batch
                .defining(
                    contract.definitions
                )
                .diagnostics(
                    .array(values)
                )
        }

        var issues: [JSONIssue] = []

        for (
            index,
            value
        ) in values.enumerated() {
            let diagnostics = callDiagnostics(
                value,
                contract: contract,
                capabilities: capabilities
            )

            issues.append(
                contentsOf: prefixed(
                    diagnostics.issues,
                    by: [
                        .index(index),
                    ]
                )
            )
        }

        return JSONDiagnostics(
            issues
        )
    }

    static func callDiagnostics(
        _ value: JSONValue,
        contract: JSONSchema,
        capabilities: [ToolRegistryInspectionEntry]
    ) -> JSONDiagnostics {
        let structural = AgenticToolHostCall
            .jsonschema
            .defining(
                contract.definitions
            )
            .diagnostics(
                value
            )

        guard case .object(let object) = value,
              case .string(let name) = object["name"]
        else {
            return structural
        }

        guard capability(
            named: name,
            in: capabilities
        ) != nil else {
            return JSONDiagnostics(
                structural.issues
                    + [
                        JSONIssue(
                            kind: .invalidValue,
                            path: JSONCodingPath(
                                [
                                    .key("name"),
                                ]
                            ),
                            reason: "No model-facing registered tool named '\(name)'."
                        ),
                    ]
            )
        }

        guard let schema = callSchema(
            named: name,
            contract: contract
        ) else {
            return structural
        }

        return schema
            .defining(
                contract.definitions
            )
            .diagnostics(
                value
            )
    }

    static func planDiagnostics(
        _ value: JSONValue,
        object: [String: JSONValue],
        plan: JSONSchema,
        contract: JSONSchema,
        capabilities: [ToolRegistryInspectionEntry]
    ) -> JSONDiagnostics {
        let structural = plan
            .defining(
                contract.definitions
            )
            .diagnostics(
                value
            )

        var issues = structural.issues.filter {
            !isUnionFailure(
                $0
            )
        }

        if let root = object["root"] {
            issues.append(
                contentsOf: planNodeIssues(
                    in: root,
                    path: JSONCodingPath(
                        [
                            .key("root"),
                        ]
                    ),
                    contract: contract,
                    capabilities: capabilities
                )
            )
        }

        return JSONDiagnostics(
            issues
        )
    }

    static func planNodeIssues(
        in value: JSONValue,
        path: JSONCodingPath,
        contract: JSONSchema,
        capabilities: [ToolRegistryInspectionEntry]
    ) -> [JSONIssue] {
        guard case .object(let object) = value else {
            return [
                JSONIssue(
                    kind: .typeMismatch,
                    path: path,
                    reason: "Expected an ToolPlan node object."
                ),
            ]
        }

        guard let kindValue = object["kind"] else {
            return [
                JSONIssue(
                    kind: .missing,
                    path: appending(
                        .key("kind"),
                        to: path
                    ),
                    reason: "Missing required plan-node kind."
                ),
            ]
                + nestedPlanIssues(
                    in: object,
                    kind: nil,
                    path: path,
                    contract: contract,
                    capabilities: capabilities
                )
        }

        guard case .string(let kind) = kindValue else {
            return [
                JSONIssue(
                    kind: .typeMismatch,
                    path: appending(
                        .key("kind"),
                        to: path
                    ),
                    reason: "Expected plan-node kind 'call', 'sequence', or 'batch'."
                ),
            ]
                + nestedPlanIssues(
                    in: object,
                    kind: nil,
                    path: path,
                    contract: contract,
                    capabilities: capabilities
                )
        }

        guard [
            "call",
            "sequence",
            "batch",
        ].contains(kind) else {
            return [
                JSONIssue(
                    kind: .invalidValue,
                    path: appending(
                        .key("kind"),
                        to: path
                    ),
                    reason: "Unknown ToolPlan node kind '\(kind)'."
                ),
            ]
                + nestedPlanIssues(
                    in: object,
                    kind: nil,
                    path: path,
                    contract: contract,
                    capabilities: capabilities
                )
        }

        var issues: [JSONIssue] = []

        if let schema = planNodeBranch(
            kind: kind,
            object: object,
            contract: contract,
            capabilities: capabilities
        ) {
            let structural = schema
                .defining(
                    contract.definitions
                )
                .diagnostics(
                    value
                )

            issues.append(
                contentsOf: prefixed(
                    structural.issues.filter {
                        !isUnionFailure(
                            $0
                        )
                    },
                    by: path.components
                )
            )
        }

        if kind == "call",
           let call = object["call"]
        {
            let diagnostics = callDiagnostics(
                call,
                contract: contract,
                capabilities: capabilities
            )

            issues.append(
                contentsOf: prefixed(
                    diagnostics.issues,
                    by: path.components
                        + [
                            .key("call"),
                        ]
                )
            )
        }

        issues.append(
            contentsOf: nestedPlanIssues(
                in: object,
                kind: kind,
                path: path,
                contract: contract,
                capabilities: capabilities
            )
        )

        return issues
    }

    static func nestedPlanIssues(
        in object: [String: JSONValue],
        kind: String?,
        path: JSONCodingPath,
        contract: JSONSchema,
        capabilities: [ToolRegistryInspectionEntry]
    ) -> [JSONIssue] {
        let keys: [String]

        switch kind {
        case "call":
            keys = [
                "onSuccess",
                "onFailure",
                "onDenied",
            ]

        case "sequence",
             "batch":
            keys = [
                "children",
            ]

        default:
            keys = [
                "children",
                "onSuccess",
                "onFailure",
                "onDenied",
            ]
        }

        var issues: [JSONIssue] = []

        for key in keys {
            guard case .array(let values) = object[key] else {
                continue
            }

            for (
                index,
                child
            ) in values.enumerated() {
                issues.append(
                    contentsOf: planNodeIssues(
                        in: child,
                        path: JSONCodingPath(
                            path.components
                                + [
                                    .key(key),
                                    .index(index),
                                ]
                        ),
                        contract: contract,
                        capabilities: capabilities
                    )
                )
            }
        }

        return issues
    }

    static func planNodeBranch(
        kind: String,
        object: [String: JSONValue],
        contract: JSONSchema,
        capabilities: [ToolRegistryInspectionEntry]
    ) -> JSONSchema? {
        guard let node = contract.definitions[
            "ToolPlanNode"
        ],
              case .oneOf(let variants) = node.form
        else {
            return nil
        }

        if kind == "sequence"
            || kind == "batch"
        {
            return variants.first {
                discriminator(
                    "kind",
                    in: $0
                ) == kind
            }
        }

        guard kind == "call" else {
            return nil
        }

        let callVariants = variants.filter {
            discriminator(
                "kind",
                in: $0
            ) == "call"
        }

        return callVariants.first
    }

    static func callSchema(
        named name: String,
        contract: JSONSchema
    ) -> JSONSchema? {
        contract.definitions.values.first {
            schema in

            discriminator(
                "name",
                in: schema
            ) == name
        }
    }

    static func objectBranch(
        named name: String,
        in schema: JSONSchema
    ) -> JSONSchema? {
        guard case .oneOf(let branches) = schema.form else {
            return nil
        }

        return branches.first {
            discriminator(
                "name",
                in: $0
            ) == name
        }
    }

    static func discriminator(
        _ name: String,
        in schema: JSONSchema
    ) -> String? {
        guard case .object(let properties, _) = schema.form,
              let property = properties.first(
                where: {
                    $0.name == name
                }
              ),
              case .constant(.string(let value)) = property.schema.form
        else {
            return nil
        }

        return value
    }

    static func hasProperty(
        _ name: String,
        in schema: JSONSchema
    ) -> Bool {
        guard case .object(let properties, _) = schema.form else {
            return false
        }

        return properties.contains {
            $0.name == name
        }
    }

    static func capability(
        named name: String,
        in capabilities: [ToolRegistryInspectionEntry]
    ) -> ToolRegistryInspectionEntry? {
        capabilities.first {
            $0.isModelFacing
                && $0.identifier.rawValue == name
        }
    }

    static func isPlanEnvelope(
        _ object: [String: JSONValue]
    ) -> Bool {
        if object["root"] != nil {
            return true
        }

        return object["id"] != nil
            && object["name"] == nil
            && object["input"] == nil
    }

    static func isPlanNode(
        _ object: [String: JSONValue]
    ) -> Bool {
        object["root"] == nil
            && object["kind"] != nil
            && (
                object["children"] != nil
                    || object["call"] != nil
                    || object["onSuccess"] != nil
                    || object["onFailure"] != nil
                    || object["onDenied"] != nil
            )
    }

    static func isUnionFailure(
        _ issue: JSONIssue
    ) -> Bool {
        issue.reason.hasPrefix(
            "Expected exactly one oneOf branch to match;"
        )
    }

    static func appending(
        _ component: JSONCodingPath.Component,
        to path: JSONCodingPath
    ) -> JSONCodingPath {
        JSONCodingPath(
            path.components
                + [
                    component,
                ]
        )
    }

    static func prefixed(
        _ issues: [JSONIssue],
        by prefix: [JSONCodingPath.Component]
    ) -> [JSONIssue] {
        issues.map {
            issue in

            JSONIssue(
                kind: issue.kind,
                path: JSONCodingPath(
                    prefix
                        + issue.path.components
                ),
                reason: issue.reason
            )
        }
    }
}
