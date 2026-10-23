import AVFAudio
import Foundation

/// On-device Neuphonic NeuTTS-2E voice: llama.cpp backbone + NeuCodec ONNX
/// decoder. Renders each cue whole (one decode over all speech codes) then
/// plays it through an AVAudioEngine. No system-voice fallback: when a
/// Neuphonic voice is selected, it is the only voice.
final class NeuTTSVoice: CoachVoice {
    static let sampleRate: Double = 24_000
    /// Render must finish inside this or it's treated as failed.
    static let renderTimeout: TimeInterval = 45
    static let defaultSpeaker = "sophie"
    static let speakers = ["sophie", "steven"]

    let speaker: String
    private(set) var isSpeaking = false
    var onFinish: (() -> Void)?
    var onStats: ((CoachVoiceStats) -> Void)?
    /// Called on the main thread when a cue can't be spoken at all.
    var onFailed: ((String) -> Void)?

    private let workQueue = DispatchQueue(label: "jogga.neutts", qos: .userInitiated)
    private var backbone: NeuTTSBackbone?
    private var decoder: NeuCodecDecoder?
    private var refCodes: [Int32] = []
    private var refText = ""
    private(set) var isReady = false

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var pending = 0
    private var generation = 0
    private var firstAudioAt: Date?
    private var speakAt = Date.distantPast
    private var renderLock = NSLock()

    init(speaker: String = NeuTTSVoice.defaultSpeaker) {
        self.speaker = Self.speakers.contains(speaker)
            ? speaker : Self.defaultSpeaker
    }

    /// "Sophie" — used in stats and the cue-log caption.
    var voiceName: String { speaker.capitalized }

    /// True when the VoiceModels bundle is shipped in this build.
    static var modelsBundled: Bool { modelURLs != nil }

    private static var modelURLs: (gguf: URL, codec: URL)? {
        guard let dir = Bundle.main.url(forResource: "VoiceModels",
                                        withExtension: nil) else { return nil }
        let gguf = dir.appendingPathComponent("neutts-2e-Q4_0.gguf")
        let codec = dir.appendingPathComponent("neucodec-int8.onnx")
        guard FileManager.default.fileExists(atPath: gguf.path),
              FileManager.default.fileExists(atPath: codec.path) else {
            return nil
        }
        return (gguf, codec)
    }

    /// The bundled NeuTTS licence text, shown in Settings.
    static var licenseText: String? {
        guard let dir = Bundle.main.url(forResource: "VoiceModels",
                                        withExtension: nil),
              let text = try? String(
                  contentsOf: dir.appendingPathComponent("NEUTTS_LICENSE"),
                  encoding: .utf8)
        else { return nil }
        return text
    }

    /// Speaker reference (codes + transcript), committed under Resources.
    private static func loadReference(
        _ speaker: String
    ) -> (codes: [Int32], text: String)? {
        guard let url = Bundle.main.url(forResource: "\(speaker).ref",
                                        withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let ref = try? JSONDecoder().decode(Reference.self, from: data)
        else { return nil }
        return (ref.codes, ref.text)
    }

    private struct Reference: Decodable { var codes: [Int32]; var text: String }

    /// Load models and run a throwaway synthesis off the main thread so the
    /// first real cue isn't paying model-load latency.
    func prepare() {
        guard Self.modelsBundled else { return }
        workQueue.async { [weak self] in
            guard let self else { return }
            do {
                guard let urls = Self.modelURLs,
                      let ref = Self.loadReference(self.speaker) else { return }
                self.backbone = try NeuTTSBackbone(path: urls.gguf.path)
                self.decoder = try NeuCodecDecoder(path: urls.codec.path)
                self.refCodes = ref.codes
                self.refText = ref.text
                _ = self.render("Warming up.", emotion: .neutral)
                self.isReady = true
            } catch {
                self.backbone = nil
                self.decoder = nil
            }
        }
    }

    func unload() {
        generation += 1
        workQueue.async { [weak self] in
            self?.backbone?.unload()
            self?.backbone = nil
            self?.decoder = nil
            self?.isReady = false
        }
    }

    func speak(_ text: String, emotion: VoiceEmotion) {
        isSpeaking = true
        speakAt = .now
        firstAudioAt = nil
        generation += 1
        let id = generation
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playback, mode: .voicePrompt,
            options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
        )
        try? session.setActive(true)

        // Queued behind prepare() on the serial work queue, so a cue that
        // lands while the models are still loading is rendered right after.
        workQueue.async { [weak self] in
            guard let self, self.generation == id else { return }
            guard let pcm = self.renderTimed(text, emotion: emotion, id: id)
            else { self.fail(id: id); return }
            guard self.generation == id else { return }
            let audioS = Double(pcm.samples.count) / Self.sampleRate
            self.schedule(pcm.samples, id: id)
            DispatchQueue.main.async {
                self.onStats?(CoachVoiceStats(
                    voice: self.voiceName,
                    firstAudioMs: self.firstAudioAt.map {
                        Int($0.timeIntervalSince(self.speakAt) * 1000)
                    },
                    synthS: pcm.synthS,
                    audioS: audioS,
                    prefillS: pcm.prefillS,
                    genTokens: pcm.genTokens,
                    genS: pcm.genS,
                    decodeS: pcm.decodeS
                ))
            }
            if pcm.samples.isEmpty, self.generation == id {
                self.fail(id: id)
            }
        }
    }

    func stop() {
        generation += 1
        player.stop()
        engine.stop()
        if isSpeaking {
            isSpeaking = false
            try? AVAudioSession.sharedInstance()
                .setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private struct Rendered {
        var samples: [Float]
        var synthS: Double
        var prefillS: Double
        var genTokens: Int
        var genS: Double
        var decodeS: Double
    }

    /// Single-decode render with per-phase timing; nil on any failure or
    /// when generation/id is stale (e.g. cancelled).
    private func renderTimed(
        _ text: String, emotion: VoiceEmotion, id: Int? = nil
    ) -> Rendered? {
        guard let backbone, let decoder else { return nil }
        renderLock.lock()
        defer { renderLock.unlock() }
        let started = Date()
        let deadline = started.addingTimeInterval(Self.renderTimeout)
        let prompt = NeuTTSBackbone.prompt(
            refCodes: refCodes, refText: refText, text: text, emotion: emotion
        )
        var codes: [Int32] = []
        var stats = NeuTTSBackbone.GenStats()
        do {
            try backbone.generate(
                prompt: prompt,
                seed: UInt32.random(in: 0...UInt32.max),
                stats: &stats
            ) { piece in
                guard Date() < deadline else { return false }
                if let id, self.generation != id { return false }
                if let code = Self.speechCode(piece.text) { codes.append(code) }
                return true
            }
        } catch {
            NSLog("NeuTTSVoice: generate failed: %@", "\(error)")
            return nil
        }
        guard !codes.isEmpty, Date() < deadline else { return nil }
        let decodeAt = Date()
        guard let pcm = try? decoder.decode(codes) else {
            NSLog("NeuTTSVoice: decode failed")
            return nil
        }
        let decodeS = Date().timeIntervalSince(decodeAt)
        guard !pcm.isEmpty else { return nil }
        return Rendered(
            samples: pcm, synthS: Date().timeIntervalSince(started),
            prefillS: stats.prefillS, genTokens: stats.tokens,
            genS: stats.genS, decodeS: decodeS
        )
    }

    /// Whole-utterance render with no playback — used by tests, warm-up and
    /// the Settings speed test. Returns nil when the models aren't loaded.
    func render(_ text: String, emotion: VoiceEmotion) -> [Float]? {
        renderTimed(text, emotion: emotion)?.samples
    }

    /// Render for the speed test at a given thread count; restores the
    /// configured count afterwards. Returns audio + per-phase timings.
    func speedTestRender(_ text: String, threads: Int32)
        -> (pcm: [Float], stats: CoachVoiceStats)? {
        guard backbone != nil else { return nil }
        backbone?.setThreads(threads)
        let rendered = renderTimed(text, emotion: .neutral)
        backbone?.setThreads(NeuTTSBackbone.threads)
        guard let rendered else { return nil }
        let stats = CoachVoiceStats(
            voice: voiceName,
            firstAudioMs: nil,
            synthS: rendered.synthS,
            audioS: Double(rendered.samples.count) / Self.sampleRate,
            prefillS: rendered.prefillS,
            genTokens: rendered.genTokens,
            genS: rendered.genS,
            decodeS: rendered.decodeS
        )
        return (rendered.samples, stats)
    }

    /// Play already-rendered PCM (Settings speed test).
    func play(_ pcm: [Float]) {
        guard !pcm.isEmpty else { return }
        isSpeaking = true
        generation += 1
        let id = generation
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playback, mode: .voicePrompt,
            options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
        )
        try? session.setActive(true)
        schedule(pcm, id: id)
    }

    /// <|speech_N|> → N, else nil.
    static func speechCode(_ piece: String) -> Int32? {
        guard piece.hasPrefix("<|speech_"), piece.hasSuffix("|>") else {
            return nil
        }
        return Int32(piece.dropFirst(9).dropLast(2))
    }

    private func schedule(_ samples: [Float], id: Int) {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                        frameCapacity: AVAudioFrameCount(samples.count))
        else { fail(id: id); return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData?[0].update(from: src.baseAddress!, count: samples.count)
        }
        DispatchQueue.main.async {
            guard self.generation == id else { return }
            if !self.engine.isRunning {
                self.engine.attach(self.player)
                self.engine.connect(self.player, to: self.engine.mainMixerNode,
                                    format: format)
                try? self.engine.start()
            }
            self.pending += 1
            if self.firstAudioAt == nil { self.firstAudioAt = .now }
            self.player.scheduleBuffer(buffer) {
                DispatchQueue.main.async {
                    self.pending -= 1
                    if self.pending <= 0, self.isSpeaking, self.generation == id {
                        self.isSpeaking = false
                        try? AVAudioSession.sharedInstance().setActive(
                            false, options: .notifyOthersOnDeactivation)
                        self.onFinish?()
                    }
                }
            }
            self.player.play()
        }
    }

    private func fail(id: Int) {
        DispatchQueue.main.async {
            guard self.generation == id else { return }
            self.isSpeaking = false
            try? AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation)
            self.onFailed?(self.voiceName)
            self.onFinish?()
        }
    }
}
