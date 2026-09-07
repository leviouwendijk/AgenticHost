import Agentic
import AgenticInterfaces
import Foundation

public enum AgenticRuntimeCommandIO {
    public static func readStandardInput() throws -> Data {
        let data = FileHandle.standardInput
            .readDataToEndOfFile()

        guard !data.isEmpty else {
            throw AgenticRuntimeCommandError
                .missingStandardInput
        }

        return data
    }

    public static func readToolCall() throws -> AgentToolCall {
        try JSONDecoder().decode(
            AgentToolCall.self,
            from: readStandardInput()
        )
    }

    public static func write(
        _ envelope: AgenticToolHostEnvelope
    ) throws {
        let text = try text(
            envelope
        )

        FileHandle.standardOutput.write(
            Data(text.utf8)
        )
        FileHandle.standardOutput.write(
            Data([0x0A])
        )
    }

    public static func text(
        _ envelope: AgenticToolHostEnvelope
    ) throws -> String {
        let data = try AgenticToolHostJSON.encode(
            envelope,
            prettyPrinted: true
        )

        return String(
            decoding: data,
            as: UTF8.self
        )
    }

    public static func writeError(
        _ error: Swift.Error,
        commandName: String
    ) {
        let message: String

        if let localized = error as? LocalizedError,
           let description = localized.errorDescription
        {
            message = description
        } else {
            message = String(
                describing: error
            )
        }

        guard let data = "\(commandName): \(message)\n"
            .data(using: .utf8)
        else {
            return
        }

        FileHandle.standardError.write(
            data
        )
    }

}
