import AVFAudio
import Foundation

/// Speaks cues with the best installed en-GB system voice, ducking other
/// audio and releasing the session when each utterance ends.
final class SystemVoice: NSObject, AVSpeechSynthesizerDelegate, CoachVoice {
    private let synth = AVSpeechSynthesizer()
    private(set) var isSpeaking = false
    /// Called on the main thread when an utterance finishes or is cancelled.
    var onFinish: (() -> Void)?
    var onStats: ((CoachVoiceStats) -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String, emotion: VoiceEmotion = .neutral) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playback, mode: .voicePrompt,
            options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
        )
        try? session.setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestVoice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.preUtteranceDelay = 0.15
        isSpeaking = true
        synth.speak(utterance)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        done()
    }

    /// Best-quality installed en-GB voice: premium > enhanced > default.
    private static func bestVoice() -> AVSpeechSynthesisVoice? {
        let installed = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.replacingOccurrences(of: "_", with: "-")
                .hasPrefix("en-GB") }
        let ranked = installed.max { a, b in rank(a) < rank(b) }
        return ranked ?? AVSpeechSynthesisVoice(language: "en-GB")
    }

    private static func rank(_ voice: AVSpeechSynthesisVoice) -> Int {
        switch voice.quality {
        case .premium: return 3
        case .enhanced: return 2
        default: return 1
        }
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) { done() }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) { done() }

    private func done() {
        isSpeaking = false
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
        onFinish?()
    }
}
