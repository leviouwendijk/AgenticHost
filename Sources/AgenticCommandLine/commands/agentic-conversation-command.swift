import Agentic
import AgenticHost
import AgenticInterfaces
import AgenticRuntime
import Arguments
import Clipboard
import Terminal

public enum AgenticConversationCommand<
    Application: AgenticApplicationProviding
>:
    ParsedArgumentCommand
{
    public typealias Options = HostOptions

    public static var name: String {
        "conversation"
    }

    public static func run(
        _ options: Options,
        invocation: ParsedInvocation
    ) async throws {
        _ = invocation

        let runtime = try await AgenticRuntime.resolve(
            Application.self
        )
        let workspace = try AgenticRuntimeWorkspace.resolve(
            options.workspace
        )
        let service: any AgentHost.Service = AgentHost.Local(
            runtime: runtime,
            workspace: workspace
        )
        let capabilities = try await service.capabilities()
        let conversation = try AgenticConversationSession(
            workspace: workspace.rootURL.path,
            service: service,
            capabilities: capabilities,
            sessionID: options.sessionID
        )
        try await AgenticConversationConsole.run(
            conversation: conversation,
            voiceInput: Application.hostVoiceInputProvider
        )
    }
}

private actor AgenticConversationTurnCompletion {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func take() -> Bool {
        defer {
            completed = false
        }

        return completed
    }
}

private enum AgenticConversationConsole {
    static func run(
        conversation: AgenticConversationSession,
        voiceInput: (any VoiceInputProvider)?
    ) async throws {
        let stream = TerminalStream.standardError
        let terminalSession = try TerminalSession(
            options: TerminalSession.Options(
                useAlternateScreen: true,
                hideCursor: true,
                useRawMode: true,
                useBracketedPaste: true,
                keyboardProtocol: .kitty,
                controlSignalBehavior: .input,
                restoreOnInterrupt: true,
                outputStream: stream
            )
        )
        defer {
            terminalSession.restore()
        }

        let reader = TerminalKeyReader()
        var renderer = TerminalFrameRenderer(stream: stream)
        var size = Terminal.size(for: stream)

        let voiceAvailability =
            await voiceInput?.availability()
            ?? .unconfigured

        await conversation.setVoiceAvailability(
            voiceAvailability
        )
        await conversation.setVoiceState(
            .idle
        )

        var control = AgenticConversationControl(
            snapshot: await conversation.presentationSnapshot()
        )
        let completion =
            AgenticConversationTurnCompletion()
        var activeSubmission:
            Task<Void, Never>?

        defer {
            activeSubmission?.cancel()
        }

        func render() {
            var frame = TerminalFrame(
                rows: size.rows,
                columns: size.columns
            )
            control.render(
                into: &frame,
                in: TerminalRegion(
                    rows: size.rows,
                    columns: size.columns
                )
            )
            renderer.render(frame)
        }

        render()

        while true {
            let events = reader.readEvents(
                timeoutMilliseconds: 100,
                maximumCount: 128
            )
            var needsRender = false

            if await completion.take() {
                activeSubmission = nil
                control.endPendingTurn()
                control.update(
                    await conversation.presentationSnapshot()
                )
                needsRender = true
            }

            if activeSubmission != nil {
                control.update(
                    await conversation.presentationSnapshot()
                )
                needsRender = true
            }

            if (await conversation.snapshot).voiceState == .recording,
               let voiceInput
            {
                await conversation.setVoiceStatus(
                    await voiceInput.status()
                )
                control.update(
                    await conversation.presentationSnapshot()
                )
                needsRender = true
            }

            let currentSize = Terminal.size(for: stream)
            if currentSize != size {
                size = currentSize
                needsRender = true
            }

            if events.isEmpty {
                if needsRender {
                    render()
                }

                continue
            }

            for input in events {
                guard let event = control.handle(input) else {
                    continue
                }

                switch event {
                case .exitRequested:
                    return

                case .submissionRequested(let submission):
                    guard activeSubmission == nil else {
                        await conversation.setActivity(
                            "model response already pending"
                        )
                        control.update(
                            await conversation.presentationSnapshot()
                        )
                        break
                    }

                    await conversation.setActivity(
                        "invoking model"
                    )
                    control.beginPendingTurn(
                        submission
                    )
                    control.update(
                        await conversation.presentationSnapshot()
                    )
                    render()

                    activeSubmission = Task {
                        do {
                            _ = try await conversation.submit(
                                submission
                            )
                        } catch is CancellationError {
                        } catch {
                            await conversation.recordFailure(
                                error
                            )
                        }

                        await completion.markCompleted()
                    }

                case .modelPreferenceChanged(let identifier):
                    guard activeSubmission == nil else {
                        break
                    }
                    await conversation.preferModel(identifier)
                    control.update(
                        await conversation.presentationSnapshot()
                    )

                case .responseDeliverySelectionChanged(let delivery):
                    guard activeSubmission == nil else {
                        break
                    }
                    await conversation.selectResponseDelivery(
                        delivery
                    )
                    control.update(
                        await conversation.presentationSnapshot()
                    )

                case .invocationOptionsSelectionChanged(let options):
                    guard activeSubmission == nil else {
                        break
                    }
                    await conversation.selectInvocationOptions(
                        options
                    )
                    control.update(
                        await conversation.presentationSnapshot()
                    )

                case .autonomySelectionChanged(let mode):
                    guard activeSubmission == nil else {
                        break
                    }
                    await conversation.selectAutonomy(mode)
                    control.update(
                        await conversation.presentationSnapshot()
                    )

                case .toolExposureSelectionChanged(let exposure):
                    guard activeSubmission == nil else {
                        break
                    }
                    await conversation.selectToolExposure(exposure)
                    control.update(
                        await conversation.presentationSnapshot()
                    )

                case .customToolSelectionChanged(let selection):
                    guard activeSubmission == nil else {
                        break
                    }
                    await conversation.selectCustomToolSelection(
                        selection
                    )
                    control.update(
                        await conversation.presentationSnapshot()
                    )

                case .skillSelectionChanged(let identifiers):
                    guard activeSubmission == nil else {
                        break
                    }
                    await conversation.selectSkills(identifiers)
                    control.update(
                        await conversation.presentationSnapshot()
                    )

                case .feedbackRequested(let message):
                    await conversation.setActivity(message)
                    control.update(
                        await conversation.presentationSnapshot()
                    )

                case .voiceStartRequested:
                    guard let voiceInput else {
                        await conversation.setVoiceAvailability(
                            .unconfigured
                        )
                        await conversation.setVoiceState(
                            .idle
                        )
                        await conversation.setActivity(
                            "Voice input unavailable — no transcription provider configured."
                        )
                        control.update(
                            await conversation.presentationSnapshot()
                        )
                        break
                    }

                    do {
                        try await voiceInput.start()
                        await conversation.setVoiceStatus(
                            await voiceInput.status()
                        )
                        await conversation.setVoiceState(
                            .recording
                        )
                        await conversation.setActivity(
                            "recording voice input"
                        )
                    } catch {
                        let message =
                            String(
                                describing: error
                            )
                        await conversation.setVoiceState(
                            .failed(
                                message
                            )
                        )
                        await conversation.setActivity(
                            "Voice input failed: \(message)"
                        )
                    }

                    control.update(
                        await conversation.presentationSnapshot()
                    )

                case .voiceStopRequested:
                    guard let voiceInput else {
                        await conversation.setVoiceAvailability(
                            .unconfigured
                        )
                        await conversation.setVoiceState(
                            .idle
                        )
                        await conversation.setActivity(
                            "Voice input unavailable — no transcription provider configured."
                        )
                        control.update(
                            await conversation.presentationSnapshot()
                        )
                        break
                    }

                    await conversation.setVoiceStatus(
                        nil
                    )
                    await conversation.setVoiceState(
                        .transcribing
                    )
                    await conversation.setActivity(
                        "transcribing voice input"
                    )
                    control.update(
                        await conversation.presentationSnapshot()
                    )
                    render()

                    do {
                        let transcription =
                            try await voiceInput.stop()

                        await conversation.setVoiceState(
                            .idle
                        )
                        await conversation.setActivity(
                            "transcription ready"
                        )
                        control.update(
                            await conversation.presentationSnapshot()
                        )

                        _ = control.applyTranscription(
                            transcription
                        )
                    } catch {
                        let message =
                            String(
                                describing: error
                            )
                        await conversation.setVoiceState(
                            .failed(
                                message
                            )
                        )
                        await conversation.setActivity(
                            "Voice input failed: \(message)"
                        )
                        control.update(
                            await conversation.presentationSnapshot()
                        )
                    }

                case .voiceCancelRequested:
                    if let voiceInput {
                        await voiceInput.cancel()
                    }

                    await conversation.setVoiceStatus(
                        nil
                    )
                    await conversation.setVoiceState(
                        .idle
                    )
                    await conversation.setActivity(
                        "voice input cancelled"
                    )
                    control.update(
                        await conversation.presentationSnapshot()
                    )

                case .run(let workflowEvent):
                    if case .actionRequested(
                        interruptionID: let interruptionID,
                        runID: let runID,
                        stepID: let stepID,
                        action: let action
                    ) = workflowEvent {
                        guard activeSubmission == nil else {
                            await conversation.setActivity(
                                "model response already pending"
                            )
                            control.update(
                                await conversation.presentationSnapshot()
                            )
                            break
                        }

                        await conversation.setActivity(
                            "applying \(action.title.lowercased())"
                        )
                        control.update(
                            await conversation.presentationSnapshot()
                        )
                        render()

                        activeSubmission = Task {
                            do {
                                _ = try await conversation.resolveHostAction(
                                    interruptionID: interruptionID,
                                    runID: runID,
                                    stepID: stepID,
                                    action: action
                                )
                            } catch is CancellationError {
                            } catch {
                                await conversation.setActivity(
                                    "Action failed: \(error.localizedDescription)"
                                )
                            }

                            await completion.markCompleted()
                        }
                        break
                    }

                    await service(
                        workflowEvent,
                        conversation: conversation
                    )
                    control.update(
                        await conversation.presentationSnapshot()
                    )

                case .contentPinned,
                     .attachmentOpened,
                     .attachmentClosed,
                     .runOpened,
                     .runClosed:
                    break
                }
            }

            size = Terminal.size(for: stream)
            render()
        }
    }

    private static func service(
        _ event: AgenticHostConsoleWorkflowEvent,
        conversation: AgenticConversationSession
    ) async {
        let copied: Bool
        let success: String
        let failure: String

        switch event {
        case .copyRequested(
            text: let text,
            title: let title
        ):
            copied = Clipboard.system.write(text)
            success = "Copied \(title.lowercased())."
            failure = "Clipboard write failed."

        case .runInputCopyRequested(runID: let runID):
            guard let text = await conversation.input(for: runID) else {
                await conversation.setActivity("Run input is not available.")
                return
            }
            copied = Clipboard.system.write(text)
            success = "Copied run input."
            failure = "Could not copy run input."

        case .runOutputCopyRequested(runID: let runID):
            guard let text = await conversation.output(for: runID) else {
                await conversation.setActivity("Run output is not available.")
                return
            }
            copied = Clipboard.system.write(text)
            success = "Copied run output."
            failure = "Could not copy run output."

        case .feedbackRequested(message: let message):
            await conversation.setActivity(message)
            return

        default:
            return
        }

        await conversation.setActivity(copied ? success : failure)
    }
}