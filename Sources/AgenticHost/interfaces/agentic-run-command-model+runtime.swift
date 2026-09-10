import Agentic
import AgenticInterfaces
import AgenticRuntime

public extension AgenticRunCommandModel {
    init(
        prompt: String,
        application: ModeRuntimeApplication,
        request: AgentRequest
    ) {
        self.init(
            prompt: prompt,
            modeID: application.modeID,
            modeTitle: application.selection.mode.title,
            routePurpose: application.modelSelection.purpose,
            autonomyMode: application.configuration.autonomyMode,
            budgetPosture: application.selection.budgetPosture,
            approvalStrictness: application.selection.approvalStrictness,
            exposedToolNames: request.tools.map(\.name).sorted(),
            loadedSkillIDs: application.loadedSkills.map(\.identifier),
            missingSkillIDs: application.missingSkillIdentifiers,
            metadata: request.metadata
        )
    }
}
