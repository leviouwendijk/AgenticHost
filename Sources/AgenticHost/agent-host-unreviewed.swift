import Foundation
import Writers

extension AgentHostLocalSessionState {
    func unreviewed(
        _ id: UUID
    ) -> StandardMutationPublication? {
        unreviewedPublications.first { $0.result.id == id }
    }

    /// Reviewed and kept, or rolled back: no longer awaiting review.
    func markReviewed(
        _ ids: Set<UUID>
    ) {
        unreviewedPublications.removeAll { ids.contains($0.result.id) }
    }
}

extension StandardMutationRollbackPlan {
    /// Whether every target is still as this publication left it, checked
    /// before anything is written. A later change (by Agentic, an editor or
    /// git) to a target makes rolling back this one alone unsafe; the paths
    /// that changed, or empty when rollback can proceed.
    func driftedTargets() -> [URL] {
        var seen: Set<URL> = []
        var drifted: [URL] = []
        func first(_ url: URL) -> Bool { seen.insert(url.standardizedFileURL).inserted }
        for action in actions {
            switch action {
            case .none:
                continue
            case .delete_created_file(let item):
                guard first(item.target) else { continue }
                let current = try? StandardResourceState.read(at: item.target)
                if current?.fingerprint != item.requiredCurrentFingerprint { drifted.append(item.target) }
            case .restore_text(let item):
                guard first(item.target) else { continue }
                let current = try? StandardResourceState.read(at: item.target, encoding: item.encoding.foundation)
                if current?.fingerprint != item.requiredCurrentFingerprint { drifted.append(item.target) }
            case .restore_data(let item):
                guard first(item.target) else { continue }
                let current = try? StandardResourceState.read(at: item.target)
                if current?.fingerprint != item.requiredCurrentFingerprint { drifted.append(item.target) }
            case .move_resource(let item):
                guard first(item.source), first(item.destination) else { continue }
                if (try? item.requiredSourceState.requireCurrent()) == nil { drifted.append(item.source) }
                if (try? item.requiredDestinationState.requireCurrent()) == nil { drifted.append(item.destination) }
            }
        }
        return drifted
    }
}
