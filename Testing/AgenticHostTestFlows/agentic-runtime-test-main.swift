import TestFlows

@main
enum AgenticRuntimeTestMain {
    static func main() async {
        await TestFlowCLI.run(
            suite: AgenticRuntimeFlowSuite.self
        )
    }
}
