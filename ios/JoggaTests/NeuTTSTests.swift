import XCTest
@testable import Jogga

final class NeuTTSTests: XCTestCase {

    // MARK: Stream math (fake decoder: each code → 480 samples of its value)

    private func fakeDecode(_ codes: [Int32]) -> [Float] {
        codes.flatMap { [Float](repeating: Float($0), count: 480) }
    }

    private func streamAll(_ n: Int) -> [Float] {
        var stream = NeuTTSStream(refCodes: [])
        var out: [Float] = []
        for i in 0..<n {
            if let chunk = try? stream.push(Int32(i + 1), decode: fakeDecode) {
                out += chunk
            }
        }
        if let tail = try? stream.finish(decode: fakeDecode) { out += tail }
        return out
    }

    func testStreamMatchesFullDecode() throws {
        for n in [10, 30, 31, 137] {
            let codes = (1...n).map { Int32($0) }
            let full = fakeDecode(codes)
            let streamed = streamAll(n)
            // Full chunks (25 tokens, 12000 samples) assemble exactly like a
            // whole-run decode; the Python tail decode intentionally starts
            // one overlap frame (480 samples) early, so the tail region is
            // the full decode shifted by 480 with a 960-sample blend at the
            // last chunk boundary.
            let chunks = n >= 30 ? (n - 30) / 25 + 1 : 0
            let tailStart = chunks * 12000
            XCTAssertEqual(streamed.count, full.count + (chunks > 0 ? 480 : 0),
                           "n=\(n)")
            for i in 0..<tailStart {
                XCTAssertEqual(streamed[i], full[i], accuracy: 1e-5,
                               "n=\(n) sample \(i)")
            }
            if chunks > 0 {
                let blend = 960
                for i in (tailStart + blend)..<streamed.count {
                    XCTAssertEqual(streamed[i], full[i - 480], accuracy: 1e-3,
                                   "n=\(n) tail sample \(i)")
                }
            }
        }
    }

    // MARK: Speech token piece parsing

    func testSpeechCodeParsing() {
        XCTAssertEqual(NeuTTSVoice.speechCode("<|speech_42|>"), 42)
        XCTAssertEqual(NeuTTSVoice.speechCode("<|speech_0|>"), 0)
        XCTAssertNil(NeuTTSVoice.speechCode("hello"))
        XCTAssertNil(NeuTTSVoice.speechCode("<|SPEECH_GENERATION_END|>"))
        XCTAssertNil(NeuTTSVoice.speechCode("<|speech_x|>"))
    }

    // MARK: Prompt format vs neutts.py `_ggml_prompt` (BPE branch)

    func testPromptFormat() {
        let ref = "What we need, helping us."
        let neutral = NeuTTSBackbone.prompt(
            refCodes: [7, 8], refText: ref, text: "Run on.", emotion: .neutral
        )
        XCTAssertEqual(
            neutral,
            "<|TEXT_PROMPT_START|>What we need, helping us. Run on."
            + "<|TEXT_PROMPT_END|><|SPEECH_GENERATION_START|>"
            + "<|speech_7|><|speech_8|>"
        )
        let happy = NeuTTSBackbone.prompt(
            refCodes: [7], refText: "it’s “fine”", text: "Go.", emotion: .happy
        )
        XCTAssertEqual(
            happy,
            "<|TEXT_PROMPT_START|>it's \"fine\"<|HAPPY|>Go."
            + "<|TEXT_PROMPT_END|><|SPEECH_GENERATION_START|><|speech_7|>"
        )
    }

    // MARK: Integration — real synthesis on the bundled models

    func testSynthesizesAudibleAudio() throws {
        try XCTSkipUnless(NeuTTSVoice.modelsBundled,
                          "VoiceModels not bundled in this build")
        let voice = NeuTTSVoice()
        voice.prepare()
        // Wait for background load + warm-up.
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline, !voice.isReady {
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(voice.isReady, "voice never became ready")
        guard let pcm = voice.render("Kilometre one done.", emotion: .neutral)
        else { return XCTFail("render returned nil") }
        let start = Date()
        let again = voice.render("Kilometre one done.", emotion: .neutral)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(pcm.count, Int(0.5 * 24000))
        let rms = sqrt(pcm.map { $0 * $0 }.reduce(0, +)
                       / Float(pcm.count))
        XCTAssertGreaterThan(rms, 0.0005, "audio is silent")
        let audioS = Double((again ?? pcm).count) / 24000
        let summary = String(
            format: "neutts: render %.2f s for %.2f s audio",
            elapsed, audioS)
        print(summary)
    }

    /// Writes a WAV of the settings-preview line (whole line, single decode,
    /// sophie) to ~/plans/audio/ so the owner can listen to it.
    func testWritePreviewWAV() throws {
        try XCTSkipUnless(NeuTTSVoice.modelsBundled,
                          "VoiceModels not bundled in this build")
        let voice = NeuTTSVoice(speaker: "sophie")
        voice.prepare()
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline, !voice.isReady {
            Thread.sleep(forTimeInterval: 0.5)
        }
        var pcm: [Float]?
        if voice.isReady {
            pcm = voice.render(Self.previewText, emotion: .happy)
        }
        let samples = try XCTUnwrap(pcm, "no audio rendered")
        let dir = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0].appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("whole_line_single_decode.wav")
        try Self.writeWAV(samples: samples, sampleRate: 24000, to: url)
        print("neutts: WAV at \(url.path) "
              + "(\(String(format: "%.1f", Double(samples.count) / 24000)) s)")
    }

    private static let previewText =
        "Last kilometre split, five minutes thirty-six seconds. "
        + "Distance so far, three kilometres in seventeen minutes "
        + "twenty-six seconds. That's good progress compared to your PB."

    /// Prints the speed-test lines (2 vs 4 threads) for the report.
    func testSpeedComparison() throws {
        try XCTSkipUnless(NeuTTSVoice.modelsBundled,
                          "VoiceModels not bundled in this build")
        let voice = NeuTTSVoice(speaker: "sophie")
        voice.prepare()
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline, !voice.isReady {
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard voice.isReady else { return XCTFail("voice never ready") }
        for threads in [Int32(2), Int32(4)] {
            guard let r = voice.speedTestRender(
                Self.previewText, threads: threads) else {
                return XCTFail("render at \(threads) threads failed")
            }
            let tok = Double(r.stats.genTokens ?? 0)
            let genS = r.stats.genS ?? 0
            let audioS = r.stats.audioS ?? 0
            let rt = audioS > 0 ? (r.stats.synthS ?? 0) / audioS : 0
            print(String(
                format:
                  "%d threads: prefill %.1f s · %d tok in %.1f s (%.0f tok/s) "
                + "· decode %.1f s · %.1f s audio · %.2f× real time",
                threads, r.stats.prefillS ?? 0, Int(tok), genS,
                genS > 0 ? tok / genS : 0, r.stats.decodeS ?? 0, audioS, rt))
        }
    }

    static func writeWAV(samples: [Float], sampleRate: Int, to url: URL) throws {
        var data = Data()
        let dataSize = UInt32(samples.count * 2)
        func w(_ s: String) { data.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) {
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }
        func u16(_ v: UInt16) {
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }
        w("RIFF"); u32(36 + dataSize); w("WAVE")
        w("fmt "); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        w("data"); u32(dataSize)
        for s in samples {
            let clamped = max(-1, min(1, s))
            u16(UInt16(bitPattern: Int16(clamped * 32767)))
        }
        try data.write(to: url)
    }
}
