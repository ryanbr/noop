# On-Device Bundled LLM Coach — Design

**Date:** 2026-07-09
**Status:** Approved (design), pending implementation plan
**Platform:** iOS (NOOPiOS target) first
**Scope:** A fifth AI Coach provider that runs a small LLM entirely on-device, with no server to run and no API key.

## Summary

Add an **on-device** coach provider for iOS, powered by **in-process llama.cpp (GGUF, Metal)** running a **~3B Q4 instruct model** (default: Llama-3.2-3B-Instruct Q4_K_M). The model is **downloaded once on first run** (pinned URL, SHA-256 verified, excluded from backup), replies **stream** token-by-token, and it is positioned as the **default "no setup, fully private"** option in the existing provider picker.

The feature reuses the entire existing coach pipeline — context building, consent gating, chat history/windowing, and `CoachView` UI — by conforming to the existing `AIProviderClient` protocol. It is RAM-gated and uses the increased-memory entitlement plus memory-pressure unloading to stay within iOS limits.

## Motivation

The existing AI Coach is bring-your-own-key (BYOK) and networked: it sends a text summary of the user's metrics to a cloud provider (OpenAI/Anthropic/Gemini) or a **separately-run** local server (Ollama/LM Studio via the "Custom" provider's user-typed URL). This new feature removes both the cloud dependency and the "run your own server" friction: the app ships the ability to run a capable coach model itself, so coaching inference is **100% offline and zero-config**.

This aligns with NOOP's "offline by design" ethos. Today the coach is the one networked exception; the on-device provider makes the coach offline too, leaving only a **one-time, user-initiated model download** as network activity — which sends *no user data* (it only fetches public weights).

## Non-goals

- macOS, Android: out of scope for this first release (iOS only). The design keeps new code macOS-safe (guards, no iOS-only assumptions leaking into shared types) but does not wire up other platforms.
- A live/remote model catalog or in-app model marketplace. One pinned default model, hard-coded.
- Replacing the cloud providers. They remain available and unchanged.
- Fine-tuning, RAG, embeddings, tools/function-calling. Plain chat completion only.

## Existing architecture this builds on

- `Strand/AI/AIProvider.swift` — `AIProvider` enum (`openAI`, `anthropic`, `gemini`, `custom`) and the `AIProviderClient` protocol (`send(...) -> String`, `fetchModels(...)`).
- `Strand/AI/AICoach.swift` — `AICoachEngine` (`@MainActor ObservableObject`): chat state, provider/model selection, consent gating (`dataConsent`, `includeOnDeviceSignals`), context builders (`buildFullContext`, `buildContext`, workouts/stress/on-device-signals blocks), chat windowing, `send(_:)`, `startBriefIfNeeded()`. `isConfigured` gates setup-card vs chat.
- `Strand/AI/Providers/Custom.swift` — proves the OpenAI-shaped `AIProviderClient` seam isolates "how we talk to a model" from "what the coach does".
- `Strand/Screens/CoachView.swift` — shared macOS/iOS chat UI (StrandiOS reaches it via `RootTabView` → `CoachView()`). Branches its setup card on `provider`.
- `Strand/App/AppModel.swift` — constructs the single `AICoachEngine(repo:)`.
- `project.yml` — XcodeGen source of truth; `NOOPiOS` target, iOS deployment target 17.0.

Note: iOS 17.0 deployment target rules out Apple's Foundation Models framework (needs iOS 26), so we bring our own inference runtime.

## Architecture

```
CoachView (shared macOS/iOS, unchanged UI shell)
        │
   AICoachEngine (@MainActor, + streaming path, + download state)
        │  provider == .onDevice
        ▼
OnDeviceClient : AIProviderClient        ← new
        │  (no URLSession, no HTTP)
        ▼
LlamaEngine (Swift actor)                ← new: owns model lifecycle
        │  C API
        ▼
llama.cpp xcframework (Metal)            ← new binary dependency
        ▲
ModelDownloadManager                     ← new: first-run GGUF fetch + SHA-256 verify
```

### Runtime choice: llama.cpp (in-process)

Chosen over MLX Swift (clear #2) and MLC LLM. Rationale:

| | llama.cpp | MLX Swift | MLC LLM |
|---|---|---|---|
| Maturity on iOS | Very high, widely shipped | Growing, examples-grade | Low, heavy toolchain |
| Model/quant choice | Huge (GGUF, Q4/Q5/Q8) | Moderate (mlx-community) | Limited |
| Metal accel | Yes (ggml-metal) | Yes (native) | Yes |
| Memory tunability | Excellent (quant + ctx) | Good, needs cache tuning | Good |
| Swift integration | C API + thin wrapper | Native Swift pkg | Weakest |
| Structured output | GBNF grammars (JSON) | Manual | Manual |

llama.cpp is the lowest-risk path to a shipped feature: broadest tiny-model choice, mature Metal + memory controls, thin C API. We run it **in-process** (no HTTP server — not viable in the iOS sandbox anyway) and wrap it so it conforms to `AIProviderClient`, dropping the on-device provider straight into `AICoachEngine`. We are adding a fifth provider, not a parallel coach.

### New files

- `Strand/AI/OnDevice/LlamaEngine.swift` — Swift `actor` wrapping llama.cpp: `load(modelURL:)`, `unload()`, `generate(systemPrompt:messages:) -> AsyncStream<String>`.
- `Strand/AI/OnDevice/OnDeviceClient.swift` — `AIProviderClient` conformance calling `LlamaEngine`.
- `Strand/AI/OnDevice/ModelDownloadManager.swift` — `@MainActor ObservableObject`: download to Application Support, resume, SHA-256 verify, delete, state.
- `Strand/AI/OnDevice/ModelCatalog.swift` — the pinned default `BundledModel` + `deviceMeetsRequirements(physicalMemory:)`.
- llama.cpp binary **xcframework** added to `NOOPiOS` via `project.yml`.

## Inference engine & streaming

### `LlamaEngine` (Swift actor)

Owns the whole native lifecycle so llama.cpp state is never touched concurrently.

- `load(modelURL:) async throws` — `llama_model_load_from_file` + context creation. `n_ctx = 4096` (fits the ~1500-token metric context + system prompt + windowed history + reply). Metal enabled, `n_gpu_layers = -1` (all layers on GPU). Idempotent; unloads a prior model first.
- `unload()` — frees context/model. Called on memory pressure and provider switch-away.
- `generate(systemPrompt:messages:) -> AsyncStream<String>` — applies the model's **chat template** via `llama_chat_apply_template` (template id from `ModelCatalog`), tokenizes, decodes token-by-token, yields each detokenized piece. Stops on EOS, `n_ctx` limit, or a max-tokens cap (~512). Cancellation-aware: Task cancellation stops the decode loop and yields nothing further.

All llama.cpp calls are confined to this actor; failures surface as Swift errors (no traps/force-unwraps). Native pointers never escape the actor.

### Streaming — the one protocol change

Today `AIProviderClient.send(...)` returns `String`. Add an **optional** streaming method with a default that adapts existing clients:

```swift
protocol AIProviderClient {
    func send(...) async throws -> String                    // existing, unchanged
    func stream(...) -> AsyncThrowingStream<String, Error>    // new
}
extension AIProviderClient {
    // Default: run send(), yield the whole reply as ONE chunk. Cloud clients get "streaming"
    // for free as a single chunk; only OnDeviceClient overrides with true token streaming.
    func stream(...) -> AsyncThrowingStream<String, Error> { /* wraps send() */ }
}
```

`AICoachEngine` gains a parallel `sendStreaming(_:)` that appends an empty assistant `ChatMessage`, then mutates its `.text` as chunks arrive (`ChatMessage.text` becomes a `var`). It uses `stream(...)` for **every** provider — cloud providers resolve to one chunk, on-device streams for real — so the streaming plumbing is uniform and the send path is not forked per provider.

**Threading:** generation runs on the `LlamaEngine` actor (off main); each yielded chunk is applied on `@MainActor` in `AICoachEngine`. UI never blocks.

**Stop:** add `stop()` to `AICoachEngine` that cancels the generation Task → the actor exits its decode loop cleanly. Surfaced as a Stop button while `sending`.

## Model delivery, storage & verification

### `ModelCatalog`

Static, checked-in description of the pinned default model (no live network catalog):

```swift
struct BundledModel {
    let id: String                 // "llama-3.2-3b-instruct-q4_k_m"
    let displayName: String        // "On-device Coach (Llama 3.2 3B)"
    let url: URL                   // pinned HuggingFace resolve URL
    let sha256: String             // verified after download
    let sizeBytes: Int64           // ~2.0 GB, shown in the confirm dialog
    let contextLength: Int         // 4096
    let chatTemplate: String       // template id for llama_chat_apply_template
}
```

**Model choice + license (resolved):** **Llama-3.2-3B-Instruct Q4_K_M**, pinned to an official/community HuggingFace resolve URL. Chosen over the MIT-licensed Phi-3.5-mini for coaching quality and Metal-friendliness. The app **never hosts or redistributes weights** — `ModelCatalog` holds only a pinned pointer + SHA-256, and the device downloads directly from HuggingFace — so the Llama 3.2 Community License concern is minimal. Only the factual pointer + checksum is committed; no weights in the repo.

### `ModelDownloadManager` (`@MainActor ObservableObject`)

- State enum the UI binds to: `.absent`, `.downloading(progress: Double)`, `.verifying`, `.ready`, `.failed(String)`.
- `URLSession` background `downloadTask` with **resume data** so a dropped 2 GB download continues rather than restarting.
- On completion: stream-hash the file (SHA-256, CryptoKit) and compare to the catalog value. **Mismatch → delete + `.failed`** (never load an unverified/corrupt blob).
- Atomic move into place only after verification passes.
- `deleteModel()` — frees the ~2 GB, surfaced in settings.
- Launch presence check sets initial state to `.ready` vs `.absent`.

### Storage

- `Application Support/OnDeviceModels/<id>.gguf`.
- Marked **excluded from iCloud/iTunes backup** (`URLResourceValues.isExcludedFromBackup = true`) — a re-downloadable 2 GB blob must not bloat backups.

### Trust & network honesty

- URL and SHA-256 are compiled in: first-run download is pinned and integrity-checked, consistent with the app's security posture (verified artifact, no arbitrary remote code).
- The model download is a **new network egress**. It is one-time, user-initiated, fetches public weights, and sends **no user data**. The spec/UI call this out explicitly so "offline by design" stays accurate: coach *inference* is 100% offline; only the one-time weight download touches the network, and only when the user taps it.

## UX flow in CoachView

**Provider picker.** `.onDevice` becomes the first case in `AIProvider.allCases` and the app default provider. Displayed as **"On-device — no setup, fully private"**. The setup card branches on provider; on-device shows a distinct card instead of the API-key field.

**On-device setup card (driven by `ModelDownloadManager.state`):**
- `.absent` → explainer + **"Download coach model (~2 GB)"** button, with: *"One-time download of the model over Wi-Fi. After that, coaching runs entirely on your \(deviceNoun) with no internet."*
- `.downloading(p)` → progress bar + bytes, **Cancel**.
- `.verifying` → "Verifying…" indeterminate.
- `.ready` → green "Model ready" pill; chat available; **Delete model (free 2 GB)** in the settings/disconnect area.
- `.failed(msg)` → error + **Retry** (uses resume data when possible).

**`isConfigured`:** `provider == .onDevice ? (downloadState == .ready) : <existing logic>`.

**Chat behavior:** identical composer and message list. Differences for on-device:
- Replies **stream** in token-by-token.
- A **Stop** button appears while `sending` (calls `stop()`).
- First-run **"Today's brief"** (`startBriefIfNeeded`) works the same — runs on-device.

**Consent & privacy copy:** data-consent toggle and system-prompt editor unchanged. The bottom privacy line gets an on-device variant: *"On-device coaching never leaves your \(deviceNoun) — your metrics are read and answered locally."* (No "sent to a provider" language for this case.)

**Reused verbatim:** message list, markdown rendering (`CoachMarkdownTheme`), consent toggle, system-prompt editor, "Today's brief".

## Memory, device gating & error handling

The core iOS risk is RAM (3B Q4 ~2 GB resident + KV cache). Mitigations:

- **Entitlement:** add `com.apple.developer.kernel.increased-memory-limit` to the `NOOPiOS` target (raises the jetsam ceiling on supported devices). Friction-free since NOOP is build-from-source / not App-Store-reviewed.
- **Device gate (`ModelCatalog.deviceMeetsRequirements(physicalMemory:)`):** check `ProcessInfo.physicalMemory`. Below ~6 GB installed RAM, disable the download button with an explainer ("Your \(deviceNoun) doesn't have enough memory to run the on-device coach; use a cloud provider instead"). Honest rather than jetsam-on-load.
- **Lazy load + single instance:** model loaded on first generation, not at launch; only one `llama_context` ever exists.
- **Memory-pressure handling:** `DispatchSource.makeMemoryPressureSource` (warning/critical). On critical while idle → `LlamaEngine.unload()` (reload lazily next turn). Never unload mid-generation.
- **Background unload:** unload the model when the app is backgrounded (default **ON**) to avoid being the top jetsam target; reload lazily on next use. Exposed as a tunable; the ON default may be revisited after device testing.

**Error handling — extend `AICoachError`** (keeps the UI's error surface uniform):
- `.modelNotDownloaded` — ask the user to download first.
- `.modelLoadFailed(String)` — llama.cpp failed to load/init (corrupt file, OOM at load) → suggest re-download / smaller context.
- `.generationFailed(String)` — decode error mid-stream.
- `.deviceUnsupported` — RAM gate failed.
- Download errors map to existing `.network(...)`.

All non-fatal: they land in `errorText` exactly like today. No crashes.

## Testing strategy

Native/model-dependent parts can't run in CI (no 2 GB weights, no Metal on runners), so logic is pushed into pure, testable units and the native surface is kept thin — matching the repo convention that wire/math-level logic lives deep and is covered by fast tests.

**Pure unit tests (CI, no model, no device) — in `StrandTests`:**
- `ModelCatalog`: URL well-formed, sha256 is 64 hex chars, `deviceMeetsRequirements(physicalMemory:)` correct at boundary values (inject RAM, don't read the device).
- SHA-256 verifier: hash a known fixture → match; corrupt a byte → fail.
- `ModelDownloadManager` state machine (protocol-injected downloader, no real network): absent→downloading→verifying→ready; verify-fail→failed+file-deleted; cancel→absent; resume path.
- `AICoachError`: new cases produce non-empty user-facing strings.
- Streaming adapter: `AIProviderClient.stream` default wraps `send()` into exactly one chunk (fake client asserts cloud parity); `AICoachEngine.sendStreaming` accumulates a stub stream `["He","llo"]` → message text "Hello", `sending` toggles, `stop()` cancels.
- `isConfigured` truth table across all five providers including `.onDevice` × download states.

**Manual / device verification (documented, not CI):**
- Real download + verify + generate on a physical iPhone; measure tokens/sec, peak memory (Instruments), jetsam with/without the entitlement.
- Streaming renders incrementally; Stop interrupts cleanly; memory-pressure unload/reload works.

**TDD:** the pure units (state machine, verifier, streaming adapter, gate, error strings) get tests first. `LlamaEngine` is validated by device smoke-testing; its logic is deliberately minimal.

## Resolved decisions

1. **Model:** Llama-3.2-3B-Instruct Q4_K_M, pinned HuggingFace resolve URL + SHA-256 in `ModelCatalog`. App never hosts weights.
2. **llama.cpp packaging:** pinned prebuilt binary **xcframework** (specific release tag) for reproducible, fast builds.
3. **Background unload:** default **ON**; exposed as a tunable, revisit after device testing.
4. **RAM gate threshold:** ~6 GB `physicalMemory`; the exact number confirmed against real-device measurements during implementation.

The one item still requiring a physical iPhone is confirming the exact RAM-gate number and validating tokens/sec + peak memory — captured in the device-verification testing section, not blocking the plan.
