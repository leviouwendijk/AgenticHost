import Agentic
import AgenticConfiguration
import AgenticHarness
import AgenticHost
import AgenticInterfaces
import AgenticModels
import AgenticRuntime
import AgenticStandard
import Foundation
import Reporting
import Primitives
import Terminal
import Version
import Workspace
import Writers

package enum AgenticConversationSessionError: Error, LocalizedError {
    case noModelProfiles
    case modelProfileUnavailable(String)
    case programUnavailable(String)
    case missingInstructions([String])
    case runUnavailable(String)
    case staleApproval(runID: String, stepID: String)
    case staleWorkspaceAccess(runID: String, stepID: String)
    case staleRunLimit(runID: String, stepID: String)
    case staleUserInput(runID: String, interactionID: String)
    case invalidProgramSuspension(String)
    case unsupportedHostAction(String)

    package var errorDescription: String? {
        switch self {
        case .noModelProfiles:
            return "The host has no available model profiles."
        case .modelProfileUnavailable(let identifier):
            return "Model profile '\(identifier)' is not available from the host."
        case .programUnavailable(let identifier):
            return "Program '\(identifier)' is not available from the host."
        case .missingInstructions(let identifiers):
            return "Unknown selected instruction(s): \(identifiers.joined(separator: ", "))."
        case .runUnavailable(let runID):
            return "Conversation run '\(runID)' is no longer resumable."
        case .staleApproval(let runID, let stepID):
            return "Approval for run '\(runID)' step '\(stepID)' is no longer current."
        case .staleWorkspaceAccess(let runID, let stepID):
            return "Workspace access for run '\(runID)' step '\(stepID)' is no longer current."
        case .staleRunLimit(let runID, let stepID):
            return "Run-limit interaction for run '\(runID)' step '\(stepID)' is no longer current."
        case .staleUserInput(let runID, let interactionID):
            return "User input for run '\(runID)' interaction '\(interactionID)' is no longer current."
        case .invalidProgramSuspension(let program):
            return "Program '\(program)' suspended without a usable conversation interaction."
        case .unsupportedHostAction(let action):
            return "Conversation runs do not support host action '\(action)'."
        }
    }
}

private struct AgenticConversationSuspendedProgram:
    Sendable
{
    let descriptor: ProgramDefinition
    let request: Run.Interaction.Request
    let messageID: String
    let attachmentID: String
}

package actor AgenticConversationSession {
    package private(set) var snapshot: AgenticConversationSnapshot

    private let capabilities: AgentHost.Capabilities
    private let primaryAgent: AgentRealization?
    private let workspace: String
    /// Follows `:cd`; the command line completes paths against it.
    package nonisolated let workingDirectory: AgenticWorkingDirectory
    /// The `PathScope` bindings of settings.frame, read when used.
    package nonisolated let pathScopes: @Sendable () throws -> [String: PathScope]
    /// Read at each `:export`, so a changed `settings.frame` applies at once.
    package nonisolated let exports: @Sendable () throws -> AgenticSettings.Exports
    private var requestedInterruption: Run.Interruption.Mode?
    // `:` commands issued during each run, for its card.
    /// The first operator trace entry no command has claimed yet.
    private var traceIndex = 0
    /// The last opening shown; a run opening the same way is not news.
    private var shownOpening: [String]?
    private var commandsByRunID: [String: [String]] = [:]
    private let service: any AgentHost.Service
    private let baseSessionID: String
    private var serviceStarted: Bool
    private var stateObservation: Task<Void, Never>?
    private var nextOrdinal: Int
    private var submissionGeneration = 0
    /// Messages that were not sent, waiting to go back to the composer.
    private var unsent: [AgenticConversationSubmission] = []
    private var runInputs: [String: String]
    private var runOutputs: [String: String]
    private var settledRunIDs: Set<String>
    private var pendingRunInput: String?
    private var pending_interruption: (mode: Run.Interruption.Mode, reason: String?)?
    private var stop_requested: Bool
    private var program_in_flight: Bool
    private var activeRunID: String?
    private var activeRunTitle: String?
    private var liveRunState: AgentRunStateSnapshot?
    private var liveAssistantText: String?
    /// Each run's last known delegation tree; it outlives the Host's
    /// delegation, which an abandoned run drops.
    private var agentsByRunID: [String: [AgenticHostConsoleAgentPresentation]] = [:]
    private var suspendedProgramsByRunID:
        [String: AgenticConversationSuspendedProgram]
    private var suspendedUserInputRequestsByRunID:
        [String: Run.Interaction.Request]

    package init(
        workspace: String,
        service: any AgentHost.Service,
        capabilities: AgentHost.Capabilities,
        sessionID: String? = nil,
        primaryAgent: AgentRealization? = nil,
        pathScopes: @escaping @Sendable () throws -> [String: PathScope] = {
            try AgentHomeLocator().resolveHome().pathScopes()
        },
        exports: @escaping @Sendable () throws -> AgenticSettings.Exports = {
            try AgentHomeLocator().resolveHome().settings().exports
        },
        notices: [String] = AgenticConversationSession.settingsNotices(
            AgentHomeLocator().resolveHome()
        )
    ) async throws {
        let profiles = capabilities.models
        guard !profiles.isEmpty else {
            throw AgenticConversationSessionError.noModelProfiles
        }
        let initialRoute = try await service.resolveModel(
            for: primaryAgent?.identifier
        )
        let preferredProfile = initialRoute.route.profile

        let instructions = capabilities.instructions.map { instruction in
            AgenticConversationInstructionPresentation(
                id: instruction.identifier,
                title: instruction.identifier.rawValue,
                summary: instruction.content
            )
        }

        self.capabilities = capabilities
        self.primaryAgent = primaryAgent
        self.workspace = workspace
        self.workingDirectory = AgenticWorkingDirectory(workspace)
        self.pathScopes = pathScopes
        self.exports = exports
        self.service = service
        self.baseSessionID = sessionID ?? UUID().uuidString
        self.serviceStarted = false
        self.stateObservation = nil
        self.nextOrdinal = 1
        self.runInputs = [:]
        self.runOutputs = [:]
        self.settledRunIDs = []
        self.pendingRunInput = nil
        self.pending_interruption = nil
        self.stop_requested = false
        self.program_in_flight = false
        self.activeRunID = nil
        self.activeRunTitle = nil
        self.liveRunState = nil
        self.liveAssistantText = nil
        self.suspendedProgramsByRunID = [:]
        self.suspendedUserInputRequestsByRunID = [:]
        self.snapshot = AgenticConversationSnapshot(
            workspace: workspace,
            activity: "ready",
            models: profiles.map { profile in
                // Configured and eligible for this agent's role and
                // requirements, or why not.
                let agentSelection = primaryAgent?.definition.modelSelection
                let rejection = profile.unavailability.map(Self.unconfiguredReason)
                    ?? profile.profile?.rejection(for: .init(
                        purpose: agentSelection?.purpose ?? .executor,
                        requirements: agentSelection?.requirements ?? .init()
                    ))
                return AgenticConversationModelPresentation(
                    id: profile.id,
                    title: profile.title,
                    detail: "\(profile.model) · \(profile.gatewayIdentifier.rawValue)",
                    isAvailable: rejection == nil,
                    supportsStreaming: profile.supportsStreaming,
                    tier: profile.profile?.tier?.rawValue,
                    provider: profile.gatewayIdentifier.rawValue,
                    unavailableReason: rejection,
                    isConfigured: profile.unavailability == nil
                )
            },
            programs: capabilities.programs,
            preferredModelProfileID: preferredProfile.identifier,
            selectedResponseDelivery:
                preferredProfile.capabilities.contains(.streaming)
                    ? .stream
                    : .buffered,
            selectedAutonomyMode: .auto_observe,
            instructions: instructions,
            capabilityEntries: capabilities.catalogEntries.map { item in
                let kind: AgenticConversationCapabilityEntry.Kind
                switch item.kind {
                case .tool: kind = .tool
                case .program: kind = .program
                case .inference: kind = .inference
                case .agent: kind = .agent
                case .instruction: kind = .instruction
                }
                return AgenticConversationCapabilityEntry(
                    kind: kind,
                    identifier: item.identifier,
                    namespace: item.namespace,
                    title: item.title,
                    summary: item.summary
                )
            },
            availableCapabilities:
                (primaryAgent?.available
                 ?? capabilities.defaultExecution.availableCapabilities
                 ?? capabilities.installedCapabilities).intersecting(capabilities.installedCapabilities),
            visibleCapabilities:
                (primaryAgent?.visible
                 ?? capabilities.defaultExecution.visibleCapabilities
                 ?? capabilities.defaultExecution.availableCapabilities
                 ?? capabilities.installedCapabilities).intersecting(
                    primaryAgent?.available
                    ?? capabilities.defaultExecution.availableCapabilities
                    ?? capabilities.installedCapabilities
                ),
            hostConsole: .init(
                context: workspace
            )
        )
        self.snapshot.notices = notices
    }

    /// How `settings.frame`'s declared schema compares with this
    /// program's, as a header notice. Reads only.
    package static func settingsNotices(
        _ home: AgentHome
    ) -> [String] {
        let current = AgenticSettings.schemaVersion
        let line = ".schema = .{ .major = \(current.major), .minor = \(current.minor), .patch = \(current.patch) }"
        guard let standing = try? home.settingsSchemaStanding() else {
            return []
        }
        switch standing {
        case .missing, .current:
            return []
        case .undeclared:
            return ["settings.frame declares no schema; add \(line) to settings"]
        case .older(let declared):
            return ["settings.frame is schema \(text(declared)), read as is; \(text(current)) has new settings (agentic settings-modernize shows them)"]
        case .incompatible(let declared):
            return ["settings.frame is schema \(text(declared)); this agentic reads \(text(current)), so settings may be read differently: agentic settings-modernize"]
        case .newer(let declared):
            return ["settings.frame is schema \(text(declared)), newer than this agentic (\(text(current))); update agentic"]
        }
    }

    private static func text(_ version: SemanticVersion) -> String {
        "\(version.major).\(version.minor).\(version.patch)"
    }

    deinit {
        stateObservation?.cancel()
    }

    package func preferModel(
        _ identifier: AgentModelProfileIdentifier
    ) {
        snapshot.preferredModelProfileID = identifier

        if let profile = capabilities.models.first(where: {
            $0.id == identifier
        }), !profile.supportsStreaming {
            snapshot.selectedResponseDelivery = .buffered
        }

        snapshot.activity = "model preference changed"
    }

    package func selectResponseDelivery(
        _ delivery: AgentModelResponseDelivery
    ) {
        if delivery == .stream,
           let profile = capabilities.models.first(where: {
               $0.id == snapshot.preferredModelProfileID
           }),
           !profile.supportsStreaming
        {
            snapshot.selectedResponseDelivery = .buffered
            snapshot.activity = "streaming unavailable for preferred model"
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

    package func selectInstructions(
        _ identifiers: [InstructionIdentifier]
    ) {
        snapshot.selectedInstructionIDs = identifiers
        snapshot.activity = "instructions selected"
    }

    /// Apply a trusted user selection against the application's installed
    /// capabilities, independently of the Agent's authored initial defaults.
    package func selectCapabilities(available: AgentCapabilitySet, visible: AgentCapabilitySet) {
        let permitted = available.intersecting(capabilities.installedCapabilities)
        snapshot.availableCapabilities = permitted
        snapshot.visibleCapabilities = visible.intersecting(permitted)
        snapshot.activity = "capability selection changed"
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
        _ submission: AgenticConversationSubmission,
        existingRunPolicy:
            AgentHost.Session.Submission.ExistingRunPolicy = .reject
    ) async throws -> AgentExecutor.Result {
        do {
            try await ensureServiceStarted()
        } catch {
            returnUnsent(submission, reason: error.localizedDescription)
            throw error
        }

        preferModel(submission.preferredModelProfileID)
        selectResponseDelivery(submission.responseDelivery)
        selectInvocationOptions(submission.invocationoptions)
        selectAutonomy(submission.autonomyMode)
        selectInstructions(submission.instructionIDs)
        selectCapabilities(
            available: submission.availableCapabilities,
            visible: submission.visibleCapabilities
        )

        guard let profile = capabilities.models.first(where: {
            $0.id == submission.preferredModelProfileID
        }) else {
            let error = AgenticConversationSessionError.modelProfileUnavailable(
                submission.preferredModelProfileID.rawValue
            )
            returnUnsent(submission, reason: error.localizedDescription)
            throw error
        }

        let selectedInstructions = submission.instructionIDs.compactMap { identifier in
            capabilities.instructions.first(where: {
                $0.identifier == identifier
            })
        }
        let foundIDs = Set(selectedInstructions.map(\.identifier))
        let missingIDs = submission.instructionIDs.filter {
            !foundIDs.contains($0)
        }
        guard missingIDs.isEmpty else {
            let error = AgenticConversationSessionError.missingInstructions(
                missingIDs.map(\.rawValue)
            )
            returnUnsent(submission, reason: error.localizedDescription)
            throw error
        }

        // selectCapabilities has already bounded the trusted selection by
        // the installed universe and preserved visible <= available.
        let available = snapshot.availableCapabilities
        let visible = snapshot.visibleCapabilities

        let renderedInput = Self.renderedInput(submission)
        let baseInstructions = primaryAgent == nil
            ? capabilities.defaultExecution.instructions
            : primaryAgent?.instructionSnapshot
        let authoredInstructions = Self.systemInstructions(
            workspace: workspace,
            instructions: selectedInstructions,
            base: baseInstructions
        )
        let turnOrdinal = nextOrdinal
        let runTitle = "conversation turn \(turnOrdinal)"
        nextOrdinal += 1
        submissionGeneration += 1
        let generation = submissionGeneration
        activeRunID = nil
        activeRunTitle = runTitle
        liveRunState = nil
        liveAssistantText = nil
        pendingRunInput = renderedInput

        let userMessage = Message(
            id: submission.id,
            role: .user,
            content: .init(text: renderedInput)
        )
        // A queued message is already in the transcript; it stops pending.
        snapshot.messages.removeAll { $0.id == userMessage.id }
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

        let result: AgentExecutor.Result
        do {
            result = try await service.submit(
            .init(
                session: .init(baseSessionID),
                prompt: renderedInput,
                execution: .init(
                    modelSelection: .init(
                        // The picked profile is a preference; the purpose
                        // stays the agent's, or the resolver refuses.
                        purpose: primaryAgent?.definition.modelSelection.purpose ?? .executor,
                        preferences: .init(
                            preferredProfileIdentifier: profile.id
                        )
                    ),
                    system: authoredInstructions.content,
                    instructions: authoredInstructions,
                    invocationOptions: submission.invocationoptions,
                    availableCapabilities: available,
                    visibleCapabilities: visible,
                    configuration: .init(
                        runLimits: .init(iterations: 12),
                        contextMode: .dynamic,
                        contextPolicy: .conversation,
                        autonomyMode: submission.autonomyMode,
                        historyPersistenceMode: .checkpointmutation,
                        responseDelivery: snapshot.selectedResponseDelivery
                    )
                ),
                existingRunPolicy: existingRunPolicy,
                metadata: [
                    "conversation_session_id": baseSessionID,
                    "model_profile_id": profile.id.rawValue,
                    "conversation_input_origin": submission.origin.rawValue,
                    "conversation_response_delivery":
                        snapshot.selectedResponseDelivery.rawValue,
                    "conversation_autonomy_mode": submission.autonomyMode.rawValue,
                ]
            )
        )
        } catch {
            snapshot.messages.removeAll { $0.id == userMessage.id }
            // A message superseded by a newer one is not given back: the
            // newer message is what the operator meant to send.
            if generation == submissionGeneration {
                returnUnsent(submission, reason: error.localizedDescription)
            }
            throw error
        }

        let consumed = try await consume(
            result,
            runID: result.sessionID,
            runTitle: runTitle,
            renderedInput: renderedInput,
            submissionGeneration: generation
        )

        if case .supersede(let expectedRunID) = existingRunPolicy,
           let expectedRunID {
            reconcileInterruptedRun(
                runID: expectedRunID
            )
        }

        return consumed
    }

    @discardableResult
    package func invokeProgram(
        _ invocation: AgenticConversationProgramInvocation,
        submission: AgenticConversationSubmission
    ) async throws -> ProgramExecutionRecord {
        try await ensureServiceStarted()

        guard let descriptor = capabilities.programs.first(where: {
            $0.identifier == invocation.program
        }) else {
            throw AgenticConversationSessionError.programUnavailable(
                invocation.program.rawValue
            )
        }

        snapshot.messages.append(
            AgenticConversationMessagePresentation(
                id: UUID().uuidString,
                role: .user,
                body: submission.body,
                attachments: submission.contents.map {
                    .content($0)
                }
            )
        )
        snapshot.activity = "invoking \(descriptor.title ?? descriptor.identifier.rawValue)"
        program_in_flight = true
        defer { program_in_flight = false }

        let record = try await service.invokeProgram(
            .init(
                program: invocation.program,
                input: invocation.input,
                autonomyMode: submission.autonomyMode,
                metadata: [
                    "conversation_session_id": baseSessionID,
                    "conversation_surface": "direct_program",
                ]
            )
        )
        let messageID = UUID().uuidString
        let attachmentID = UUID().uuidString

        try consumeProgram(
            record,
            descriptor: descriptor,
            messageID: messageID,
            attachmentID: attachmentID
        )

        return record
    }

    package func interruptRun(
        runID: String? = nil,
        mode: Run.Interruption.Mode,
        reason: String? = nil
    ) async throws {
        stop_requested = true
        requestedInterruption = mode
        snapshot.activity = mode == .urgent
            ? "Stop requested · finishing active effect if necessary, then stopping"
            : "Stop requested · finishing current iteration, then stopping"

        // Direct Programs do not publish AgentRunStateSnapshot. The Host
        // routes this request to the active Program control by conversation.
        if program_in_flight {
            try await service.interrupt(
                .init(
                    session: .init(baseSessionID),
                    runID: nil,
                    mode: mode,
                    reason: reason
                )
            )
            return
        }

        // An input can arrive before the provider establishes a run ID.
        // Keep the request and issue it on the first live state publication.
        let targetRunID = runID ?? activeRunID
        guard let targetRunID else {
            pending_interruption = (mode: mode, reason: reason)
            return
        }

        try await service.interrupt(
            .init(
                session: .init(baseSessionID),
                runID: targetRunID,
                mode: mode,
                reason: reason
            )
        )
    }

    package func resolveConversationAction(
        interruptionID: String,
        runID: String,
        stepID: String,
        action: AgenticHostConsoleAction
    ) async throws {
        if interruptionID.hasPrefix(Self.stagedReviewPrefix) {
            try await resolveStagedReview(id: interruptionID, runID: runID, action: action)
            return
        }
        guard let suspended = suspendedProgramsByRunID[
            runID
        ] else {
            _ = try await resolveHostAction(
                interruptionID: interruptionID,
                runID: runID,
                stepID: stepID,
                action: action
            )
            return
        }

        let decision: ApprovalDecision
        switch action {
        case .approve:
            decision = .approved
        case .deny:
            decision = .denied
        case .skip:
            decision = .skipped
        case .grant_for_turn,
             .grant_for_session,
             .continue_run,
             .stop_run,
             .retry,
             .create_fix_branch,
             .run_limit_continue,
             .run_limit_unlimited,
             .run_limit_stop,
             .compact_and_continue,
             .publish,
             .discard,
             .keep,
             .roll_back:
            throw AgenticConversationSessionError.unsupportedHostAction(
                action.id
            )
        }

        guard suspended.request.id == interruptionID,
              suspended.request.sessionID == runID,
              suspended.request.kind == .approval,
              suspended.request.requirement.pendingApproval?.functionCall.id
                == stepID,
              snapshot.hostConsole.interruptions.contains(
                where: { interruption in
                    interruption.id == interruptionID
                        && interruption.runID == runID
                        && interruption.stepID == stepID
                        && interruption.kind == .approval
                        && interruption.actions.contains(action)
                }
              )
        else {
            throw AgenticConversationSessionError.staleApproval(
                runID: runID,
                stepID: stepID
            )
        }

        snapshot.activity = "applying \(action.title.lowercased())"

        let record = try await service.resumeProgram(
            .init(
                request: suspended.request,
                resolution: .approval(decision),
                metadata: [
                    "conversation_host_action": action.id,
                    "conversation_interruption_id": interruptionID,
                    "conversation_step_id": stepID,
                    "conversation_surface": "direct_program",
                ]
            )
        )

        try consumeProgram(
            record,
            descriptor: suspended.descriptor,
            messageID: suspended.messageID,
            attachmentID: suspended.attachmentID
        )
    }

    package func resolveUserInput(
        interactionID: String,
        runID: String,
        reply: UserInputReply
    ) async throws {
        if let suspended = suspendedProgramsByRunID[runID] {
            guard suspended.request.id == interactionID,
                  suspended.request.sessionID == runID,
                  suspended.request.kind == .user_input,
                  suspended.request.requirement.pendingUserInput != nil,
                  snapshot.pendingUserInput?.interactionID == interactionID,
                  snapshot.pendingUserInput?.runID == runID
            else {
                throw AgenticConversationSessionError.staleUserInput(
                    runID: runID,
                    interactionID: interactionID
                )
            }

            // Answered: the Program runs on; the question must not linger
            // until it finishes.
            let question = snapshot.pendingUserInput
            snapshot.pendingUserInput = nil
            markResumed(runID: runID)
            snapshot.activity = "running"

            let record: ProgramExecutionRecord
            do {
                record = try await service.resumeProgram(
                    .init(
                        request: suspended.request,
                        resolution: .user_input(reply),
                        metadata: [
                            "conversation_interaction_id": interactionID,
                            "conversation_surface": "direct_program",
                            "conversation_user_input": "submitted",
                        ]
                    )
                )
            } catch {
                snapshot.pendingUserInput = question
                snapshot.activity = "user input not submitted: \(error.localizedDescription)"
                throw error
            }

            try consumeProgram(
                record,
                descriptor: suspended.descriptor,
                messageID: suspended.messageID,
                attachmentID: suspended.attachmentID
            )
            return
        }

        guard let request = suspendedUserInputRequestsByRunID[runID],
              request.id == interactionID,
              request.sessionID == runID,
              request.kind == .user_input,
              request.requirement.pendingUserInput != nil,
              snapshot.pendingUserInput?.interactionID == interactionID,
              snapshot.pendingUserInput?.runID == runID
        else {
            throw AgenticConversationSessionError.staleUserInput(
                runID: runID,
                interactionID: interactionID
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
        // Answered: the run continues now, and resume returns only when it
        // next settles, so the question must not wait for that.
        clearPendingUserInput(runID: runID)
        markResumed(runID: runID)
        snapshot.activity = "running"
        let generation = submissionGeneration

        let result: AgentExecutor.Result
        do {
            result = try await service.resume(
                .init(
                    request: request,
                    resolution: .user_input(reply),
                    metadata: [
                        "conversation_interaction_id": interactionID,
                        "conversation_user_input": "submitted",
                    ]
                )
            )
        } catch {
            if let pending = request.requirement.pendingUserInput {
                retainUserInput(request: request, pendingUserInput: pending)
            }
            snapshot.activity = "user input not submitted: \(error.localizedDescription)"
            throw error
        }

        _ = try await consume(
            result,
            runID: runID,
            runTitle: runTitle,
            submissionGeneration: generation
        )
    }

    @discardableResult
    package func resolveHostAction(
        interruptionID: String,
        runID: String,
        stepID: String,
        action: AgenticHostConsoleAction
    ) async throws -> AgentExecutor.Result {
        guard let interruption = snapshot.hostConsole.interruptions.first(
            where: { candidate in
                candidate.id == interruptionID
                    && candidate.runID == runID
                    && candidate.stepID == stepID
                    && candidate.actions.contains(action)
            }
        ) else {
            switch action {
            case .grant_for_turn,
                 .grant_for_session:
                throw AgenticConversationSessionError.staleWorkspaceAccess(
                    runID: runID,
                    stepID: stepID
                )

            case .run_limit_continue,
                 .run_limit_unlimited,
                 .run_limit_stop:
                throw AgenticConversationSessionError.staleRunLimit(
                    runID: runID,
                    stepID: stepID
                )

            default:
                throw AgenticConversationSessionError.staleApproval(
                    runID: runID,
                    stepID: stepID
                )
            }
        }

        let sessions = try await service.sessions()
        guard let interactionRequest = sessions.first(
            where: { summary in
                summary.id.rawValue == baseSessionID
            }
        )?.interaction,
              interactionRequest.sessionID == runID
        else {
            switch interruption.kind {
            case .workspace_access:
                throw AgenticConversationSessionError.staleWorkspaceAccess(
                    runID: runID,
                    stepID: stepID
                )

            case .run_limit:
                throw AgenticConversationSessionError.staleRunLimit(
                    runID: runID,
                    stepID: stepID
                )

            case .approval,
                 .recovery,
                 .publication:
                throw AgenticConversationSessionError.staleApproval(
                    runID: runID,
                    stepID: stepID
                )
            }
        }

        let resolution: Run.Interaction.Resolution

        switch interruption.kind {
        case .approval:
            guard interactionRequest.kind == .approval,
                  interactionRequest.requirement.pendingApproval?.functionCall.id == stepID
            else {
                throw AgenticConversationSessionError.staleApproval(
                    runID: runID,
                    stepID: stepID
                )
            }

            switch action {
            case .approve:
                resolution = .approval(
                    .approved
                )

            case .deny:
                resolution = .approval(
                    .denied
                )

            case .skip:
                resolution = .approval(
                    .skipped
                )

            case .grant_for_turn,
                 .grant_for_session,
                 .continue_run,
                 .stop_run,
                 .retry,
                 .create_fix_branch,
                 .run_limit_continue,
                 .run_limit_unlimited,
                 .run_limit_stop,
                 .compact_and_continue,
                 .publish,
                 .discard,
                 .keep,
                 .roll_back:
                throw AgenticConversationSessionError.unsupportedHostAction(
                    action.id
                )
            }

        case .workspace_access:
            guard interactionRequest.id == interruptionID,
                  interactionRequest.kind == .workspace_access,
                  case .workspace_access = interactionRequest.requirement
            else {
                throw AgenticConversationSessionError.staleWorkspaceAccess(
                    runID: runID,
                    stepID: stepID
                )
            }

            switch action {
            case .grant_for_turn:
                resolution = .workspace_access(
                    .grant_for_turn
                )

            case .grant_for_session:
                resolution = .workspace_access(
                    .grant_for_session
                )

            case .deny:
                resolution = .workspace_access(
                    .deny
                )

            case .approve,
                 .skip,
                 .continue_run,
                 .stop_run,
                 .retry,
                 .create_fix_branch,
                 .run_limit_continue,
                 .run_limit_unlimited,
                 .run_limit_stop,
                 .compact_and_continue,
                 .publish,
                 .discard,
                 .keep,
                 .roll_back:
                throw AgenticConversationSessionError.unsupportedHostAction(
                    action.id
                )
            }

        case .run_limit:
            guard interactionRequest.id == interruptionID,
                  interactionRequest.kind == .run_limit,
                  case .run_limit = interactionRequest.requirement
            else {
                throw AgenticConversationSessionError.staleRunLimit(
                    runID: runID,
                    stepID: stepID
                )
            }

            switch action {
            case .run_limit_continue(let iterations):
                resolution = .run_limit(
                    .continue_with(
                        .init(
                            iterations: iterations
                        )
                    )
                )

            case .run_limit_unlimited:
                resolution = .run_limit(
                    .continue_with(
                        .unlimited
                    )
                )

            case .compact_and_continue:
                // A context pause: compact first, then continue the same
                // checkpoint; the next request applies the pointers.
                let compacted = try await service.compact(.init(baseSessionID))
                if let compaction = compacted.compaction {
                    recordChange(AgenticConversationChangeProjection.compaction(compaction))
                }
                resolution = .run_limit(
                    .continue_with(
                        .default
                    )
                )

            case .run_limit_stop:
                resolution = .run_limit(
                    .stop
                )

            case .approve,
                 .deny,
                 .skip,
                 .grant_for_turn,
                 .grant_for_session,
                 .continue_run,
                 .stop_run,
                 .retry,
                 .create_fix_branch,
                 .publish,
                 .discard,
                 .keep,
                 .roll_back:
                throw AgenticConversationSessionError.unsupportedHostAction(
                    action.id
                )
            }

        case .recovery,
             .publication:
            throw AgenticConversationSessionError.unsupportedHostAction(
                action.id
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
        markResumed(runID: runID)
        let generation = submissionGeneration

        let result = try await service.resume(
            .init(
                request: interactionRequest,
                resolution: resolution,
                metadata: [
                    "conversation_host_action": action.id,
                    "conversation_interruption_id": interruptionID,
                    "conversation_step_id": stepID,
                ]
            )
        )

        return try await consume(
            result,
            runID: runID,
            runTitle: runTitle,
            submissionGeneration: generation
        )
    }

    private func consumeProgram(
        _ record: ProgramExecutionRecord,
        descriptor: ProgramDefinition,
        messageID: String,
        attachmentID: String
    ) throws {
        pending_interruption = nil
        let presentation = AgenticConversationProgramProjection.project(
            record,
            descriptor: descriptor,
            id: attachmentID
        )
        let body: String
        var attachments: [AgenticConversationAttachmentPresentation] = [
            .program(presentation),
        ]

        switch record.outcome {
        case .succeeded:
            body = "\(descriptor.title ?? descriptor.identifier.rawValue) completed."
            snapshot.activity = "program completed"
            clearProgramRun(record.sessionID)

        case .failed:
            body = record.failure?.message
                ?? "\(descriptor.title ?? descriptor.identifier.rawValue) failed."
            snapshot.activity = "program failed"
            clearProgramRun(record.sessionID)

        case .interrupted:
            body = "\(descriptor.title ?? descriptor.identifier.rawValue) interrupted."
            snapshot.activity = "program interrupted"
            stop_requested = false
            clearProgramRun(record.sessionID)

        case .suspended:
            guard let runID = record.sessionID,
                  let request = record.interactionRequest
            else {
                throw AgenticConversationSessionError
                    .invalidProgramSuspension(
                        descriptor.identifier.rawValue
                    )
            }

            attachments.append(
                .run(runID: runID)
            )
            suspendedProgramsByRunID[runID] = .init(
                descriptor: descriptor,
                request: request,
                messageID: messageID,
                attachmentID: attachmentID
            )

            switch request.kind {
            case .approval:
                guard let pendingApproval = request.requirement.pendingApproval else {
                    throw AgenticConversationSessionError
                        .invalidProgramSuspension(
                            descriptor.identifier.rawValue
                        )
                }

                clearPendingUserInput(
                    runID: runID
                )
                body = "\(descriptor.title ?? descriptor.identifier.rawValue) is awaiting approval."
                snapshot.activity = "program awaiting approval"
                refreshProgramRun(
                    record,
                    descriptor: descriptor,
                    request: request,
                    pendingApproval: pendingApproval
                )

            case .user_input:
                guard let pendingUserInput = request.requirement.pendingUserInput else {
                    throw AgenticConversationSessionError
                        .invalidProgramSuspension(
                            descriptor.identifier.rawValue
                        )
                }

                body = "\(descriptor.title ?? descriptor.identifier.rawValue) is awaiting user input."
                snapshot.activity = "program awaiting user input"
                presentUserInput(
                    request: request,
                    pendingUserInput: pendingUserInput
                )
                refreshProgramUserInputRun(
                    record,
                    descriptor: descriptor,
                    pendingUserInput: pendingUserInput
                )

            case .workspace_access,
                 .run_limit:
                throw AgenticConversationSessionError
                    .invalidProgramSuspension(
                        descriptor.identifier.rawValue
                    )
            }
        }

        let message = AgenticConversationMessagePresentation(
            id: messageID,
            role: .assistant,
            body: body,
            attachments: attachments
        )

        if let index = snapshot.messages.firstIndex(
            where: { message in
                message.id == messageID
            }
        ) {
            snapshot.messages[index] = message
        } else {
            snapshot.messages.append(message)
        }
    }

    private func refreshProgramRun(
        _ record: ProgramExecutionRecord,
        descriptor: ProgramDefinition,
        request: Run.Interaction.Request,
        pendingApproval: PendingApproval
    ) {
        guard let runID = record.sessionID else {
            return
        }

        let stepID = pendingApproval.functionCall.id
        let steps = record.steps.map { step in
            let state: AgenticHostConsoleStepState
            if step.failure != nil {
                state = .failed
            } else if step.suspension != nil {
                state = .pending
            } else {
                state = .completed
            }

            return AgenticHostConsoleStepPresentation(
                id: step.suspension?.reason.pendingApproval?.functionCall.id
                    ?? "program-step-\(step.index)",
                title: programStepTitle(step),
                detail: step.failure?.message,
                state: state
            )
        }

        snapshot.hostConsole.runs.removeAll { run in
            run.id == runID
        }
        snapshot.hostConsole.runs.append(
            .init(
                id: runID,
                title: descriptor.title ?? descriptor.identifier.rawValue,
                summary: pendingApproval.preflight.summary,
                state: .awaitingApproval,
                steps: steps
            )
        )

        snapshot.hostConsole.interruptions.removeAll { interruption in
            interruption.runID == runID
        }
        snapshot.hostConsole.interruptions.append(
            .init(
                id: request.id,
                runID: runID,
                stepID: stepID,
                kind: .approval,
                title: "Approval",
                summary: pendingApproval.preflight.summary,
                actions: [
                    .approve,
                    .deny,
                    .skip,
                ]
            )
        )

        snapshot.hostConsole.documents.removeAll { document in
            document.runID == runID
        }
        snapshot.hostConsole.documents.append(
            .init(
                id: "\(request.id)-details",
                runID: runID,
                stepID: stepID,
                kind: .details,
                title: "Staged intent details",
                body: [
                    "tool     \(pendingApproval.functionCall.name)",
                    "risk     \(pendingApproval.preflight.risk.rawValue)",
                    "summary  \(pendingApproval.preflight.summary)",
                ].joined(separator: "\n")
            )
        )

        if let preview = HostPreviewDocument.make(
            pendingApproval.preflight.preview,
            id: "\(request.id)-preview",
            runID: runID,
            stepID: stepID
        ) {
            snapshot.hostConsole.documents.append(preview)
        }
    }

    private func refreshProgramUserInputRun(
        _ record: ProgramExecutionRecord,
        descriptor: ProgramDefinition,
        pendingUserInput: UserInputRequest
    ) {
        guard let runID = record.sessionID else {
            return
        }

        let steps = record.steps.map { step in
            let state: AgenticHostConsoleStepState
            if step.failure != nil {
                state = .failed
            } else if step.suspension != nil {
                state = .pending
            } else {
                state = .completed
            }

            return AgenticHostConsoleStepPresentation(
                id: "program-step-\(step.index)",
                title: programStepTitle(step),
                detail: step.failure?.message,
                state: state
            )
        }

        snapshot.hostConsole.runs.removeAll { run in
            run.id == runID
        }
        snapshot.hostConsole.runs.append(
            .init(
                id: runID,
                title: descriptor.title ?? descriptor.identifier.rawValue,
                summary: pendingUserInput.prompt,
                state: .paused,
                steps: steps
            )
        )
        snapshot.hostConsole.interruptions.removeAll { interruption in
            interruption.runID == runID
        }
        snapshot.hostConsole.documents.removeAll { document in
            document.runID == runID
        }
    }

    private func presentUserInput(
        request: Run.Interaction.Request,
        pendingUserInput: UserInputRequest
    ) {
        snapshot.pendingUserInput = .init(
            interactionID: request.id,
            runID: request.sessionID,
            request: pendingUserInput
        )
    }

    private func retainUserInput(
        request: Run.Interaction.Request,
        pendingUserInput: UserInputRequest
    ) {
        suspendedUserInputRequestsByRunID[request.sessionID] = request
        presentUserInput(
            request: request,
            pendingUserInput: pendingUserInput
        )
    }

    private func clearPendingUserInput(
        runID: String
    ) {
        suspendedUserInputRequestsByRunID.removeValue(
            forKey: runID
        )

        if snapshot.pendingUserInput?.runID == runID {
            snapshot.pendingUserInput = nil
        }
    }

    /// A terminal interruption clears stale controls without discarding
    /// the run's historical projection or reopening it on late state events.
    private func reconcileInterruptedRun(
        runID: String
    ) {
        settledRunIDs.insert(runID)
        clearPendingUserInput(
            runID: runID
        )
        snapshot.hostConsole.interruptions.removeAll { interruption in
            interruption.runID == runID
        }
        if let index = snapshot.hostConsole.runs.firstIndex(
            where: { $0.id == runID }
        ) {
            switch snapshot.hostConsole.runs[index].state {
            case .completed, .failed:
                break
            default:
                snapshot.hostConsole.runs[index].state = .interrupted
            }
        }
    }

    private func clearProgramRun(
        _ runID: String?
    ) {
        guard let runID else {
            return
        }

        suspendedProgramsByRunID.removeValue(
            forKey: runID
        )
        clearPendingUserInput(
            runID: runID
        )
        snapshot.hostConsole.runs.removeAll { run in
            run.id == runID
        }
        snapshot.hostConsole.interruptions.removeAll { interruption in
            interruption.runID == runID
        }
        snapshot.hostConsole.documents.removeAll { document in
            document.runID == runID
        }
    }

    private func programStepTitle(
        _ step: ProgramStepRecord
    ) -> String {
        switch step.kind {
        case .inference(let site, _):
            return "inference · \(site.rawValue)"
        case .tool(let identifier):
            return "tool · \(identifier.rawValue)"
        case .user_input:
            return "user input"
        case .program(let identifier):
            return "program · \(identifier.rawValue)"
        }
    }

    private func consume(
        _ result: AgentExecutor.Result,
        runID: String,
        runTitle: String,
        renderedInput: String? = nil,
        submissionGeneration generation: Int? = nil
    ) async throws -> AgentExecutor.Result {
        let isCurrent = generation == nil || generation == submissionGeneration
        settledRunIDs.insert(runID)
        if isCurrent {
            pending_interruption = nil
            stop_requested = false
        }
        // Steering was taken by the run, or opens the next turn: either way
        // it is no longer waiting on this run.
        for index in snapshot.messages.indices
        where snapshot.messages[index].pending == AgenticQueuePolicy.next.pendingLabel {
            snapshot.messages[index].pending = nil
        }
        if let record = result.costRecord {
            snapshot.usage.records[runID] = record
        }

        let previous_trace = liveRunState.flatMap { state in
            state.sessionID == result.sessionID ? try? state.execution_trace() : nil
        }
        let projection = AgenticConversationRunProjection.project(
            result,
            title: runTitle,
            previous_trace: previous_trace
        )
        refreshRunProjection(
            projection,
            runID: runID
        )

        if let request = result.interactionRequest,
           let pendingUserInput = request.requirement.pendingUserInput
        {
            retainUserInput(
                request: request,
                pendingUserInput: pendingUserInput
            )
        } else {
            clearPendingUserInput(
                runID: runID
            )
        }

        let responseText = result.response?.message.content.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let body: String
        if let responseText, !responseText.isEmpty {
            body = responseText
        } else if liveRunState?.sessionID == runID,
                  let liveAssistantText, !liveAssistantText.isEmpty {
            body = liveAssistantText
        } else if let failure = result.failure {
            body = failure.message
        } else if let runLimit = result.pendingRunLimit {
            body = runLimit.summary
        } else if result.isInterrupted {
            body = "The run was stopped."
        } else if result.isAwaitingApproval {
            body = "The run is awaiting approval."
        } else if result.isAwaitingUserInput {
            body = "The run is awaiting user input."
        } else if result.isSuspended {
            body = "The run is suspended."
        } else {
            body = "The run completed without assistant text."
        }

        updateAssistant(
            runID: runID,
            body: body
        )
        synchronizeStructuredConversation(
            runID: runID,
            messages: result.state.messages,
            events: result.events,
            toolUses: result.toolUses
        )

        let showsRunAttachment =
            !result.toolUses.isEmpty
                || !projection.run.steps.isEmpty
                || !projection.documents.isEmpty
                || !projection.interruptions.isEmpty
                || result.isAwaitingApproval
                || result.isSuspended
                || result.isInterrupted
                || result.isFailed

        setRunAttachmentVisible(
            showsRunAttachment,
            runID: runID
        )

        if !result.isSuspended, !result.isAwaitingApproval {
            await refreshStagedReview(runID: runID)
        }

        if let failure = result.failure {
            upsertFailureStatus(
                runID: runID,
                summary: failure.kind.rawValue,
                body: failure.message
            )
        }
        if isCurrent {
            if result.failure != nil {
                snapshot.activity = "run failed"
            } else if result.isInterrupted {
                snapshot.activity = "run stopped"
            } else if result.isAwaitingRunLimit {
                snapshot.activity = "run limit reached"
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
        }

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
        // A run may have been granted roots (or had turn leases expire).
        await refreshWorkspace()

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
                agent: primaryAgent?.identifier,
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
        // What the session traced at start (settings.paths) is no command's:
        // it shows as a workspace change of its own.
        let started = (try? await service.operatorTrace(sessionID, from: traceIndex)) ?? []
        await beginCommand()
        let applied = started.filter { $0.kind == .workspace_changed }
        if !applied.isEmpty {
            recordChange(.init(
                id: "settings-paths-" + baseSessionID,
                kind: .workspace,
                summary: "\(applied.count) from settings.paths",
                reason: "applied at session start from settings.frame",
                items: applied.map { entry in
                    .init(
                        id: "settings-\(entry.index)",
                        subject: "settings.paths",
                        detail: entry.summary.hasPrefix("settings: ")
                            ? String(entry.summary.dropFirst("settings: ".count))
                            : entry.summary
                    )
                },
                isLossy: applied.contains { $0.summary.contains("refused") }
            ))
        }
        await refreshWorkspace()
    }

    private func refreshWorkspace() async {
        guard serviceStarted,
              let state = try? await service.workspace(AgentHost.Session.ID(baseSessionID))
        else { return }
        present(state)
    }

    /// The header and the settings tree's Workspace section follow the
    /// Host's workspace state.
    private func present(
        _ state: AgentHost.WorkspaceState
    ) {
        snapshot.workspace = state.summary
        workingDirectory.path = state.directory
        snapshot.workingDirectory = state.directory
        snapshot.workspaceRoots = state.roots.map { root in
            let source: String
            switch root.source {
            case .configured: source = "configured"
            case .operator_command: source = "added"
            case .request: source = "model request"
            case .settings: source = "settings"
            }
            let access = root.asks
                ? "ask"
                : ([root.capabilities.map(\.rawValue).sorted().joined(separator: ", ")]
                    + (root.lifetime.map { [$0.rawValue] } ?? []))
                    .joined(separator: " · ")
            return .init(
                id: root.id,
                label: root.label,
                path: root.files.isEmpty ? root.path : root.files.joined(separator: ", "),
                access: access,
                source: source,
                isDefault: root.isDefault,
                isRemovable: root.source != .configured,
                restrictions: root.restrictions.map { .init(id: $0.id, pattern: $0.pattern) }
            )
        }
    }

    /// `:path` and `:cd`, typed without `:`. The outcome, or the refusal,
    /// shows in the conversation; the host has traced it in the session
    /// log, and the header follows the workspace.
    package func runWorkspaceCommand(_ text: String) async {
        await beginCommand()
        let body: String
        do {
            let command = try AgenticWorkspaceCommand(parsing: text)
            try await ensureServiceStarted()
            let id = AgentHost.Session.ID(baseSessionID)
            let state: AgentHost.WorkspaceState
            switch command {
            case .list:
                state = try await service.workspace(id)
                body = state.listing
            case .change(let change):
                let result = try await service.changeWorkspace(id, change, command: text)
                state = result.state
                body = result.outcome
            case .listScopes:
                state = try await service.workspace(id)
                let scopes = try pathScopes()
                body = scopes.isEmpty
                    ? "no PathScope bindings in settings.frame"
                    : scopes.keys.sorted().map { name in
                        let scope = scopes[name]!
                        return "\(name)  \(scope.path)\(scope.readOnly ? "  [read]" : "")"
                    }.joined(separator: "\n")
            case .addScope(let name, let readOnly):
                // The Host resolves the name, so a refusal is traced too.
                let result = try await service.changeWorkspace(
                    id,
                    .addScope(name: name, readOnly: readOnly),
                    command: text
                )
                state = result.state
                body = result.outcome
            }
            present(state)
            snapshot.activity = "workspace: \(state.summary)"
        } catch {
            body = "refused: \(error.localizedDescription)"
            snapshot.activity = body
        }
        await noteCommand(text, outcome: body)
    }

    /// What the active run's card adds: queued messages, a requested
    /// interrupt not yet reached, and commands issued during the run.
    private func runNotes(
        for runID: String
    ) -> [String] {
        guard runID == activeRunID else { return [] }
        var notes: [String] = []
        let changed = changes().filter { $0.runID == runID }.count
        if changed > 0 {
            notes.append("\(changed) change\(changed == 1 ? "" : "s") to this run · :context")
        }
        let queued = snapshot.messages.filter { $0.pending != nil }.count
        if queued > 0 {
            notes.append("\(queued) message\(queued == 1 ? "" : "s") queued · after the current run")
        }
        if stop_requested, let mode = requestedInterruption {
            notes.append(mode == .urgent
                ? "interrupt requested · earliest safe boundary"
                : "interrupt requested · after this iteration")
        }
        notes.append(contentsOf: (commandsByRunID[runID] ?? []).suffix(3))
        return notes
    }

    /// A message held under the queue policy, shown at once.
    package func notePending(
        _ submission: AgenticConversationSubmission,
        policy: AgenticQueuePolicy
    ) {
        snapshot.messages.append(.init(
            id: submission.id,
            role: .user,
            body: submission.body,
            attachments: submission.contents.map { .content($0) },
            pending: policy.pendingLabel
        ))
        snapshot.activity = "message queued · \(policy.pendingLabel)"
    }

    /// A message that was not sent leaves the transcript; the reason stays as
    /// a system note and the text waits in `takeUnsent()` for the composer.
    private func returnUnsent(
        _ submission: AgenticConversationSubmission,
        reason: String
    ) {
        snapshot.messages.removeAll { $0.id == submission.id }
        snapshot.messages.append(.init(
            id: "unsent-" + submission.id,
            role: .system,
            body: "Message not sent: \(reason) Its text is back in the message box.",
            attachments: []
        ))
        snapshot.activity = "message not sent: \(reason)"
        unsent.append(submission)
    }

    package func takeUnsent() -> [AgenticConversationSubmission] {
        defer { unsent = [] }
        return unsent
    }

    /// Removes held messages cancelled by the operator; their text goes back
    /// through `takeUnsent()`.
    package func withdrawPending(
        _ submissions: [AgenticConversationSubmission]
    ) {
        guard !submissions.isEmpty else { return }
        let ids = Set(submissions.map(\.id))
        snapshot.messages.removeAll { ids.contains($0.id) }
        snapshot.activity = submissions.count == 1
            ? "message cancelled · its text is back in the message box"
            : "\(submissions.count) messages cancelled · their text is back in the message box"
        unsent += submissions
    }

    /// A message the conversation could not start is not lost.
    package func returnUnstarted(
        _ submission: AgenticConversationSubmission,
        reason: String
    ) {
        returnUnsent(submission, reason: reason)
    }

    /// What a message held under `:queue await` waits for now, when it is
    /// more than the current run.
    private func holdLabel() -> String? {
        if snapshot.pendingUserInput != nil {
            return "pending · after the question is answered"
        }
        let kinds = Set(snapshot.hostConsole.interruptions.map(\.kind))
        if kinds.contains(.approval) || kinds.contains(.workspace_access) {
            return "pending · after the approval"
        }
        if kinds.contains(.run_limit) || kinds.contains(.recovery) {
            return "pending · after the run's decision"
        }
        if kinds.contains(.publication) {
            return "pending · after staged changes are published or discarded"
        }
        return nil
    }

    /// Steers the executing run with `submission`, shown at once as
    /// pending. Throws when no run is executing; the caller queues it then.
    package func steer(
        _ submission: AgenticConversationSubmission
    ) async throws {
        try await service.steer(.init(baseSessionID), text: submission.body)
        notePending(submission, policy: .next)
    }

    /// An installed Inference invoked by the owner; the typed output or the
    /// failure appears in the transcript.
    package func runInference(
        _ text: String,
        identifier: InferenceIdentifier,
        input: JSONValue
    ) async {
        let outcome: String
        do {
            try await ensureServiceStarted()
            let result = try await service.invokeInference(.init(
                inference: identifier,
                input: input,
                session: .init(baseSessionID)
            ))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            outcome = String(decoding: try encoder.encode(result.output), as: UTF8.self)
        } catch {
            outcome = "failed: \(error.localizedDescription)"
        }
        await noteCommand(text, outcome: outcome)
        snapshot.activity = "inference \(identifier.rawValue) done"
    }

    package func setQueuePolicy(
        _ policy: AgenticQueuePolicy
    ) {
        snapshot.queuePolicy = policy
    }

    /// A run waits on the operator: a question or a review. Queued messages
    /// wait for it to be resolved, not merely for the call to return.
    package func awaitsOperator() -> Bool {
        snapshot.pendingUserInput != nil || !snapshot.hostConsole.interruptions.isEmpty
    }

    /// Shows a change where it happened in the conversation. Every source
    /// of changes (history selection, routing, required capabilities,
    /// workspace) reports through here.
    package func recordChange(
        _ change: AgenticChangePresentation,
        before messageID: String? = nil
    ) {
        let id = "change-message-" + change.id
        // Live updates and the settled result report the same event.
        guard !snapshot.messages.contains(where: { $0.id == id }) else { return }
        let message = AgenticConversationMessagePresentation(
            id: id,
            role: .system,
            body: change.line,
            attachments: [.change(change)]
        )
        // A change to a request belongs before the answer it shaped.
        if let messageID,
           let index = snapshot.messages.firstIndex(where: { $0.id == messageID }) {
            snapshot.messages.insert(message, at: index)
        } else {
            snapshot.messages.append(message)
        }
    }

    /// The changes shown so far, newest last.
    package func changes() -> [AgenticChangePresentation] {
        snapshot.messages.flatMap { message in
            message.attachments.compactMap { attachment in
                if case .change(let change) = attachment { return change }
                return nil
            }
        }
    }

    /// `:context [all]`: the latest run's changes, or every one.
    package func runContextCommand(
        _ text: String
    ) async {
        await beginCommand()
        if text.split(whereSeparator: \.isWhitespace).first == "compact" {
            await runCompact(text)
            return
        }
        if text.split(whereSeparator: \.isWhitespace).first == "retro" {
            await runRetro(text)
            return
        }
        let words = text.split(whereSeparator: \.isWhitespace).dropFirst()
        guard words.isEmpty || words.elementsEqual(["all"]) else {
            await noteCommand(text, outcome: "refused: " + AgenticConsoleCommands.catalog.usage(["context"]))
            return
        }
        let all = changes()
        let latestRun = all.last { $0.runID != nil }?.runID
        let shown = words.isEmpty && latestRun != nil
            ? all.filter { $0.runID == latestRun || $0.runID == nil }
            : all
        let outcome = shown.isEmpty
            ? "no changes: every request carried the full history, on the selected route"
            : shown.map(\.line).joined(separator: "\n")
        await noteCommand(text, outcome: outcome)
    }

    /// `:export <format> [n] [path]`: the nth newest result shown in the
    /// conversation, written to a file; by default into the
    /// `exports.directory` of `settings.frame`.
    package func runExportCommand(
        _ text: String
    ) async {
        await beginCommand()
        do {
            let command = try AgenticExportCommand(parsing: text)
            let documents = snapshot.messages.reversed().flatMap { message in
                message.attachments.reversed().compactMap { attachment -> ReportDocument? in
                    guard case .structured(let structured) = attachment,
                          case .document(let document) = structured.content else { return nil }
                    return document
                }
            }
            guard command.index <= documents.count else {
                throw AgenticExportCommand.Failure.noResult(command.index)
            }
            let document = documents[command.index - 1]
            let directory = try exports().resolvedDirectory(workspace: workspace)
            let url = try await command.write(document, workspace: workspace, exports: directory)
            await noteCommand(text, outcome: "\(document.title) → \(url.path)")
        } catch {
            await noteCommand(text, outcome: "refused: \(error.localizedDescription)")
        }
    }

    /// `:compact`: through the Host, so it is traced and every later
    /// request of this conversation applies it.
    private func runCompact(
        _ text: String
    ) async {
        guard text.split(whereSeparator: \.isWhitespace).count == 1 else {
            await noteCommand(text, outcome: "refused: " + AgenticConsoleCommands.catalog.usage(["compact"]))
            return
        }
        do {
            try await ensureServiceStarted()
            let result = try await service.compact(.init(baseSessionID))
            if let compaction = result.compaction {
                recordChange(AgenticConversationChangeProjection.compaction(compaction))
            }
            await noteCommand(text, outcome: result.outcome)
        } catch {
            await noteCommand(text, outcome: "refused: \(error.localizedDescription)")
        }
    }

    /// `:retro`: the retrospective reviews this conversation's log in a
    /// session of its own, out of the conversation, and records verified
    /// findings in the home's `improvements/`. Its outcome arrives as a
    /// second note when it is done.
    private func runRetro(
        _ text: String
    ) async {
        guard text.split(whereSeparator: \.isWhitespace).count == 1 else {
            await noteCommand(text, outcome: "refused: " + AgenticConsoleCommands.catalog.usage(["retro"]))
            return
        }
        let reviewed = AgentHost.Session.ID(baseSessionID)
        let id = AgentHost.Session.ID("\(baseSessionID)-retro-\(UUID().uuidString.prefix(8).lowercased())")
        do {
            try await ensureServiceStarted()
            _ = try await service.start(.init(
                id: id,
                title: "Retrospective of \(baseSessionID)",
                agent: Harness.Agents.Retrospector.definition.identifier,
                reviewing: reviewed
            ))
            await noteCommand(text, outcome: "reviewing in session \(id.rawValue)")
        } catch {
            await noteCommand(text, outcome: "refused: \(error.localizedDescription)")
            return
        }
        let service = self.service
        Task {
            let outcome: String
            do {
                let result = try await service.submit(.init(
                    session: id,
                    prompt: "Review session \(reviewed.rawValue).",
                    execution: .init(configuration: .init(autonomyMode: .auto_bounded_mutate))
                ))
                outcome = result.response?.message.content.text
                    ?? "ended without a report (\(id.rawValue))"
            } catch {
                outcome = "failed: \(error.localizedDescription)"
            }
            await self.noteCommand("retro", outcome: outcome)
        }
    }

    /// Marks where a command's trace starts: what the Host traces from
    /// here until `noteCommand` belongs to it.
    package func beginCommand() async {
        guard serviceStarted,
              let entries = try? await service.operatorTrace(.init(baseSessionID), from: traceIndex),
              let last = entries.last
        else { return }
        traceIndex = last.index + 1
    }

    /// Appends `:command` as one entry: its outcome, what the model will
    /// see of it, and what the Host traced for it since `beginCommand`.
    package func noteCommand(
        _ command: String,
        outcome: String
    ) async {
        if let activeRunID {
            let first = outcome.split(separator: "\n").first.map(String.init) ?? outcome
            commandsByRunID[activeRunID, default: []].append(":\(command) → \(first)")
        }
        var trace: [String] = []
        if serviceStarted,
           let entries = try? await service.operatorTrace(.init(baseSessionID), from: traceIndex),
           let last = entries.last
        {
            trace = entries.map(\.line)
            traceIndex = last.index + 1
        }
        let id = UUID().uuidString
        snapshot.messages.append(.init(
            id: id,
            role: .system,
            body: ":\(command)\n\(outcome)",
            attachments: [.command(.init(
                id: "command-" + id,
                command: command,
                outcome: outcome,
                isRefused: outcome.hasPrefix("refused:") || outcome.hasPrefix("failed:"),
                contextEffect: AgenticConsoleCommands.catalog.definition(for: command)?.contextEffect ?? .none,
                trace: trace
            ))]
        ))
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
        pending_interruption = nil
        stop_requested = false
    }

    package func publish(
        _ state: AgentRunStateSnapshot
    ) async {
        // Suspended runs are already in settledRunIDs; their later terminal
        // state must still invalidate the old approval or user-input controls.
        if state.phase == .interrupted {
            // Preserve final historical output without changing the new run's
            // live presentation, even when this was a previously suspended run.
            let previousTrace = liveRunState.flatMap { earlier in
                earlier.sessionID == state.sessionID
                    ? try? earlier.execution_trace()
                    : nil
            }
            let title = snapshot.hostConsole.runs.first(where: {
                $0.id == state.sessionID
            })?.title ?? state.sessionID
            let projection = AgenticConversationRunProjection.project(
                state,
                title: title,
                previous_trace: previousTrace
            )
            refreshRunProjection(projection, runID: state.sessionID)
            synchronizeStructuredConversation(
                runID: state.sessionID,
                messages: state.state.messages,
                events: state.events,
                toolUses: state.toolUses
            )
            if let record = state.costRecord {
                snapshot.usage.records[state.sessionID] = record
            }
            setRunAttachmentVisible(true, runID: state.sessionID)
            reconcileInterruptedRun(runID: state.sessionID)
            if activeRunID == state.sessionID {
                snapshot.activity = "run stopped"
                liveRunState = nil
                liveAssistantText = nil
                activeRunID = nil
                activeRunTitle = nil
                pendingRunInput = nil
                pending_interruption = nil
                stop_requested = false
            }
            return
        }
        guard !settledRunIDs.contains(state.sessionID) else {
            return
        }

        let previous_trace = liveRunState.flatMap { earlier in
            earlier.sessionID == state.sessionID ? try? earlier.execution_trace() : nil
        }
        liveRunState = state
        activeRunID = state.sessionID
        if let record = state.costRecord {
            snapshot.usage.records[state.sessionID] = record
        }

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
            title: activeRunTitle ?? state.sessionID,
            previous_trace: previous_trace
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
        }

        synchronizeStructuredConversation(
            runID: state.sessionID,
            messages: state.state.messages,
            events: state.events,
            toolUses: state.toolUses
        )

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

        if stop_requested {
            snapshot.activity =
                "Stop requested · finishing active effect if necessary, then stopping"
        } else {
            snapshot.activity = Self.activityTitle(
                for: state
            )
        }

        if let stop = pending_interruption {
            pending_interruption = nil
            do {
                try await service.interrupt(
                    .init(
                        session: .init(baseSessionID),
                        runID: state.sessionID,
                        mode: stop.mode,
                        reason: stop.reason
                    )
                )
            } catch {
                stop_requested = false
                snapshot.activity = "Stop failed: \(error.localizedDescription)"
            }
        }
    }

    package func presentationSnapshot(
        now: Date = Date()
    ) -> AgenticConversationSnapshot {
        var presentation = snapshot
        // Held messages name what actually holds them; derived when read so
        // the label follows the session without being stored.
        if let holdLabel = holdLabel() {
            for index in presentation.messages.indices
            where presentation.messages[index].pending == AgenticQueuePolicy.await.pendingLabel {
                presentation.messages[index].pending = holdLabel
            }
        }
        // Notes are derived when read, so a run's republished presentation
        // never drops them.
        for index in presentation.hostConsole.runs.indices {
            presentation.hostConsole.runs[index].notes = runNotes(
                for: presentation.hostConsole.runs[index].id
            )
        }

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

    private func synchronizeStructuredConversation(
        runID: String,
        messages: [Message],
        events: [Run.Event.State],
        toolUses: [AgentToolUseRecord]
    ) {
        for event in events {
            switch event.kind {
            case .context_changed:
                // Compacted pointers have their own card, from `:compact`;
                // each later run applying them is not news.
                guard let change = AgenticConversationChangeProjection.change(event, runID: runID) else { break }
                recordChange(change, before: "\(runID)-assistant")
            case .context_pressure:
                recordChange(
                    AgenticConversationChangeProjection.pressure(event, runID: runID),
                    before: "\(runID)-assistant"
                )
            case .cache_miss:
                guard let change = AgenticConversationChangeProjection.cacheMiss(event, runID: runID) else { break }
                recordChange(change, before: "\(runID)-assistant")
            case .schemas_advertised:
                guard let advertisement = event.advertisement else { break }
                if advertisement.rewritesCachedPrefix {
                    recordChange(
                        AgenticConversationChangeProjection.toolsChanged(event, events: events, runID: runID),
                        before: "\(runID)-assistant"
                    )
                } else {
                    let signature = advertisement.entries.map { "\($0.name) \($0.detail.rawValue)" }
                    guard signature != shownOpening,
                          let opening = AgenticConversationChangeProjection.opening(event, events: events, runID: runID)
                    else { break }
                    shownOpening = signature
                    recordChange(opening, before: "\(runID)-assistant")
                }
            case .model_routed:
                if let route = event.route, route.isRerouted {
                    recordChange(
                        AgenticConversationChangeProjection.reroute(event, route: route, runID: runID, models: snapshot.models),
                        before: "\(runID)-assistant"
                    )
                }
            default:
                break
            }
        }
        guard let index = snapshot.messages.firstIndex(where: {
            $0.id == "\(runID)-assistant"
        }) else { return }
        // The answer names the model of the request that produced it.
        if let route = events.last(where: { $0.kind == .model_routed })?.route {
            snapshot.messages[index].route = AgenticConversationChangeProjection.route(route, models: snapshot.models)
        }
        let iterations = AgenticConversationStructuredProjection.iterations(
            runID: runID,
            messages: messages,
            events: events
        )
        let views = AgenticConversationStructuredProjection.attachments(
            runID: runID,
            toolUses: toolUses,
            events: events
        )
        snapshot.messages[index].iterations = iterations
        // Recompute from canonical runtime records, rather than appending
        // again on every stream update, suspension, or resume.
        var retained = snapshot.messages[index].attachments.filter { attachment in
            switch attachment {
            case .structured, .trace, .run:
                return false
            case .content, .program, .command, .change:
                return true
            }
        }
        retained.append(contentsOf: views)
        if snapshot.messages[index].attachments.contains(where: { attachment in
            if case .run(let id) = attachment { return id == runID }
            return false
        }) {
            retained.append(.run(runID: runID))
        }
        snapshot.messages[index].attachments = retained
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
        var run = run
        if let agents = agentsByRunID[run.id] {
            run.agents = agents
        }
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

    /// The run ID the conversation believes is still occupying the session
    /// (actively executing, awaiting approval, awaiting user input, or paused
    /// at a run limit). Used as the expected run for a superseding
    /// submission; the Host rejects a stale confirmation if ownership moved.
    package func unsettledRunID() -> String? {
        if let interactionRunID = snapshot.pendingUserInput?.runID {
            return interactionRunID
        }
        if let active = activeRunID {
            return active
        }
        return snapshot.hostConsole.runs.first(where: { run in
            guard run.parentID == nil else { return false }
            switch run.state {
            case .ready,
                 .active,
                 .pause_pending,
                 .paused,
                 .awaitingApproval,
                 .onHold:
                return true

            case .interrupted,
                 .completed,
                 .failed:
                return false
            }
        })?.id
    }

    package func input(for runID: String) -> String? {
        runInputs[runID]
    }

    package func output(for runID: String) -> String? {
        runOutputs[runID]
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

    private static func systemInstructions(
        workspace: String,
        instructions: [InstructionDefinition],
        base: InstructionSnapshot? = nil
    ) -> InstructionSnapshot {
        let authoredParts: [Instructions.Part] = base.map { snapshot in
            snapshot.composition?.parts ?? [.text(snapshot.content)]
        } ?? []
        let parts = authoredParts + [
            .text("You are operating in an Agentic terminal conversation."),
            .text("Workspace root: \(workspace)"),
            .text("Use only the advertised capabilities and keep file operations inside the workspace."),
        ] + instructions.map { .instruction($0) }
        return Instructions(parts).snapshot
    }

}

/// Changes staged by finished work in this conversation, reviewed from the
/// run card that finished last: one Diff across every staged file, Details
/// naming the run that staged each change, and Publish, Discard or Skip.
extension AgenticConversationSession {
    static let stagedReviewPrefix = "staged-review:"

    /// Changes this conversation wrote that still await review.
    package func unreviewedChanges() async throws -> Int {
        guard serviceStarted else { return 0 }
        return try await service.unreviewedChanges(.init(baseSessionID))
    }

    /// This conversation's staged review, refreshed now; nil when nothing
    /// it ran is staged.
    package func stagedReview() async -> AgenticHostConsoleInterruptionPresentation? {
        let runID = snapshot.hostConsole.interruptions.first { $0.kind == .publication }?.runID
            ?? snapshot.hostConsole.runs.last { $0.parentID == nil }?.id
        if let runID {
            await refreshStagedReview(runID: runID, includingWritten: true)
        }
        return snapshot.hostConsole.interruptions.first { $0.kind == .publication }
    }

    /// After a run: only what is staged pops up. Written changes wait for
    /// `:review`, so the operator decides when to look.
    func refreshStagedReview(
        runID: String,
        includingWritten: Bool = false
    ) async {
        snapshot.hostConsole.interruptions.removeAll { $0.kind == .publication }
        snapshot.hostConsole.documents.removeAll { $0.stepID.hasPrefix(Self.stagedReviewPrefix) }

        guard let review = try? await service.reviewCoordinatedMutations(
            session: .init(baseSessionID),
            includingPublished: includingWritten
        ) else {
            return
        }

        // One review per origin, so each worker's changes are judged alone.
        let whole = Self.stagedReviewPrefix + review.id.uuidString
        for origin in review.origins {
            let stepID = whole + ":" + origin.submissionID.uuidString
            let written = origin.isPublished
            let title = (written ? "Written · " : "Staged · ") + agentTitle(origin.runID)
            let files = origin.paths.count
            let summary = "\(files) \(files == 1 ? "file" : "files") "
                + (written ? "written, awaiting review" : "staged, not yet on disk")
                + (review.origins.count > 1 ? " · one of \(review.origins.count) changes to review" : "")
            snapshot.hostConsole.interruptions.append(
                .init(
                    id: stepID,
                    runID: runID,
                    stepID: stepID,
                    kind: .publication,
                    title: title,
                    summary: summary,
                    actions: written ? [.keep, .roll_back, .skip] : [.publish, .discard, .skip]
                )
            )
            if let difference = origin.difference ?? (review.origins.count == 1 ? review.difference : nil),
               let preview = HostPreviewDocument.make(
                   .init([.difference(difference, title: title)]),
                   id: stepID + "-preview",
                   runID: runID,
                   stepID: stepID
               ) {
                snapshot.hostConsole.documents.append(preview)
            }
            snapshot.hostConsole.documents.append(
                .init(
                    id: stepID + "-details",
                    runID: runID,
                    stepID: stepID,
                    kind: .details,
                    title: title,
                    body: (
                        [summary, "", (written ? "written by " : "staged by  ") + agentTitle(origin.runID), "run        \(origin.runID ?? "unknown")", ""]
                            + origin.paths
                            + [
                                "",
                                written
                                    ? "Keep leaves them on disk; Roll back restores what was there, refused if a file changed since; Skip asks again later."
                                    : "Publish writes these to disk; Discard withdraws them; Skip keeps them staged.",
                                "[ and ] move between changes; :publish keeps or publishes all, :discard rolls back or discards all.",
                            ]
                    ).joined(separator: "\n")
                )
            )
        }
        setRunAttachmentVisible(true, runID: runID)
        snapshot.activity = "staged changes awaiting review"
    }

    /// Decides one origin's review (`staged-review:<ticket>:<submission>`),
    /// or the whole review (`staged-review:<ticket>`).
    func resolveStagedReview(
        id: String,
        runID: String,
        action: AgenticHostConsoleAction
    ) async throws {
        let parts = id.dropFirst(Self.stagedReviewPrefix.count).split(separator: ":")
        guard let ticket = parts.first.flatMap({ UUID(uuidString: String($0)) }) else {
            throw AgenticConversationSessionError.unsupportedHostAction(action.id)
        }
        let submission = parts.dropFirst().first.flatMap { UUID(uuidString: String($0)) }

        let decision: ApprovalDecision
        switch action {
        case .publish, .keep:
            decision = .approved
        case .discard, .roll_back:
            decision = .denied
        case .skip:
            decision = .skipped
        default:
            throw AgenticConversationSessionError.unsupportedHostAction(action.id)
        }

        if decision == .skipped {
            // Skipping keeps it staged; it leaves the review until next time.
            snapshot.hostConsole.interruptions.removeAll { $0.id == id || (submission == nil && $0.kind == .publication) }
            snapshot.hostConsole.documents.removeAll { $0.stepID == id }
            snapshot.activity = "staged changes kept for later review"
            return
        }

        let publication: StandardMutationPublication?
        if let submission {
            publication = try await service.decideCoordinatedMutations(
                reviewID: ticket,
                decisions: [submission: decision]
            )
        } else {
            publication = try await service.publishCoordinatedMutations(
                reviewID: ticket,
                decision: decision
            )
        }

        switch decision {
        case .approved:
            let written = publication?.contributions.flatMap(\.entries).filter(\.was_applied).count ?? 0
            snapshot.activity = "published \(written) staged \(written == 1 ? "change" : "changes")"
        default:
            snapshot.activity = "discarded staged changes"
        }
        // The ticket is spent; what remains staged gets a fresh review.
        await refreshStagedReview(runID: runID)
    }

    /// The whole review an origin's review belongs to.
    package static func wholeStagedReviewID(
        of id: String
    ) -> String {
        guard id.hasPrefix(stagedReviewPrefix),
              let ticket = id.dropFirst(stagedReviewPrefix.count).split(separator: ":").first
        else {
            return id
        }
        return stagedReviewPrefix + ticket
    }

    /// The worker's Agent name, from the run's delegation tree.
    func agentTitle(
        _ runID: String?
    ) -> String {
        if let runID,
           let agent = agentsByRunID.values.joined().first(where: { $0.id == runID }) {
            return agent.title
        }
        return Self.originTitle(runID)
    }

    /// `child:…:call_id` reads as the worker that call started.
    static func originTitle(
        _ runID: String?
    ) -> String {
        guard let runID else {
            return "unknown run"
        }
        guard runID.hasPrefix("child:"),
              let call = runID.split(separator: ":").last
        else {
            return "this conversation"
        }
        return "worker \(call)"
    }
}

extension AgenticConversationSession {
    /// A resolved review resumes its run at once; the card must not keep
    /// showing the decided interruption until the run next reports.
    func markResumed(
        runID: String
    ) {
        snapshot.hostConsole.interruptions.removeAll { $0.runID == runID }
        guard let index = snapshot.hostConsole.runs.firstIndex(where: { $0.id == runID }) else {
            return
        }
        snapshot.hostConsole.runs[index].state = .active
        snapshot.hostConsole.runs[index].summary = nil
        snapshot.hostConsole.runs[index].agents = snapshot.hostConsole.runs[index].agents.map { agent in
            var agent = agent
            if agent.state == .awaitingReview || agent.state == .awaitingInput {
                agent.state = .running
            }
            return agent
        }
        agentsByRunID[runID] = snapshot.hostConsole.runs[index].agents
    }

    /// Refreshes each unsettled run's delegation tree from the Host. Workers
    /// report through the delegation, not the conversation's state stream.
    package func refreshAgents() async {
        let roots = snapshot.hostConsole.runs.filter { run in
            run.parentID == nil && (
                ![.completed, .failed, .interrupted].contains(run.state)
                    || (agentsByRunID[run.id]?.contains { !$0.state.isSettled } ?? false)
            )
        }
        guard serviceStarted, !roots.isEmpty,
              let workers = try? await service.delegatedWorkers(.init(baseSessionID))
        else {
            return
        }
        for run in roots {
            let live = liveRunState?.sessionID == run.id ? liveRunState : nil
            let agents = AgenticConversationAgentProjection.project(
                workers,
                runID: run.id,
                runState: run.state,
                rootState: live,
                rootCost: snapshot.usage.records[run.id]
            )
            guard !agents.isEmpty else { continue }
            agentsByRunID[run.id] = agents
            if let index = snapshot.hostConsole.runs.firstIndex(where: { $0.id == run.id }) {
                snapshot.hostConsole.runs[index].agents = agents
            }
            let ids = Set(agents.map(\.id))
            for worker in workers where worker.session.parentSessionID != nil && ids.contains(worker.session.id) {
                presentWorker(worker, title: agents.first { $0.id == worker.session.id }?.title)
            }
        }
    }

    /// A worker's own run: its steps, trace and diffs, inspectable in the run
    /// console under the run that delegated to it. Its reviews surface on
    /// that run, so none are added here.
    private func presentWorker(
        _ worker: AgentDelegation.Snapshot,
        title: String?
    ) {
        guard let state = worker.state else { return }
        let id = worker.session.id
        var projection = AgenticConversationRunProjection.project(
            state,
            title: title ?? worker.session.agent.rawValue
        )
        projection.run.parentID = worker.session.parentSessionID
        upsertRun(projection.run)
        snapshot.hostConsole.documents.removeAll { $0.runID == id }
        snapshot.hostConsole.documents.append(contentsOf: projection.documents)
        if let record = state.costRecord {
            snapshot.usage.records[id] = record
        }
    }
}

extension AgenticConversationSession {
    /// Completes "This model …" for a model whose provider is not set up,
    /// naming the setting to provide when the provider reports one.
    static func unconfiguredReason(
        _ unavailability: AgentModelGatewayUnavailability
    ) -> String {
        if let symbol = unavailability.metadata["symbol"] {
            return "is not configured: set \(symbol)"
        }
        let message = unavailability.message.map {
            $0.hasSuffix(".") ? String($0.dropLast()) : $0
        }
        return "is not configured" + (message.map { ": \($0)" } ?? "")
    }
}
