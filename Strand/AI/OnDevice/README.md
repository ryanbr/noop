# On-Device Coach (iOS)

A fifth AI Coach provider (`AIProvider.onDevice`) that runs a small LLM **entirely on
the iPhone** via in-process llama.cpp — no server, no API key, and (after a one-time
model download) no network. It is the default, front-and-center coach on iOS; the
cloud BYOK providers (OpenAI/Anthropic/Gemini/Custom) remain available.

## How it fits

It conforms to the existing `AIProviderClient` protocol, so the whole coach pipeline —
context building, consent gating, chat history/windowing, and `CoachView` — is reused
unchanged. We added a provider, not a parallel coach.

```
CoachView ─▶ AICoachEngine (sendStreaming / stop, owns ModelDownloadManager)
                  │  provider == .onDevice
                  ▼
            OnDeviceClient : AIProviderClient   (no URLSession, no HTTP)
                  ▼
            LlamaEngine (actor)  ──C API──▶  llama.cpp xcframework (Metal)
                  ▲
            ModelDownloadManager  (first-run GGUF fetch + SHA-256 verify)
```

## Files

- `ModelCatalog.swift` — the pinned model (`BundledModel`), on-disk paths (`ModelStorage`),
  and the RAM device gate. Pure, macOS + iOS.
- `ModelDownloadManager.swift` — first-run download state machine + streaming SHA-256
  verify + delete. Pure, macOS + iOS.
- `LlamaEngine.swift` — Swift `actor` wrapping llama.cpp (load/unload/generate, token
  streaming). **iOS only** (excluded from the macOS target).
- `OnDeviceClient.swift` — `AIProviderClient` conformance driving `LlamaEngine`. **iOS only**.
- llama.cpp is a pinned prebuilt binary xcframework: `Packages/LlamaCpp` (URL + checksum).

## Privacy / network posture

Coach **inference is 100% offline**. The only network activity is the **one-time,
user-initiated** download of the public model weights (opposite direction — no user
data leaves the device). The `CoachView` privacy copy reflects this for `.onDevice`.

## Runtime notes

- Model: **Llama-3.2-3B-Instruct Q4_K_M** (~2 GB), Metal-accelerated (`n_gpu_layers = -1`),
  `n_ctx = 4096`, `n_batch = n_ctx` so the full coach context prefills in one decode.
- Memory: needs the `com.apple.developer.kernel.increased-memory-limit` entitlement.
  `AICoachEngine.installMemoryGuards()` unloads the model on critical memory pressure
  (when idle) and on app backgrounding, reloading lazily on the next turn. Devices below
  ~6 GB RAM are gated out (`ModelCatalog.deviceMeetsRequirements`).
- Downloaded weights live in `Application Support/OnDeviceModels/<id>.gguf`, excluded
  from iCloud/iTunes backup.

## Changing the model

Update **every** field of `ModelCatalog.coach` together (`id`, `url`, `sha256`,
`sizeBytes`, `contextLength`, `chatTemplate`). The `sha256` must match the file:

```sh
curl -L "<url>" -o m.gguf && shasum -a 256 m.gguf   # → sha256
```

## Bumping llama.cpp

Update **both** the `url` and `checksum` in `Packages/LlamaCpp/Package.swift` together
(a llama.cpp release that publishes a `llama-b<NNNN>-xcframework.zip` asset):

```sh
curl -L -o llama.zip "https://github.com/ggml-org/llama.cpp/releases/download/b<NNNN>/llama-b<NNNN>-xcframework.zip"
swift package compute-checksum llama.zip
```

Then re-verify the `LlamaEngine.swift` C calls still match that release's `llama.h`.
The currently pinned release is **b9947**.

## Building / verifying iOS locally

The `NOOPiOS` scheme embeds the watch app, which some environments can't build. To
compile-check the iOS app on its own, build `NOOPiOS` for the simulator with the
`NOOPWatch` dependency temporarily removed from `project.yml` (restore it afterward —
never commit the watch-dropped state). CI (`app-build.yml`, macos-15) builds the full
scheme.

## Device verification (not covered by CI)

The native path (Metal inference, real memory behavior) is validated on a physical
iPhone (≥ 6 GB RAM): download → verify → stream a reply → Stop mid-stream → background
unload/reload → measure tokens/sec and peak memory (Instruments) → confirm no jetsam →
delete reclaims ~2 GB.
