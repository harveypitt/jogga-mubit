import Foundation

/// Streaming assembly of NeuCodec output, ported from neutts.py
/// `_infer_stream_ggml`: decode overlapping token windows and blend them with
/// a triangular overlap-add. Parameterised on the decode closure so the math
/// is unit-testable without models.
struct NeuTTSStream {
    static let framesPerChunk = 25
    static let lookforward = 5
    static let lookback = 50
    static let overlapFrames = 1
    static let hop = 480
    static var strideSamples: Int { framesPerChunk * hop }

    private(set) var tokens: [Int32]
    private var audioCache: [[Float]] = []
    private var nDecodedSamples = 0
    private var nDecodedTokens: Int

    init(refCodes: [Int32]) {
        tokens = refCodes
        nDecodedTokens = refCodes.count
    }

    /// Feed one generated speech token. Returns new PCM when a full
    /// framesPerChunk (+lookforward) window is ready, else nil.
    mutating func push(
        _ code: Int32, decode: ([Int32]) throws -> [Float]
    ) rethrows -> [Float]? {
        tokens.append(code)
        guard tokens.count - nDecodedTokens
                >= Self.framesPerChunk + Self.lookforward else { return nil }

        let start = max(nDecodedTokens - Self.lookback - Self.overlapFrames, 0)
        let end = nDecodedTokens + Self.framesPerChunk
            + Self.lookforward + Self.overlapFrames
        let sampleStart = (nDecodedTokens - start) * Self.hop
        let sampleEnd = sampleStart
            + (Self.framesPerChunk + 2 * Self.overlapFrames) * Self.hop
        var recon = try decode(Array(tokens[start..<min(end, tokens.count)]))
        recon = Array(recon[sampleStart..<min(sampleEnd, recon.count)])
        audioCache.append(recon)

        var processed = Self.linearOverlapAdd(frames: audioCache,
                                              stride: Self.strideSamples)
        let newEnd = audioCache.count * Self.strideSamples
        processed = Array(processed[nDecodedSamples..<newEnd])
        nDecodedSamples = newEnd
        nDecodedTokens += Self.framesPerChunk
        return processed
    }

    /// Final partial chunk — decoded with a non-constant window as in the
    /// Python generator's tail block. Returns remaining PCM or nil.
    mutating func finish(
        decode: ([Int32]) throws -> [Float]
    ) rethrows -> [Float]? {
        let remaining = tokens.count - nDecodedTokens
        guard remaining > 0 else { return nil }
        let start = max(
            tokens.count - (Self.lookback + Self.overlapFrames + remaining), 0
        )
        let sampleStart = (tokens.count - start - remaining
                           - Self.overlapFrames) * Self.hop
        var recon = try decode(Array(tokens[start...]))
        recon = Array(recon[max(sampleStart, 0)...])
        audioCache.append(recon)

        let processed = Self.linearOverlapAdd(frames: audioCache,
                                              stride: Self.strideSamples)
        return Array(processed[nDecodedSamples...])
    }

    /// Triangular overlap-add of 1-D frames (encodec `_linear_overlap_add`).
    static func linearOverlapAdd(
        frames: [[Float]], stride: Int, power: Float = 1
    ) -> [Float] {
        guard !frames.isEmpty else { return [] }
        var totalSize = 0
        for (i, frame) in frames.enumerated() {
            totalSize = max(totalSize, stride * i + frame.count)
        }
        var out = [Float](repeating: 0, count: totalSize)
        var weight = [Float](repeating: 0, count: totalSize)
        var offset = 0
        for frame in frames {
            let n = frame.count
            for i in 0..<n {
                // t = (i+1)/(n+1); w = (0.5 - |t - 0.5|)^power
                let t = Float(i + 1) / Float(n + 1)
                let w = powf(0.5 - abs(t - 0.5), power)
                out[offset + i] += w * frame[i]
                weight[offset + i] += w
            }
            offset += stride
        }
        for i in 0..<totalSize { out[i] /= weight[i] }
        return out
    }
}
