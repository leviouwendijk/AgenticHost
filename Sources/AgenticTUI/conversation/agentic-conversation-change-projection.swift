import Agentic
import AgenticContextWindow
import AgenticInterfaces
import AgenticRuntime

/// Run events that changed what a run works with, as Changes cards.
package enum AgenticConversationChangeProjection {
    /// A `context_changed` event: what one request carried less of.
    package static func change(
        _ event: Run.Event.State,
        runID: String
    ) -> AgenticChangePresentation? {
        let changes = (event.contextChanges ?? []).filter { $0.reason != .compacted }
        guard !changes.isEmpty else { return nil }
        let reasons = Set(changes.map(\.reason))
        let summary: String
        if reasons.count == 1, let reason = reasons.first {
            summary = "\(changes.count) × \(label(reason))"
        } else {
            summary = "\(changes.count) items shortened or left out"
        }
        return .init(
            id: event.id,
            kind: .context,
            runID: runID,
            iteration: event.iteration + 1,
            summary: summary,
            reason: reasons.count == 1
                ? AgenticChangePresentation.contextReason(reasons.first!.rawValue)
                : "the request was fitted to the history budget",
            items: changes.enumerated().map { index, change in
                .init(
                    id: "\(event.id)-\(index)",
                    subject: change.call.map { "\($0.name) · \($0.id)" } ?? "message \(change.messageID)",
                    detail: change.sourceCall.map { "→ see \($0.id)" }
                        ?? AgenticChangePresentation.contextReason(change.reason.rawValue),
                    // A pointer names a result still in view; other content
                    // is in the session log, readable only with a reader.
                    isRecoverable: change.reason == .repeated_result || change.reason == .compacted ? true : nil
                )
            },
            // Pointers to preserved content lose nothing.
            isLossy: !reasons.isSubset(of: [.repeated_result, .compacted])
        )
    }

    /// An explicit compaction: which results became pointers.
    static func compaction(
        _ compaction: ContextWindow.Compaction
    ) -> AgenticChangePresentation {
        .init(
            id: compaction.id,
            kind: .context,
            summary: "\(compaction.pointers.count) result\(compaction.pointers.count == 1 ? "" : "s") compacted · ≈\(compaction.estimatedTokensSaved) tokens",
            reason: "explicit compaction: pointers to preserved results; one cache miss, then a stable prefix",
            items: compaction.pointers.map { pointer in
                .init(
                    id: compaction.id + "-" + pointer.call.id,
                    subject: "\(pointer.call.name) · \(pointer.call.id)",
                    detail: "≈\(pointer.estimatedTokens) tokens · \(pointer.preview)",
                    isRecoverable: true
                )
            }
        )
    }

    /// Which model answered, for the answer's label.
    package static func route(
        _ route: Run.Event.Route,
        models: [AgenticConversationModelPresentation]
    ) -> AgenticModelRoutePresentation {
        .init(
            title: route.title,
            provider: route.gateway.rawValue,
            selectedTitle: route.isRerouted
                ? route.preferredProfileID.map { id in models.first { $0.id == id }?.title ?? id.rawValue } ?? "selection"
                : nil,
            reason: route.reason
        )
    }

    /// A request served by another model than selected: only with fallback
    /// allowed, and never unseen.
    package static func reroute(
        _ event: Run.Event.State,
        route: Run.Event.Route,
        runID: String,
        models: [AgenticConversationModelPresentation]
    ) -> AgenticChangePresentation {
        let presented = self.route(route, models: models)
        return .init(
            id: event.id,
            kind: .route,
            runID: runID,
            iteration: event.iteration + 1,
            summary: "\(presented.selectedTitle ?? "selection") → \(route.title)",
            reason: route.reason ?? "the selected model could not serve this request; fallback is allowed",
            items: [.init(
                id: event.id + "-route",
                subject: route.title,
                detail: "\(route.gateway.rawValue) · \(route.model)" + (route.tier.map { " · \($0.rawValue)" } ?? "")
            )],
            isLossy: true
        )
    }

    /// A run's opening: the schemas its first request carried, what put
    /// each in view, and what they cost. Shown once, and again only when a
    /// run opens differently.
    package static func opening(
        _ advertised: Run.Event.State,
        events: [Run.Event.State],
        runID: String
    ) -> AgenticChangePresentation? {
        guard let advertisement = advertised.advertisement else { return nil }
        let sources = exposedSources(in: events.first { $0.kind == .capability_changed && $0.iteration == advertised.iteration })
        let counts = Dictionary(grouping: advertisement.entries) { sources[$0.name] ?? .declared }
        let order: [Run.Event.CapabilityChange.Source] = [
            .declared, .ambient, .discovery, .session_readers, .result_reader, .tool_reveal, .other,
        ]
        let bySource = order.compactMap { source in
            counts[source].map { "\(label(source)) \($0.count)" }
        }
        let core = advertisement.entries.filter { $0.detail == .core }.count
        return .init(
            id: advertised.id,
            kind: .capability,
            runID: runID,
            iteration: advertised.iteration + 1,
            summary: "opened with \(advertisement.entries.count) tool\(advertisement.entries.count == 1 ? "" : "s") · ≈\(advertisement.estimatedTokens) tokens",
            reason: bySource.joined(separator: " · ")
                + (core > 0 ? "; \(core) in core form, ≈\(advertisement.fullTokens) in full" : ""),
            items: advertisement.entries.map { entry in
                .init(
                    id: "\(advertised.id)-\(entry.name)",
                    subject: entry.name,
                    detail: "≈\(entry.estimatedTokens)"
                        + (entry.detail == .core ? " core (≈\(entry.fullTokens) full)" : "")
                        + " · \(label(sources[entry.name] ?? .declared))"
                )
            }
        )
    }

    /// Later requests advertising other tools than the one before: the
    /// provider's cached prefix, which starts with them, is written again.
    package static func toolsChanged(
        _ advertised: Run.Event.State,
        events: [Run.Event.State],
        runID: String
    ) -> AgenticChangePresentation {
        let entries = advertised.advertisement?.entries ?? []
        let changes = events.first {
            $0.kind == .capability_changed && $0.iteration == advertised.iteration
        }?.capabilityChanges ?? []
        let tokens = advertised.advertisement?.estimatedTokens ?? 0
        return .init(
            id: advertised.id,
            kind: .capability,
            runID: runID,
            iteration: advertised.iteration + 1,
            summary: "tools changed · \(entries.count) schemas, ≈\(tokens) tokens",
            reason: "the advertised tools changed, so the provider's cached prefix is written again",
            items: changes.filter { $0.operation == .exposed || $0.operation == .hidden }.map { change in
                .init(
                    id: "\(advertised.id)-\(change.reference.identifier)",
                    subject: change.reference.identifier,
                    detail: "\(change.operation.rawValue) · \(label(change.source))"
                )
            }
        )
    }

    private static func exposedSources(
        in event: Run.Event.State?
    ) -> [String: Run.Event.CapabilityChange.Source] {
        var sources: [String: Run.Event.CapabilityChange.Source] = [:]
        for change in event?.capabilityChanges ?? [] where change.operation == .exposed {
            sources[change.reference.identifier] = change.source
        }
        return sources
    }

    private static func label(
        _ source: Run.Event.CapabilityChange.Source
    ) -> String {
        source.rawValue.replacingOccurrences(of: "_", with: " ")
    }

    /// A `context_pressure` event: advice, not an action.
    static func pressure(
        _ event: Run.Event.State,
        runID: String
    ) -> AgenticChangePresentation {
        .init(
            id: event.id,
            kind: .context,
            runID: runID,
            iteration: event.iteration + 1,
            summary: "soft limit passed",
            reason: event.summary + ". Nothing was changed."
        )
    }

    static func label(
        _ reason: ContextWindow.HistorySelection.Change.Reason
    ) -> String {
        switch reason {
        case .aged_result: "aged result shortened"
        case .budget_result: "result shortened"
        case .unseen_result: "unread result shortened"
        case .repeated_result: "repeat pointed at its original"
        case .turn_budget: "earlier turn left out"
        case .exchange_budget: "tool exchange left out"
        case .working_set: "outside the working set"
        case .compacted: "result compacted to a pointer"
        }
    }
}
