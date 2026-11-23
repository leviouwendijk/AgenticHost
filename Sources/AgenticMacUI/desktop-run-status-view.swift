import AgenticPresentation
import SwiftUI

/// The current run as the engine projects it: state, steps and the
/// delegated agents. The terminal's run card shows the same projection.
@MainActor
struct DesktopRunStatusView: View {
    let run: AgenticHostConsoleRunPresentation

    private var isActive: Bool {
        run.state == .active
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if isActive { ProgressView().controlSize(.small) }
                Text(run.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(run.state.rawValue.desktopLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let iteration = run.iteration {
                    Text("Iteration \(iteration)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let summary = run.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .textSelection(.enabled)
            }
            ForEach(run.notes, id: \.self) { note in
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !run.steps.isEmpty {
                DisclosureGroup("Steps (\(run.steps.count))") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(run.steps, id: \.id) { step in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text(step.state.rawValue.desktopLabel)
                                    .font(.caption)
                                    .foregroundStyle(step.state == .failed ? .red : .secondary)
                                    .frame(width: 72, alignment: .leading)
                                Text(step.title)
                                    .font(.caption.monospaced())
                                if let detail = step.detail, !detail.isEmpty {
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .textSelection(.enabled)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            if !run.agents.isEmpty {
                DisclosureGroup("Agents (\(run.agents.count))") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(run.agents, id: \.id) { agent in
                            HStack(alignment: .firstTextBaseline) {
                                Text(agent.title)
                                    .padding(.leading, CGFloat(agent.depth) * 12)
                                Text(agent.state.rawValue.desktopLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if let model = agent.model {
                                    Text(model)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
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

extension String {
    /// `awaitingApproval` and `pause_pending` as "awaiting approval", "pause pending".
    var desktopLabel: String {
        var words = ""
        for character in self {
            if character == "_" {
                words.append(" ")
            } else if character.isUppercase {
                words.append(" ")
                words.append(contentsOf: character.lowercased())
            } else {
                words.append(character)
            }
        }
        return words
    }
}
