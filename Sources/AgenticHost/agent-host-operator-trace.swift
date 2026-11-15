import Agentic
import AgenticRuntime
import Writers
import Foundation

public extension AgentHost {
    /// What a turn runs with, as the operator chose it. A turn traces what
    /// differs from the previous one; the first turn traces all of it.
    struct TurnSettings: Sendable, Hashable {
        public var values: [String: String]
        public var capabilities: [String: Set<String>]

        public init(
            modelSelection: AgentModelSelection,
            invocationOptions: AgentModelInvocationOptions,
            configuration: AgentExecutor.Configuration,
            available: AgentCapabilitySet,
            visible: AgentCapabilitySet
        ) {
            values = [
                "model": modelSelection.preferences.preferredProfileIdentifier?.rawValue ?? "default",
                "purpose": modelSelection.purpose.rawValue,
                "delivery": configuration.responseDelivery.rawValue,
                "autonomy": configuration.autonomyMode.rawValue,
                "timeout": invocationOptions.timeoutseconds.map { "\($0)s" } ?? "none",
            ]
            func names(_ set: AgentCapabilitySet) -> Set<String> {
                Set(set.tools.map(\.rawValue))
                    .union(set.programs.map(\.rawValue))
                    .union(set.inferences.map(\.rawValue))
                    .union(set.agents.map(\.rawValue))
            }
            capabilities = [
                "available": names(available),
                "visible": names(visible),
            ]
        }

        /// `nil` when nothing changed.
        public func changes(
            since previous: TurnSettings?
        ) -> String? {
            var parts: [String] = []
            for key in values.keys.sorted() where values[key] != previous?.values[key] {
                let now = values[key] ?? ""
                if let before = previous?.values[key] {
                    parts.append("\(key) \(before) → \(now)")
                } else {
                    parts.append("\(key) \(now)")
                }
            }
            for key in capabilities.keys.sorted() {
                let now = capabilities[key] ?? []
                guard let before = previous?.capabilities[key] else {
                    parts.append("\(key) \(now.count)")
                    continue
                }
                let added = now.subtracting(before).sorted().map { "+\($0)" }
                let removed = before.subtracting(now).sorted().map { "-\($0)" }
                if !(added + removed).isEmpty {
                    parts.append("\(key) " + (added + removed).joined(separator: " "))
                }
            }
            return parts.isEmpty ? nil : parts.joined(separator: "; ")
        }
    }
}

extension AgentHostLocalSessionState {
    func traceTurnSettings(
        _ settings: AgentHost.TurnSettings,
        run: String
    ) async {
        defer { turnSettings = settings }
        guard let changes = settings.changes(since: turnSettings) else { return }
        await record(.operator_command, "settings: \(changes)", run: run)
    }
}

extension AgentHost.Local {
    /// Runs an owner decision and traces it in each session it touches:
    /// `action → outcome`, or `action → refused: reason`.
    func traced<Value>(
        _ action: String,
        in sessions: [AgentHostLocalSessionState],
        outcome: (Value) -> String,
        _ body: () async throws -> Value
    ) async throws -> Value {
        do {
            let value = try await body()
            for state in sessions {
                await state.record(.operator_command, "\(action) → \(outcome(value))")
            }
            return value
        } catch {
            for state in sessions {
                await state.record(.operator_command, "\(action) → refused: \(error.localizedDescription)")
            }
            throw error
        }
    }

    /// The sessions owning any of `ids`, each with its own unit count.
    func owners(
        of ids: [UUID]
    ) async -> [(state: AgentHostLocalSessionState, units: Int)] {
        var owners: [(AgentHostLocalSessionState, Int)] = []
        for state in sessionsByID.values {
            let units = await state.stagedUnitCount(among: ids)
            if units > 0 { owners.append((state, units)) }
        }
        return owners
    }
}

extension StandardMutationPublication {
    var operatorOutcome: String {
        let written = contributions.flatMap(\.entries).filter(\.was_applied).count
        return "published \(written) \(written == 1 ? "change" : "changes")"
    }
}
