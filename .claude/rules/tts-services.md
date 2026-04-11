---
paths:
  - "SoundsRight/Features/TTS/**/*.swift"
  - "Scripts/**"
---

# TTS Service Conventions

- All TTS service types are Swift `actor`s to safely manage async state.
- `TTSManager` is the only type that UI code should interact with for synthesis. Individual services (`KokoroTTSService`, `EdgeTTSService`, `FallbackTTSService`) are internal implementation details.
- `TTSManager.synthesize()` returns a `TTSResult` enum (`.audioData`, `.fallbackUsed`, `.failed`). Callers must handle all three cases.
- Audio caching uses `AudioCache` with a composite key of text + playback rate. Always check cache before calling any TTS provider.
- The Kokoro Python server runs on `127.0.0.1:18923`. It accepts POST `/tts` with JSON body `{text, speed, voice}` and returns `audio/wav`. The `/health` endpoint is used for availability checks.
- Edge TTS communicates over WebSocket with specific browser-like headers. Do not change the User-Agent or Origin headers without testing against the endpoint.
- `FallbackTTSService` uses `AVSpeechSynthesizer` and plays audio directly (no `Data` returned). This is the last resort in the chain.
