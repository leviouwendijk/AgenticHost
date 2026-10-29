import Agentic
import AgenticRuntime
import SwiftUI

/// Read-only native presentation of the same checkpoint evidence used by CLI.
/// State and authority continue to belong to the runtime/host.
@MainActor
struct DesktopRunStatusView: View {
    let snapshot: AgentRunStateSnapshot

    private var meaningfulEvents: [Run.Event.State] {
        snapshot.events.filter { $0.kind != .assistant_delta }
    }

    private var isRunning: Bool {
        switch snapshot.phase {
        case .ready_for_model, .receiving_model_response, .processing_tool_calls:
            true
        case .suspended, .awaiting_approval, .interrupted, .failed, .completed:
            false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if isRunning { ProgressView().controlSize(.small) }
                Text(snapshot.phase.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Iteration \(snapshot.state.iteration)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let maximum = snapshot.runLimits.iterations {
                    Text("/ \(maximum)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let failure = snapshot.failure {
                Text(failure.message).foregroundStyle(.red).textSelection(.enabled)
            }
            if !snapshot.toolUses.isEmpty {
                DisclosureGroup("Tools (\(snapshot.toolUses.count))") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(snapshot.toolUses) { tool in
                            DisclosureGroup {
                                if let preflight = tool.preflight {
                                    Text(preflight.summary).textSelection(.enabled)
                                    Text("Risk: \(preflight.risk.rawValue)")
                                        .foregroundStyle(.secondary)
                                }
                                if let result = tool.result {
                                    if let projection = result.projection {
                                        Text("Result: \(projection.status)")
                                            .textSelection(.enabled)
                                    } else {
                                        Text("Result recorded (no projection)")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } label: {
                                HStack {
                                    Text(tool.toolCall.tool.rawValue)
                                        .font(.caption.monospaced())
                                    Spacer()
                                    Text(tool.disposition.rawValue.replacingOccurrences(of: "_", with: " "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            if !meaningfulEvents.isEmpty {
                DisclosureGroup("Events (\(meaningfulEvents.count))") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(meaningfulEvents.suffix(30))) { event in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text("#\(event.iteration)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(event.kind.rawValue.replacingOccurrences(of: "_", with: " "))
                                    .font(.caption.weight(.semibold))
                                Text(event.summary)
                                    .font(.caption)
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
