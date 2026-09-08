import Agentic
import AgenticExecution
import AgenticHost
import AgenticInterfaces
import AgenticModels
import AgenticRuntime
import AgenticTools
import Foundation

package enum AgenticConversationSessionError: Error, LocalizedError {
    case noModelProfiles
    case modelProfileUnavailable(String)
    case missingSkills([String])
    case runUnavailable(String)
    case staleApproval(runID: String, stepID: String)
    case unsupportedHostAction(String)

    package var errorDescription: String? {
        switch self {
        case .noModelProfiles:
            return "The host has no available model profiles."
        case .modelProfileUnavailable(let identifier):
            return "Model profile '\(identifier)' is not available from the host."
        case .missingSkills(let identifiers):
            return "Unknown selected skill(s): \(identifiers.joined(separator: ", "))."
        case .runUnavailable(let runID):
            return "Conversation run '\(runID)' is no longer resumable."
        case .staleApproval(let runID, let stepID):
            return "Approval for run '\(runID)' step '\(stepID)' is no longer current."
        case .unsupportedHostAction(let action):
            return "Conversation runs do not support host action '\(action)'."
        }
    }
}

package actor AgenticConversationSession {
    package private(set) var snapshot: AgenticConversationSnapshot

    private let capabilities: AgentHost.Capabilities
    private let workspace: String
    private let service: any AgentHost.Service
    private let baseSessionID: String
    private var serviceStarted: Bool
    private var stateObservation: Task<Void, Never>?
    private var nextOrdinal: Int
    private var runInputs: [String: String]
    private var runOutputs: [String: String]
    private var settledRunIDs: Set<String>
    private var pendingRunInput: String?
    private var activeRunID: String?
    private var activeRunTitle: String?
    private var liveRunState: AgentRunStateSnapshot?
    private var liveAssistantText: String?

    package init(
        workspace: String,
        service: any AgentHost.Service,
        capabilities: AgentHost.Capabilities,
        sessionID: String? = nil
    ) throws {
        let profiles = capabilities.models

        guard let selectedProfile = profiles.first else {
            throw AgenticConversationSessionError.noModelProfiles
        }

        let skills = capabilities.skills.map { skill in
            AgenticConversationSkillPresentation(
                id: skill.id,
                title: skill.title,
                summary: skill.summary,
                toolNames: skill.toolNames
            )
        }

        self.capabilities = capabilities
        self.workspace = workspace
        self.service = service
        self.baseSessionID = sessionID ?? UUID().uuidString
        self.serviceStarted = false
        self.stateObservation = nil
        self.nextOrdinal = 1
        self.runInputs = [:]
        self.runOutputs = [:]
        self.settledRunIDs = []
        self.pendingRunInput = nil
        self.activeRunID = nil
        self.activeRunTitle = nil
        self.liveRunState = nil
        self.liveAssistantText = nil
        self.snapshot = AgenticConversationSnapshot(
            workspace: workspace,
            activity: "ready",
            models: profiles.map { profile in
                AgenticConversationModelPresentation(
                    id: profile.id,
                    title: profile.title,
                    detail: "\(profile.model) · \(profile.adapterIdentifier.rawValue)",
                    supportsStreaming: profile.supportsStreaming
                )
            },
            selectedModelProfileID: selectedProfile.id,
            selectedResponseDelivery:
                selectedProfile.supportsStreaming
                    ? .stream
                    : .buffered,
            selectedAutonomyMode: .auto_observe,
            skills: skills,
            toolCollections:
                AgenticConversationToolCatalogPresentation.collections(
                    capabilities.tools
                ),
            customToolSelection:
                AgenticConversationToolCatalogPresentation.defaultSelection(
                    capabilities.tools
                ),
            hostConsole: .init(
                context: workspace
            )
        )
    }

    deinit {
        stateObservation?.cancel()
    }

    package func selectModel(
        _ identifier: AgentModelProfileIdentifier
    ) {
        snapshot.selectedModelProfileID = identifier

        if let profile = capabilities.models.first(where: {
            $0.id == identifier
        }), !profile.supportsStreaming {
            snapshot.selectedResponseDelivery = .buffered
        }

        snapshot.activity = "model selected"
    }

    package func selectResponseDelivery(
        _ delivery: AgentModelResponseDelivery
    ) {
        if delivery == .stream,
           let profile = capabilities.models.first(where: {
               $0.id == snapshot.selectedModelProfileID
           }),
           !profile.supportsStreaming
        {
            snapshot.selectedResponseDelivery = .buffered
            snapshot.activity = "streaming unavailable for selected model"
            return
        }

        snapshot.selectedResponseDelivery = delivery
        snapshot.activity = "\(delivery.rawValue) response delivery selected"
    }

    package func selectInvocationOptions(
        _ options: AgentModelInvocationOptions
    ) {
        snapshot.selectedInvocationOptions = options
        snapshot.activity = "invocation options selected"
    }

    package func selectAutonomy(
        _ mode: AutonomyMode
    ) {
        snapshot.selectedAutonomyMode = mode
        snapshot.activity = "\(mode.rawValue) autonomy selected"
    }

    package func selectSkills(
        _ identifiers: [AgentSkillIdentifier]
    ) {
        snapshot.selectedSkillIDs = identifiers
        snapshot.activity = "skills selected"
    }

    package func selectToolExposure(
        _ exposure: AgenticConversationToolExposure
    ) {
        snapshot.selectedToolExposure = exposure
        snapshot.activity = "\(exposure.title.lowercased()) tool exposure selected"
    }

    package func selectCustomToolSelection(
        _ selection: AgenticConversationToolSelection
    ) {
        snapshot.customToolSelection = selection
        snapshot.activity = "custom tool selection changed"
    }

    package func setActivity(_ activity: String) {
        snapshot.activity = activity
    }

    package func setVoiceAvailability(
        _ availability: AgenticConversationVoice.Availability
    ) {
        snapshot.voiceAvailability = availability
    }

    package func setVoiceState(
        _ state: AgenticConversationVoice.State
    ) {
        snapshot.voiceState = state
    }

    package func setVoiceStatus(
        _ status: AgenticConversationVoice.Status?
    ) {
        snapshot.voiceStatus = status
    }

    @discardableResult
    package func submit(
        _ submission: AgenticConversationSubmission
    ) async throws -> AgentRunResult {
        try await ensureServiceStarted()

        selectModel(submission.modelProfileID)
        selectResponseDelivery(submission.responseDelivery)
        selectInvocationOptions(submission.invocationoptions)
        selectAutonomy(submission.autonomyMode)
        selectSkills(submission.skillIDs)
        selectToolExposure(submission.toolExposure)

        if submission.toolExposure == .custom {
            selectCustomToolSelection(
                submission.customToolSelection
            )
        }

        guard let profile = capabilities.models.first(where: {
            $0.id == submission.modelProfileID
        }) else {
            throw AgenticConversationSessionError.modelProfileUnavailable(
                submission.modelProfileID.rawValue
            )
        }

        let selectedSkills = submission.skillIDs.compactMap { identifier in
            capabilities.skills.first(where: {
                $0.id == identifier
            })
        }
        let selectedSkillIDs = Set(
            selectedSkills.map(\.id)
        )
        let missingSkillIDs = submission.skillIDs.filter {
            !selectedSkillIDs.contains($0)
        }

        guard missingSkillIDs.isEmpty else {
            throw AgenticConversationSessionError.missingSkills(
                missingSkillIDs.map(\.rawValue)
            )
        }

        let toolExposure = Self.toolExposurePolicy(
            submission.toolExposure,
            customToolSelection: submission.customToolSelection,
            skills: selectedSkills,
            catalog: capabilities.tools
        )

        let renderedInput = Self.renderedInput(submission)
        let turnOrdinal = nextOrdinal
        let runTitle = "conversation turn \(turnOrdinal)"
        nextOrdinal += 1
        activeRunID = nil
        activeRunTitle = runTitle
        liveRunState = nil
        liveAssistantText = nil
        pendingRunInput = renderedInput

        let userMessage = AgentMessage(
            role: .user,
            text: renderedInput
        )
        snapshot.messages.append(
            .init(
                id: userMessage.id,
                role: .user,
                body: submission.body,
                attachments: submission.contents.map {
                    .content($0)
                }
            )
        )
        snapshot.activity = "invoking \(profile.title)"

        let result = try await service.submit(
            .init(
                session: .init(baseSessionID),
                prompt: renderedInput,
                execution: .init(
                    modelProfileID: profile.id,
                    system: Self.systemPrompt(
                        workspace: workspace,
                        skills: selectedSkills,
                        toolExposure: submission.toolExposure,
                        customToolSelection:
                            submission.customToolSelection
                    ),
                    invocationOptions: submission.invocationoptions,
                    configuration: .init(
                        maximumIterations: 12,
                        autonomyMode: submission.autonomyMode,
                        historyPersistenceMode: .checkpointmutation,
                        toolExposure: toolExposure,
                        responseDelivery: snapshot.selectedResponseDelivery
                    )
                ),
                metadata: [
                    "conversation_session_id": baseSessionID,
                    "model_profile_id": profile.id.rawValue,
                    "conversation_input_origin": submission.origin.rawValue,
                    "conversation_tool_exposure": submission.toolExposure.rawValue,
                    "conversation_response_delivery":
                        snapshot.selectedResponseDelivery.rawValue,
                    "conversation_autonomy_mode": submission.autonomyMode.rawValue,
                ]
            )
        )

        return try await consume(
            result,
            runID: result.sessionID,
            runTitle: runTitle,
            renderedInput: renderedInput
        )
    }

    @discardableResult
    package func resolveHostAction(
        interruptionID: String,
        runID: String,
        stepID: String,
        action: AgenticHostConsoleAction
    ) async throws -> AgentRunResult {
        let decision: ApprovalDecision

        switch action {
        case .approve:
            decision = .approved
        case .deny:
            decision = .denied
        case .skip:
            decision = .skipped
        case .continueRun,
             .stopRun,
             .retry,
             .createFixBranch:
            throw AgenticConversationSessionError.unsupportedHostAction(
                action.rawValue
            )
        }

        guard let interruption = snapshot.hostConsole.interruptions.first(
            where: { candidate in
                candidate.id == interruptionID
                    && candidate.runID == runID
                    && candidate.stepID == stepID
                    && candidate.kind == .approval
                    && candidate.actions.contains(action)
            }
        ) else {
            throw AgenticConversationSessionError.staleApproval(
                runID: runID,
                stepID: stepID
            )
        }
        _ = interruption

        let sessions = try await service.sessions()
        guard let interactionRequest = sessions.first(
            where: { summary in
                summary.id.rawValue == baseSessionID
            }
        )?.interaction,
              interactionRequest.sessionID == runID,
              interactionRequest.kind == .approval,
              interactionRequest.requirement.pendingApproval?.toolCall.id == stepID
        else {
            throw AgenticConversationSessionError.staleApproval(
                runID: runID,
                stepID: stepID
            )
        }

        let runTitle = snapshot.hostConsole.runs.first(
            where: { run in
                run.id == runID
            }
        )?.title ?? runID

        settledRunIDs.remove(runID)
        activeRunID = runID
        activeRunTitle = runTitle
        liveRunState = nil
        liveAssistantText = nil
        snapshot.activity = "applying \(action.title.lowercased())"

        let result = try await service.resume(
            .init(
                request: interactionRequest,
                resolution: .approval(
                    decision
                ),
                metadata: [
                    "conversation_host_action": action.rawValue,
                    "conversation_interruption_id": interruptionID,
                    "conversation_step_id": stepID,
                ]
            )
        )

        return try await consume(
            result,
            runID: runID,
            runTitle: runTitle
        )
    }

    private func consume(
        _ result: AgentRunResult,
        runID: String,
        runTitle: String,
        renderedInput: String? = nil
    ) async throws -> AgentRunResult {
        settledRunIDs.insert(runID)

        let projection = AgenticConversationRunProjection.project(
            result,
            title: runTitle
        )
        refreshRunProjection(
            projection,
            runID: runID
        )

        let responseText = result.response?.message.content.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let body: String
        if let responseText, !responseText.isEmpty {
            body = responseText
        } else if let liveAssistantText, !liveAssistantText.isEmpty {
            body = liveAssistantText
        } else if let failure = result.failure {
            body = failure.message
        } else if result.isAwaitingApproval {
            body = "The run is awaiting approval."
        } else if result.isSuspended {
            body = "The run is suspended."
        } else {
            body = "The run completed without assistant text."
        }

        updateAssistant(
            runID: runID,
            body: body
        )

        let showsRunAttachment =
            !result.toolUses.isEmpty
                || !projection.run.steps.isEmpty
                || !projection.documents.isEmpty
                || !projection.interruptions.isEmpty
                || result.isAwaitingApproval
                || result.isSuspended
                || result.isFailed

        setRunAttachmentVisible(
            showsRunAttachment,
            runID: runID
        )

        if let failure = result.failure {
            snapshot.activity = "run failed"
            upsertFailureStatus(
                runID: runID,
                summary: failure.kind.rawValue,
                body: failure.message
            )
        } else {
            snapshot.activity = result.isCompleted
                ? "response completed"
                : "response suspended"
        }

        liveRunState = nil
        liveAssistantText = nil
        activeRunID = nil
        activeRunTitle = nil
        pendingRunInput = nil

        if let renderedInput {
            runInputs[runID] = renderedInput
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        runOutputs[runID] = String(
            decoding: try encoder.encode(result),
            as: UTF8.self
        )

        return result
    }

    private func ensureServiceStarted() async throws {
        guard !serviceStarted else {
            return
        }

        let sessionID = AgentHost.Session.ID(
            baseSessionID
        )
        _ = try await service.start(
            .init(
                id: sessionID,
                title: "Conversation",
                metadata: [
                    "source": "agentic-command-line",
                    "workspace": workspace,
                ]
            )
        )
        let stream = service.observeState(
            sessionID
        )
        stateObservation = Task { [weak self] in
            do {
                for try await state in stream {
                    guard let self else {
                        return
                    }

                    await self.publish(
                        state
                    )
                }
            } catch is CancellationError {
            } catch {
                guard let self else {
                    return
                }

                await self.recordFailure(
                    error
                )
            }
        }
        serviceStarted = true
    }

    package func recordFailure(_ error: Error) {
        let body = error.localizedDescription
        snapshot.activity = "conversation run failed"

        if let runID = activeRunID {
            settledRunIDs.insert(runID)

            if liveAssistantText?.isEmpty != false {
                updateAssistant(
                    runID: runID,
                    body: body
                )
            }

            upsertRun(
                .init(
                    id: runID,
                    title: activeRunTitle ?? runID,
                    summary: body,
                    state: .failed,
                    steps: snapshot.hostConsole.runs.first(where: {
                        $0.id == runID
                    })?.steps ?? []
                )
            )
            setRunAttachmentVisible(
                true,
                runID: runID
            )
            upsertFailureStatus(
                runID: runID,
                summary: "runtime error",
                body: body
            )
        } else {
            snapshot.messages.append(
                .init(
                    id: UUID().uuidString,
                    role: .assistant,
                    body: body
                )
            )
            snapshot.hostConsole.statuses.append(
                .init(
                    id: UUID().uuidString,
                    kind: .error,
                    title: "Conversation run failed",
                    summary: "runtime error",
                    body: body
                )
            )
        }

        liveRunState = nil
        liveAssistantText = nil
        activeRunID = nil
        activeRunTitle = nil
        pendingRunInput = nil
    }

    package func publish(
        _ state: AgentRunStateSnapshot
    ) async {
        guard !settledRunIDs.contains(state.sessionID) else {
            return
        }

        liveRunState = state
        activeRunID = state.sessionID

        if let pendingRunInput,
           runInputs[state.sessionID] == nil
        {
            runInputs[state.sessionID] = pendingRunInput
        }

        let partialText = state.partialResponse?.message.content.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let responseText = state.lastResponse?.message.content.text
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let partialText, !partialText.isEmpty {
            liveAssistantText = partialText
        } else if let responseText, !responseText.isEmpty {
            liveAssistantText = responseText
        }

        let visibleBody = liveAssistantText
            ?? state.failure?.message
        let projection = AgenticConversationRunProjection.project(
            state,
            title: activeRunTitle ?? state.sessionID
        )

        refreshRunProjection(
            projection,
            runID: state.sessionID
        )

        if let visibleBody,
           !visibleBody.isEmpty
        {
            updateAssistant(
                runID: state.sessionID,
                body: visibleBody
            )
        } else if !snapshot.messages.contains(where: { message in
            message.id == "\(state.sessionID)-assistant"
        }) {
            updateAssistant(
                runID: state.sessionID,
                body: Self.activityTitle(
                    for: state
                )
            )
        }

        let showsRunAttachment =
            !state.toolUses.isEmpty
                || !projection.run.steps.isEmpty
                || !projection.documents.isEmpty
                || !projection.interruptions.isEmpty
                || state.pendingApproval != nil
                || state.pendingUserInput != nil
                || state.suspension != nil
                || state.failure != nil

        setRunAttachmentVisible(
            showsRunAttachment,
            runID: state.sessionID
        )

        if let failure = state.failure {
            upsertFailureStatus(
                runID: state.sessionID,
                summary: failure.kind.rawValue,
                body: failure.message
            )
        }

        snapshot.activity = Self.activityTitle(
            for: state
        )
    }

    package func presentationSnapshot(
        now: Date = Date()
    ) -> AgenticConversationSnapshot {
        var presentation = snapshot

        guard let liveRunState else {
            return presentation
        }

        let elapsedEnd: Date
        switch liveRunState.phase {
        case .ready_for_model,
             .receiving_model_response,
             .processing_tool_calls:
            elapsedEnd = now

        case .suspended,
             .awaiting_approval,
             .interrupted,
             .failed,
             .completed:
            elapsedEnd = liveRunState.updatedAt
        }

        let elapsed = max(
            0,
            elapsedEnd.timeIntervalSince(
                liveRunState.startedAt
            )
        )
        presentation.activity = String(
            format: "%@ · %.1fs",
            Self.activityTitle(
                for: liveRunState
            ),
            elapsed
        )
        return presentation
    }

    private func updateAssistant(
        runID: String,
        body: String
    ) {
        guard let index = snapshot.messages.firstIndex(where: { message in
            message.id == "\(runID)-assistant"
        }) else {
            snapshot.messages.append(
                .init(
                    id: "\(runID)-assistant",
                    role: .assistant,
                    body: body,
                    attachments: []
                )
            )
            return
        }

        snapshot.messages[index].body = body
    }

    private func setRunAttachmentVisible(
        _ visible: Bool,
        runID: String
    ) {
        guard let index = snapshot.messages.firstIndex(where: { message in
            message.id == "\(runID)-assistant"
        }) else {
            return
        }

        let containsRunAttachment =
            snapshot.messages[index].attachments.contains { attachment in
                guard case .run(let attachedRunID) = attachment else {
                    return false
                }

                return attachedRunID == runID
            }

        if visible {
            guard !containsRunAttachment else {
                return
            }

            snapshot.messages[index].attachments.append(
                .run(
                    runID: runID
                )
            )
        } else {
            snapshot.messages[index].attachments.removeAll { attachment in
                guard case .run(let attachedRunID) = attachment else {
                    return false
                }

                return attachedRunID == runID
            }
        }
    }

    private func refreshRunProjection(
        _ projection: AgenticConversationRunProjection,
        runID: String
    ) {
        upsertRun(
            projection.run
        )
        snapshot.hostConsole.documents.removeAll { document in
            document.runID == runID
        }
        snapshot.hostConsole.documents.append(
            contentsOf: projection.documents
        )
        snapshot.hostConsole.interruptions.removeAll { interruption in
            interruption.runID == runID
        }
        snapshot.hostConsole.interruptions.append(
            contentsOf: projection.interruptions
        )
    }

    private func upsertRun(
        _ run: AgenticHostConsoleRunPresentation
    ) {
        if let index = snapshot.hostConsole.runs.firstIndex(where: {
            $0.id == run.id
        }) {
            snapshot.hostConsole.runs[index] = run
        } else {
            snapshot.hostConsole.runs.append(
                run
            )
        }
    }

    private func upsertFailureStatus(
        runID: String,
        summary: String,
        body: String
    ) {
        let id = "\(runID)-failure"
        let status = AgenticHostConsoleStatusPresentation(
            id: id,
            runID: runID,
            kind: .error,
            title: "Conversation run failed",
            summary: summary,
            body: body
        )

        if let index = snapshot.hostConsole.statuses.firstIndex(where: {
            $0.id == id
        }) {
            snapshot.hostConsole.statuses[index] = status
        } else {
            snapshot.hostConsole.statuses.append(
                status
            )
        }
    }

    private static func activityTitle(
        for state: AgentRunStateSnapshot
    ) -> String {
        if state.pendingUserInput != nil {
            return "awaiting user input"
        }

        switch state.phase {
        case .ready_for_model:
            return "invoking model"

        case .receiving_model_response:
            return "streaming"

        case .processing_tool_calls:
            return "processing tools"

        case .suspended:
            return "suspended"

        case .awaiting_approval:
            return "awaiting approval"

        case .interrupted:
            return "interrupted"

        case .failed:
            return "failed"

        case .completed:
            return "completed"
        }
    }

    package func input(for runID: String) -> String? {
        runInputs[runID]
    }

    package func output(for runID: String) -> String? {
        runOutputs[runID]
    }

    private static func toolExposurePolicy(
        _ exposure: AgenticConversationToolExposure,
        customToolSelection: AgenticConversationToolSelection,
        skills: [AgentHost.Capabilities.Skill],
        catalog: AgentHost.Capabilities.ToolCatalog
    ) -> AgentToolExposurePolicy {
        switch exposure {
        case .all:
            return .all

        case .discovery:
            return toolExposurePolicy(
                selectedIdentifiers: catalog.defaultExposedIdentifiers,
                skills: skills,
                dynamicDiscovery: true,
                catalog: catalog
            )

        case .skill_seeded:
            return toolExposurePolicy(
                selectedIdentifiers: [],
                skills: skills,
                dynamicDiscovery: true,
                catalog: catalog
            )

        case .custom:
            return toolExposurePolicy(
                selectedIdentifiers: customToolSelection.identifiers,
                skills: skills,
                dynamicDiscovery: customToolSelection.dynamicDiscovery,
                catalog: catalog
            )
        }
    }

    private static func toolExposurePolicy(
        selectedIdentifiers: [AgentToolIdentifier],
        skills: [AgentHost.Capabilities.Skill],
        dynamicDiscovery: Bool,
        catalog: AgentHost.Capabilities.ToolCatalog
    ) -> AgentToolExposurePolicy {
        let eligibleIdentifiers = Set(
            catalog.modelFacingIdentifiers
        )
        let requiredSkillIdentifiers = skills.flatMap(
            \.requiredToolIdentifiers
        )
        var identifiers = normalizedToolIdentifiers(
            selectedIdentifiers + requiredSkillIdentifiers,
            eligibleIdentifiers: eligibleIdentifiers
        )
        let discoveryIdentifier = FindToolsTool.identifier

        if dynamicDiscovery,
           eligibleIdentifiers.contains(discoveryIdentifier)
        {
            identifiers.append(discoveryIdentifier)

            return .discoverable(
                identifiers
            )
        }

        return .explicit(
            identifiers
        )
    }

    private static func normalizedToolIdentifiers(
        _ identifiers: [AgentToolIdentifier],
        eligibleIdentifiers: Set<AgentToolIdentifier>
    ) -> [AgentToolIdentifier] {
        var seen: Set<AgentToolIdentifier> = []
        var normalized: [AgentToolIdentifier] = []

        for identifier in identifiers {
            guard identifier != FindToolsTool.identifier,
                  eligibleIdentifiers.contains(identifier),
                  seen.insert(identifier).inserted
            else {
                continue
            }

            normalized.append(identifier)
        }

        return normalized
    }

    private static func renderedInput(
        _ submission: AgenticConversationSubmission
    ) -> String {
        var sections = [submission.body]

        for content in submission.contents {
            let heading: String

            switch content.kind {
            case .pasted:
                heading = "Pasted content"

            case .transcribed:
                heading = "Transcribed content"
            }

            sections.append(
                "# \(heading): \(content.title)\n\n\(content.body)"
            )
        }

        return sections.joined(separator: "\n\n")
    }

    private static func systemPrompt(
        workspace: String,
        skills: [AgentHost.Capabilities.Skill],
        toolExposure: AgenticConversationToolExposure,
        customToolSelection: AgenticConversationToolSelection
    ) -> String {
        var sections = [
            "You are operating in an Agentic terminal conversation.",
            "Workspace root: \(workspace)",
            "Use only the advertised tools and keep all file operations inside the workspace.",
        ]

        if !skills.isEmpty {
            sections.append(
                skills.map(\.contextText).joined(separator: "\n\n")
            )
        }

        switch toolExposure {
        case .discovery:
            sections.append(
                "Default application tools and required tools from selected skills are exposed immediately. Use find_tools to discover additional registered capabilities."
            )

        case .all:
            sections.append(
                "All registered model-facing tools are exposed immediately."
            )

        case .skill_seeded:
            if skills.isEmpty {
                sections.append(
                    "No required skill tools are currently seeded. Use find_tools to discover registered capabilities."
                )
            } else {
                sections.append(
                    "Required tools from selected skills are exposed immediately. Use find_tools to discover additional registered capabilities."
                )
            }

        case .custom:
            if customToolSelection.dynamicDiscovery {
                sections.append(
                    "Custom selected tools and required tools from selected skills are exposed immediately. Use find_tools to discover additional registered capabilities."
                )
            } else {
                sections.append(
                    "Only custom selected tools and required tools from selected skills are exposed. Dynamic tool discovery is disabled."
                )
            }
        }

        return sections.joined(separator: "\n\n")
    }
}