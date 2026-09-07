import Foundation

struct AgenticInterfaceTestCase: Sendable {
    let id: String
    let summary: String
    let run: @Sendable (
        [String]
    ) async throws -> Void

    init(
        id: String,
        summary: String,
        run: @escaping @Sendable (
            [String]
        ) async throws -> Void
    ) {
        self.id = id
        self.summary = summary
        self.run = run
    }
}

struct AgenticInterfaceTestCatalog: Sendable {
    let tests: [AgenticInterfaceTestCase]

    init(
        tests: [AgenticInterfaceTestCase]
    ) {
        self.tests = tests
    }

    static func standard() -> Self {
        .init(
            tests: [
                AppleMutateApprovalTestCase.make(),

                ScriptedMutateFilesApprovalTestCase.makeDeny(),
                ScriptedMutateFilesApprovalTestCase.makeApprove(),
                ScriptedMutateFilesApprovalTestCase.makeInvalidPayload(),
                ScriptedMutateFilesApprovalTestCase.makeRollbackMetadata(),
                ScriptedProjectDiscoveryApprovalTestCase.make(),

                ToolHostTestCase.makeListDescribe(),
                ToolHostTestCase.makeJSONRoundtrip(),
                ToolHostTestCase.makeInvocationInputDecoding(),
                ToolHostTestCase.makeInvokeBatch(),
                ToolHostTestCase.makeInvokePlan(),
                ToolHostTestCase.makePreflightNoExecution(),
                ToolHostTestCase.makeInvokeObserve(),
                ToolHostTestCase.makeInvokeApprovedReview(),
                ToolHostTestCase.makeCapabilityManifest(),
                ToolHostResultProcessingTestCase.make(),

                ModeAwareInterfaceTestCase.make(),
                ModeAwareRunnerSmokeTestCase.make(),

                ModeAwareControllerTestCase.makeApprove(),
                ModeAwareControllerTestCase.makeDeny(),
                ModeAwareControllerTestCase.makeSkip(),
                ModeAwareControllerTestCase.makeStop(),

                ModeCommandArgumentsTestCase.makeDefaultsToCoder(),
                ModeCommandArgumentsTestCase.makeSelectsMode(),
                ModeCommandArgumentsTestCase.makeCapturesSystem(),
                ModeCommandArgumentsTestCase.makeCapturesMetadata(),
                ModeCommandArgumentsTestCase.makeRejectsMissingPrompt(),
                ModeCommandArgumentsTestCase.makeRejectsUnknownMode(),
                ModeCommandArgumentsTestCase.makeCodableRoundtrip(),

                ModeCommandInvocationTestCase.makeParsesAndPrepares(),
                ModeCommandInvocationTestCase.makeExecutesApprovedCoderCommand(),
                ModeCommandInvocationTestCase.makePreservesArgvMetadata(),
                ModeCommandInvocationTestCase.makeRejectsUnknownModeBeforeExecution(),

                AWSAdapterCallTestCase.make(),
                AWSMutateRefactorApprovalTestCase.make(),
                AWSMutateMultiFileApprovalTestCase.make(),
                AWSModelRoutingAdvisorTestCase.make(),
            ]
        )
    }

    func resolve(
        _ id: String
    ) throws -> AgenticInterfaceTestCase {
        guard let test = tests.first(
            where: {
                $0.id == id
            }
        ) else {
            throw AgenticInterfaceTestError.unknownTestCase(
                id,
                available: tests.map(\.id)
            )
        }

        return test
    }
}
