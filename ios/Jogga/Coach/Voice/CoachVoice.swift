import Foundation

/// Spoken delivery style for a cue.
enum VoiceEmotion {
    case neutral, happy
}

/// Anything that can speak a cue aloud. Implementations: SystemVoice
/// (AVSpeechSynthesizer) and NeuTTSVoice (on-device Neuphonic model).
protocol CoachVoice: AnyObject {
    var isSpeaking: Bool { get }
    /// Called on the main thread when speech finishes or is cancelled.
    var onFinish: (() -> Void)? { get set }
    /// Called on the main thread once timing stats for the utterance are
    /// known (nil stats = no synthesis metrics, e.g. the system voice).
    var onStats: ((CoachVoiceStats) -> Void)? { get set }
    func speak(_ text: String, emotion: VoiceEmotion)
    func stop()
}

/// Synthesis timing for a spoken cue.
struct CoachVoiceStats: Equatable {
    var voice: String
    var firstAudioMs: Int?
    var synthS: Double?
    var audioS: Double?
    var prefillS: Double?
    var genTokens: Int?
    var genS: Double?
    var decodeS: Double?
}

extension VoiceEmotion {
    /// Positive progress splits get the happy tag; everything else neutral.
    static func forEvent(_ event: CueEvent) -> VoiceEmotion {
        guard case let .split(_, _, _, _, progress) = event else { return .neutral }
        switch progress {
        case .aheadOfTarget, .aheadOfPB, .onPB: return .happy
        case let .vsRun(_, deltaS): return deltaS < 0 ? .happy : .neutral
        default: return .neutral
        }
    }
}

/// Which voice the coach uses; stored in "jogga.coachVoice". The Neuphonic
/// choices map onto the shipped sophie/steven references.
enum CoachVoiceChoice: String, CaseIterable {
    case sophie, steven, system

    var label: String {
        switch self {
        case .sophie: return "Female (Sophie)"
        case .steven: return "Male (Steven)"
        case .system: return "iPhone voice"
        }
    }

    /// The NeuTTS speaker file, when this is a Neuphonic choice.
    var speaker: String? {
        switch self {
        case .sophie: return "sophie"
        case .steven: return "steven"
        case .system: return nil
        }
    }

    static var current: CoachVoiceChoice {
        switch UserDefaults.standard.string(forKey: "jogga.coachVoice") {
        case "sophie", "emily", "paul": return .sophie
        case "steven": return .steven
        case "system": return .system
        default:
            return NeuTTSVoice.modelsBundled ? .sophie : .system
        }
    }

    /// A voice for the current choice; Neuphonic picks get a NeuTTSVoice
    /// only when the models are bundled.
    static func make() -> CoachVoice {
        if let speaker = current.speaker, NeuTTSVoice.modelsBundled {
            return NeuTTSVoice(speaker: speaker)
        }
        return SystemVoice()
    }
}
