import Foundation
import llama

/// Thin wrapper over the llama.cpp C API driving the NeuTTS-2E GGUF backbone.
/// CPU only — iOS forbids GPU work while the phone is locked mid-run.
final class NeuTTSBackbone {
    static let maxContext: Int32 = 2048
    static let batch: Int32 = 2048
    /// Generation threads; jogga.neuttsThreads, default 2.
    static var threads: Int32 {
        let stored = UserDefaults.standard.integer(forKey: "jogga.neuttsThreads")
        return Int32(stored > 0 ? stored : 2)
    }

    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?

    enum Error: Swift.Error { case modelLoad, contextInit, decode }

    init(path: String) throws {
        llama_backend_init()
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 0
        // Explicit CPU device list: never touch Metal.
        var devices: [ggml_backend_dev_t?] = [
            ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU), nil
        ]
        let loaded = devices.withUnsafeMutableBufferPointer { buf in
            modelParams.devices = UnsafeMutablePointer(buf.baseAddress)
            return llama_model_load_from_file(path, modelParams)
        }
        guard let loaded else { throw Error.modelLoad }
        model = loaded

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = UInt32(Self.maxContext)
        ctxParams.n_batch = UInt32(Self.batch)
        ctxParams.n_threads = Self.threads
        ctxParams.n_threads_batch = Self.threads
        ctxParams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_DISABLED
        ctxParams.op_offload = false
        ctxParams.offload_kqv = false
        guard let c = llama_init_from_model(loaded, ctxParams) else {
            throw Error.contextInit
        }
        ctx = c
        vocab = llama_model_get_vocab(loaded)
    }

    func unload() {
        ctx.map { llama_free($0) }
        ctx = nil
        model.map { llama_model_free($0) }
        model = nil
        vocab = nil
    }

    deinit { unload() }

    /// BPE prompt per neutts.py `_ggml_prompt` (non-phoneme branch).
    static func prompt(
        refCodes: [Int32], refText: String, text: String, emotion: VoiceEmotion
    ) -> String {
        let codes = refCodes.map { "<|speech_\($0)|>" }.joined()
        let ref = normalize(refText)
        let input = normalize(text)
        let body: String
        switch emotion {
        case .neutral: body = "\(ref) \(input)"
        case .happy: body = "\(ref)<|HAPPY|>\(input)"
        }
        return "<|TEXT_PROMPT_START|>\(body)<|TEXT_PROMPT_END|>"
            + "<|SPEECH_GENERATION_START|>\(codes)"
    }

    /// NFKC + curly-quote normalisation (neutts.py `_normalize_text`).
    static func normalize(_ text: String) -> String {
        let mapped = text
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
        return mapped.precomposedStringWithCompatibilityMapping
    }

    /// Tokenize with add_special = true, parse_special = true.
    func tokenize(_ text: String) -> [llama_token] {
        guard let vocab else { return [] }
        return text.withCString { cstr in
            // Negative return = required token count when the buffer is NULL.
            let n = llama_tokenize(
                vocab, cstr, Int32(text.utf8.count), nil, 0, true, true
            )
            let needed = Int(n < 0 ? -n : n)
            guard needed > 0 else { return [] }
            var tokens = [llama_token](repeating: 0, count: needed)
            let written = llama_tokenize(
                vocab, cstr, Int32(text.utf8.count),
                &tokens, Int32(tokens.count), true, true
            )
            return Array(tokens.prefix(Int(written)))
        }
    }

    /// One sampled token: its id and rendered piece (special tokens included).
    struct Piece { var token: llama_token; var text: String }

    /// Change generation threads on the live context.
    func setThreads(_ n: Int32) {
        guard let ctx else { return }
        llama_set_n_threads(ctx, n, n)
    }

    /// Wall-clock split for one generate() call.
    struct GenStats {
        var prefillS: Double = 0
        var genS: Double = 0
        var tokens: Int = 0
    }

    /// Streams generation: prefill the prompt, then sample with
    /// top_k 50 → temp 1.0 → dist(seed) until EOG,
    /// <|SPEECH_GENERATION_END|>, the 2048-token context cap, or `onPiece`
    /// returns false. KV memory is cleared before each call.
    func generate(
        prompt: String, seed: UInt32, stats: inout GenStats,
        onPiece: (Piece) -> Bool
    ) throws {
        guard let ctx, let vocab else { throw Error.contextInit }
        llama_memory_clear(llama_get_memory(ctx), true)
        var promptTokens = tokenize(prompt)
        guard !promptTokens.isEmpty else { throw Error.decode }

        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(50))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(1.0))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(seed))
        defer { llama_sampler_free(sampler) }

        var total = promptTokens.count
        let prefillAt = Date()
        try promptTokens.withUnsafeMutableBufferPointer { buf in
            let b = llama_batch_get_one(buf.baseAddress, Int32(buf.count))
            let rc = llama_decode(ctx, b)
            guard rc == 0 else {
                NSLog("NeuTTSBackbone: prefill decode rc=%d tokens=%d",
                      rc, buf.count)
                throw Error.decode
            }
        }
        stats.prefillS = Date().timeIntervalSince(prefillAt)
        let genAt = Date()
        defer { stats.genS = Date().timeIntervalSince(genAt) }

        var buf = [CChar](repeating: 0, count: 64)
        while total < Self.maxContext {
            let token = llama_sampler_sample(sampler, ctx, -1)
            guard !llama_vocab_is_eog(vocab, token) else { break }
            stats.tokens += 1
            var piece = ""
            let n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, true)
            if n > 0 {
                if Int(n) < buf.count { buf[Int(n)] = 0 }
                piece = String(cString: buf)
            }
            if piece == "<|SPEECH_GENERATION_END|>" { break }
            if !onPiece(Piece(token: token, text: piece)) { break }
            var t = token
            let b = llama_batch_get_one(&t, 1)
            let rc = llama_decode(ctx, b)
            guard rc == 0 else {
                NSLog("NeuTTSBackbone: step decode rc=%d at %d", rc, total)
                throw Error.decode
            }
            total += 1
        }
    }
}
