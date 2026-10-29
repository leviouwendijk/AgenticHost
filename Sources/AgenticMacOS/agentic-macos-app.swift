import Agentic
import AgenticHost
import AgenticApple
import AgenticOllama
import AgenticRuntime
import SwiftUI

enum DesktopApplication: AgenticApplicationProviding {
    static let application = Agentic.application(
        "agentic-macos",
        title: "Agentic"
    ) {
        modelProvider(AppleFoundationModelProvider())
        modelProvider(OllamaModelProvider())
    }
}

@main
struct AgenticMacOSApp: App {
    @StateObject private var model = DesktopModel()

    var body: some Scene {
        WindowGroup("Agentic") {
            DesktopView(model: model)
                .frame(minWidth: 760, minHeight: 520)
                .task {
                    await model.connect()
                }
        }
    }
}

extension DesktopApplication {
    static func makeHost() async throws -> any AgentHost.Service {
        let runtime = try await AgenticRuntime.resolve(Self.self)
        return AgentHost.Local(runtime: runtime)
    }
}
