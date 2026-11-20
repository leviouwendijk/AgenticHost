import Foundation
import TestFlows

@main
struct AgenticInterfaceTest {
    static func main() async {
        do {
            let extracted = try AgenticInterfaceRunOptions.extract(
                from: CommandLine.arguments
            )
            let catalog = AgenticInterfaceTestCatalog.standard()
            let invocation = try AgenticInterfaceTestInvocation.parse(
                extracted.arguments
            )
            let interaction = TerminalTestFlowInteraction()

            switch invocation {
            case .menu:
                let test = try await AgenticInterfaceTestMenu.pick(
                    catalog.tests,
                    interaction: interaction
                )

                try await AgenticInterfaceTestEnvironment.run(
                    test: test,
                    arguments: [],
                    interaction: interaction,
                    options: extracted.options
                )

            case .list:
                AgenticInterfaceTestPrinter.printAvailable(
                    catalog.tests
                )

            case .run(let testID, let arguments):
                let test = try catalog.resolve(
                    testID
                )

                try await AgenticInterfaceTestEnvironment.run(
                    test: test,
                    arguments: arguments,
                    interaction: interaction,
                    options: extracted.options
                )
            }
        } catch {
            fputs(
                "aginttest failed: \(error.localizedDescription)\n",
                stderr
            )

            Foundation.exit(
                1
            )
        }
    }
}
