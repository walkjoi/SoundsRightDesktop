---
paths:
  - "SoundsRight/Features/TTS/**/*.swift"
---

# TTS Service Conventions

- `TTSManager` and `EdgeTTSService` are Swift `actor`s. `FallbackTTSService` is a `@MainActor` NSObject subclass — it must conform to `AVSpeechSynthesizerDelegate`, which actors cannot; its `nonisolated` delegate callbacks hop back onto the main actor.
- `TTSManager` is the only type that UI code should interact with for synthesis *and* playback control of fallback speech (`stopPlayback`, `pauseFallback`, `resumeFallback`). Individual services (`EdgeTTSService`, `FallbackTTSService`) are internal implementation details.
- `TTSManager.synthesize()` returns a `TTSResult` enum (`.audioData`, `.fallbackUsed`, `.failed`). Callers must handle all three cases. `.fallbackUsed(Int)` means fallback speech *started*; the payload is the utterance generation — completion arrives through the handler registered with `setFallbackFinishedHandler` as `(generation, finishedNaturally)`. Callers that discover they were superseded after `synthesize` returns must call `stopFallback(generation:)` with that payload so an orphaned utterance is silenced without touching a newer one. `.failed` is returned when Edge fails and fallback speech cannot start (or the request was superseded/cancelled before fallback started).
- Audio caching uses `AudioCache` with a composite key of text + playback rate. Always check cache before calling any TTS provider.
- Edge TTS communicates over WebSocket with specific browser-like headers. Do not change the User-Agent or Origin headers without testing against the endpoint. Voice is `avaNeural` (American English). One `URLSession` is reused for the actor's lifetime; timeouts live in `AppConstants` (`edgeTTSIdleTimeout`, `edgeTTSSynthesisDeadline`).
- `FallbackTTSService` uses `AVSpeechSynthesizer` with an explicit `en-US` voice and plays audio directly (no `Data` returned). This is the last resort in the chain. Its rate mapping switches exhaustively over `PlaybackRate` — adding a rate case must update the mapping.
