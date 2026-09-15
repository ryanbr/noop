import Foundation
import LlamaCpp

/// In-process llama.cpp wrapper. An `actor` so the C context is never touched concurrently. iOS-only.
///
/// All raw llama.cpp pointers (`model`/`ctx`/`vocab`) are confined to this actor's isolation domain:
/// they are declared `private`, and every C call that reads them runs inside an actor-isolated method.
/// `generate` is `nonisolated` only so it can synchronously hand back an `AsyncStream`; the actual
/// decode loop runs in `runGeneration`, hopping onto the actor before touching any pointer.
actor LlamaEngine {
    static let shared = LlamaEngine()

    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private var loadedModel: BundledModel?

    /// Load a GGUF into a llama context with Metal enabled. Idempotent: reloads only when the target
    /// differs from what's loaded. Throws `AICoachError.modelLoadFailed` on any C failure.
    func load(modelURL: URL, model: BundledModel) async throws {
        if loadedModel?.id == model.id, ctx != nil { return }
        unload()

        llama_backend_init()

        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = -1                    // all layers on the Metal GPU
        guard let m = llama_model_load_from_file(modelURL.path, mparams) else {
            throw AICoachError.modelLoadFailed("could not open \(model.id)")
        }

        var cparams = llama_context_default_params()
        cparams.n_ctx = UInt32(model.contextLength)
        // n_batch MUST stay = n_ctx: runGeneration prefills the whole prompt (up to ~n_ctx tokens) in a
        // SINGLE llama_decode (llama_batch_get_one) after clearing the KV cache, so the logical batch must
        // be able to hold the full prompt. Do NOT lower n_batch below n_ctx or large prompts silently fail
        // to prefill. n_ubatch (physical batch) is what bounds compute-buffer memory — pin it at 512.
        cparams.n_batch = UInt32(model.contextLength)
        cparams.n_ubatch = 512
        // Flash Attention: cuts KV-cache memory bandwidth and speeds prefill/decode on Metal. b9947's
        // default is AUTO; force ENABLED. One line to revert to LLAMA_FLASH_ATTN_TYPE_AUTO — verify
        // tokens/sec + output coherence on device.
        cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
        // All transformer layers run on the Metal GPU (n_gpu_layers = -1), so the CPU only samples/book-
        // keeps; pin a small thread count so we don't oversubscribe the efficiency cores (thermal jitter).
        let threads = Int32(max(2, min(4, ProcessInfo.processInfo.processorCount)))
        cparams.n_threads = threads
        cparams.n_threads_batch = threads
        guard let c = llama_init_from_model(m, cparams) else {
            llama_model_free(m)
            throw AICoachError.modelLoadFailed("could not create context")
        }

        self.model = m
        self.ctx = c
        self.vocab = llama_model_get_vocab(m)
        self.loadedModel = model
    }

    /// Free the context + model. Safe to call when nothing is loaded.
    func unload() {
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
        ctx = nil; model = nil; vocab = nil; loadedModel = nil
    }

    var isLoaded: Bool { ctx != nil }

    /// Generate a reply, yielding detokenized text pieces as they are produced. Stops on EOS, the
    /// 512-token cap, or `Task` cancellation. Applies the model's chat template. Assumes a model is
    /// already loaded (the caller loads via `load`); yields nothing and finishes if none is loaded.
    nonisolated func generate(systemPrompt: String,
                              messages: [(role: ChatMessage.Role, content: String)]) -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task {
                await self.runGeneration(systemPrompt: systemPrompt,
                                         messages: messages,
                                         into: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Actor-isolated decode loop. All C pointer access happens here so nothing escapes isolation.
    private func runGeneration(systemPrompt: String,
                               messages: [(role: ChatMessage.Role, content: String)],
                               into continuation: AsyncStream<String>.Continuation) {
        guard let ctx = self.ctx, let vocab = self.vocab, let model = self.model else { return }
        let maxTokens = 512

        // 1. Build the prompt via the model's chat template.
        let prompt = applyTemplate(model: model, systemPrompt: systemPrompt, messages: messages)

        // 2. Tokenize.
        var tokens = tokenize(vocab: vocab, text: prompt, addBOS: true)
        guard !tokens.isEmpty else { return }

        // 2b. Reset the KV cache so this generation starts at position 0. The context is reused across
        // turns (the model stays loaded), and `llama_batch_get_one` auto-assigns positions continuing
        // from the current `n_past` — so without this clear, each turn's full-conversation prefill is
        // appended ON TOP of the previous turns' KV, and cumulative positions overrun `n_ctx` after a
        // few turns (`llama_decode` then fails and the reply comes back empty). We already re-send the
        // entire conversation via `applyTemplate`, so clearing here is both the fix and more correct.
        llama_memory_clear(llama_get_memory(ctx), true)

        // 3. Prefill. The token buffer must stay alive across the decode call.
        let prefilled = tokens.withUnsafeMutableBufferPointer { buf -> Bool in
            let batch = llama_batch_get_one(buf.baseAddress, Int32(buf.count))
            return llama_decode(ctx, batch) == 0
        }
        guard prefilled else { return }

        // 4. Sampler chain (greedy-ish: top-k / top-p / temp). Freed at the end.
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.95, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.7))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(LLAMA_DEFAULT_SEED))
        defer { llama_sampler_free(sampler) }

        var generated = 0
        while generated < maxTokens {
            if Task.isCancelled { break }
            let next = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, next) { break }

            if let piece = pieceToString(vocab: vocab, token: next), !piece.isEmpty {
                continuation.yield(piece)
            }

            // Feed the sampled token back in. `one` must outlive the decode call.
            var one = next
            let ok = withUnsafeMutablePointer(to: &one) { ptr -> Bool in
                let batch = llama_batch_get_one(ptr, 1)
                return llama_decode(ctx, batch) == 0
            }
            if !ok { break }
            generated += 1
        }
    }

    // MARK: - C helpers (exact symbols track the pinned llama.cpp b9947 release)

    private func applyTemplate(model: OpaquePointer, systemPrompt: String,
                               messages: [(role: ChatMessage.Role, content: String)]) -> String {
        var chat: [llama_chat_message] = []
        var cStrings: [UnsafeMutablePointer<CChar>] = []
        func cstr(_ s: String) -> UnsafeMutablePointer<CChar>? {
            guard let p = strdup(s) else { return nil }
            cStrings.append(p)
            return p
        }
        defer { cStrings.forEach { free($0) } }

        chat.append(llama_chat_message(role: cstr("system"), content: cstr(systemPrompt)))
        for m in messages {
            chat.append(llama_chat_message(role: cstr(m.role.rawValue), content: cstr(m.content)))
        }

        let tmpl = llama_model_chat_template(model, nil)
        // `llama_chat_apply_template` returns the TOTAL length; a fixed buffer silently truncated a large
        // coach prompt (system context + lab book + windowed history can exceed a fixed size), cutting the
        // user's actual question. Start modest, then grow to the returned length and re-render if needed.
        var buf = [CChar](repeating: 0, count: 8192)
        var n = llama_chat_apply_template(tmpl, chat, chat.count, true, &buf, Int32(buf.count))
        if n <= 0 { return systemPrompt + "\n\n" + (messages.last?.content ?? "") }
        if Int(n) > buf.count {
            buf = [CChar](repeating: 0, count: Int(n))
            n = llama_chat_apply_template(tmpl, chat, chat.count, true, &buf, Int32(buf.count))
            if n <= 0 { return systemPrompt + "\n\n" + (messages.last?.content ?? "") }
        }
        return buf.withUnsafeBufferPointer { p in
            String(decoding: UnsafeRawBufferPointer(start: p.baseAddress, count: Int(n)), as: UTF8.self)
        }
    }

    private func tokenize(vocab: OpaquePointer, text: String, addBOS: Bool) -> [llama_token] {
        let utf8 = Array(text.utf8)
        guard !utf8.isEmpty else { return [] }
        let byteCount = Int32(utf8.count)
        let cap = Int32(utf8.count + 8)
        var out = [llama_token](repeating: 0, count: Int(cap))
        // Use the UTF-8 byte length directly; do not re-derive it from a C string.
        let n: Int32 = utf8.withUnsafeBufferPointer { src in
            src.withMemoryRebound(to: CChar.self) { rebound in
                llama_tokenize(vocab, rebound.baseAddress, byteCount, &out, cap, addBOS, true)
            }
        }
        if n < 0 { return [] }
        return Array(out.prefix(Int(n)))
    }

    private func pieceToString(vocab: OpaquePointer, token: llama_token) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        let n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, true)
        if n <= 0 { return nil }
        return buf.withUnsafeBufferPointer { p in
            String(decoding: UnsafeRawBufferPointer(start: p.baseAddress, count: Int(n)), as: UTF8.self)
        }
    }
}
