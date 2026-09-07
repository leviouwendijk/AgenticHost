import Primitives
import Agentic
import AgenticInterfaces

package struct HostPendingCall: Sendable {
    package let runID: String
    package let path: String
    package let call: AgentToolCall
    package let execution: JSONValue?

    package init(
        runID: String,
        path: String,
        call: AgentToolCall,
        execution: JSONValue?
    ) {
        self.runID = runID
        self.path = path
        self.call = call
        self.execution = execution
    }
}

package actor HostPendingPlans {
    private var plansByRunID: [String: AgentToolPlan] = [:]
    private var runOrder: [String] = []
    private var documentsByRunID:
        [String: [AgenticHostConsoleDocumentPresentation]] = [:]

    package init() {}

    package func insert(
        _ plan: AgentToolPlan,
        runID: String
    ) {
        if plansByRunID[runID] == nil {
            runOrder.append(
                runID
            )
            documentsByRunID[runID] = []
        }

        plansByRunID[runID] = plan
    }

    func plan(
        runID: String
    ) -> AgentToolPlan? {
        plansByRunID[runID]
    }

    func call(
        runID: String,
        stepID: String
    ) -> HostPendingCall? {
        guard let plan = plansByRunID[runID] else {
            return nil
        }

        return Self.call(
            plan.root,
            runID: runID,
            stepID: stepID,
            path: "root"
        )
    }

    func store(
        _ document: AgenticHostConsoleDocumentPresentation
    ) {
        guard plansByRunID[document.runID] != nil else {
            return
        }

        var documents = documentsByRunID[document.runID] ?? []

        if let index = documents.firstIndex(
            where: {
                $0.stepID == document.stepID
                    && $0.kind == document.kind
            }
        ) {
            documents[index] = document
        } else {
            documents.append(
                document
            )
        }

        documentsByRunID[document.runID] = documents
    }

    func documents() -> [AgenticHostConsoleDocumentPresentation] {
        runOrder.flatMap { runID in
            documentsByRunID[runID] ?? []
        }
    }

    package func take(
        runID: String
    ) -> AgentToolPlan? {
        guard let plan = plansByRunID.removeValue(
            forKey: runID
        ) else {
            return nil
        }

        runOrder.removeAll {
            $0 == runID
        }
        documentsByRunID.removeValue(
            forKey: runID
        )

        return plan
    }

    func restore(
        _ plan: AgentToolPlan,
        runID: String
    ) {
        insert(
            plan,
            runID: runID
        )
    }

    func presentations() -> [AgenticHostConsoleRunPresentation] {
        runOrder.compactMap { runID in
            guard let plan = plansByRunID[runID] else {
                return nil
            }

            return Self.presentation(
                plan,
                runID: runID
            )
        }
    }
}

private extension HostPendingPlans {
    static func call(
        _ node: AgentToolPlanNode,
        runID: String,
        stepID: String,
        path: String
    ) -> HostPendingCall? {
        switch node {
        case .call(
            let call,
            let execution,
            let onSuccess,
            let onFailure,
            let onDenied
        ):
            if call.id == stepID {
                return HostPendingCall(
                    runID: runID,
                    path: path,
                    call: call,
                    execution: execution
                )
            }

            return Self.call(
                onSuccess,
                runID: runID,
                stepID: stepID,
                path: "\(path).onSuccess"
            )
                ?? Self.call(
                    onFailure,
                    runID: runID,
                    stepID: stepID,
                    path: "\(path).onFailure"
                )
                ?? Self.call(
                    onDenied,
                    runID: runID,
                    stepID: stepID,
                    path: "\(path).onDenied"
                )

        case .sequence(let children):
            return Self.call(
                children,
                runID: runID,
                stepID: stepID,
                path: "\(path).sequence"
            )

        case .batch(let children):
            return Self.call(
                children,
                runID: runID,
                stepID: stepID,
                path: "\(path).batch"
            )
        }
    }

    static func call(
        _ nodes: [AgentToolPlanNode],
        runID: String,
        stepID: String,
        path: String
    ) -> HostPendingCall? {
        for (index, node) in nodes.enumerated() {
            if let pending = Self.call(
                node,
                runID: runID,
                stepID: stepID,
                path: "\(path)[\(index)]"
            ) {
                return pending
            }
        }

        return nil
    }

    static func presentation(
        _ plan: AgentToolPlan,
        runID: String
    ) -> AgenticHostConsoleRunPresentation {
        AgenticHostConsoleRunPresentation(
            id: runID,
            title: plan.id,
            summary: "Awaiting execution policy.",
            state: .ready,
            steps: steps(
                plan.root,
                path: "root"
            )
        )
    }

    static func steps(
        _ node: AgentToolPlanNode,
        path: String
    ) -> [AgenticHostConsoleStepPresentation] {
        switch node {
        case .call(
            let call,
            _,
            let onSuccess,
            let onFailure,
            let onDenied
        ):
            var result = [
                AgenticHostConsoleStepPresentation(
                    id: call.id,
                    title: call.name,
                    state: .pending
                ),
            ]

            result.append(
                contentsOf: steps(
                    onSuccess,
                    path: "\(path).onSuccess"
                )
            )
            result.append(
                contentsOf: steps(
                    onFailure,
                    path: "\(path).onFailure"
                )
            )
            result.append(
                contentsOf: steps(
                    onDenied,
                    path: "\(path).onDenied"
                )
            )

            return result

        case .sequence(let children):
            return steps(
                children,
                path: "\(path).sequence"
            )

        case .batch(let children):
            return steps(
                children,
                path: "\(path).batch"
            )
        }
    }

    static func steps(
        _ nodes: [AgentToolPlanNode],
        path: String
    ) -> [AgenticHostConsoleStepPresentation] {
        nodes.enumerated().flatMap { index, node in
            steps(
                node,
                path: "\(path)[\(index)]"
            )
        }
    }
}
