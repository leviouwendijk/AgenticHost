import AgenticInterfaces
import AgenticRuntime

public protocol AgenticVoiceInputProviding:
    AgenticApplicationProviding
{
    static var voiceInputProvider: (any VoiceInputProvider)? {
        get
    }
}

public extension AgenticApplicationProviding {
    static var hostVoiceInputProvider: (any VoiceInputProvider)? {
        (Self.self as? any AgenticVoiceInputProviding.Type)?
            .voiceInputProvider
    }
}
