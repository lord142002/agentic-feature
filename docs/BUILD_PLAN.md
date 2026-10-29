# Bibbles Build Plan

This is a historical phase plan. For the implemented provider routing and current setup, see [README.md](../README.md).

This plan turns `MVP.md` into six gated phases. A later phase may begin in parallel, but it cannot be called complete until the preceding gate passes on physical Macs.

## Phase 0 Product and measurement contract

**Outcome:** every critical interaction has one definition, timestamp source, and release threshold.

- Freeze the three gestures: Control + Option hold for PTT, double Control for typed input, Function + Control hold for dictation.
- Define client monotonic timestamps for shortcut, audio-first-frame, PTT release, STT partial/final, route, capture, grounding, first token, and pointer.
- Create a 500-utterance English/Hindi/Hinglish evaluation manifest without storing production audio by default.
- Record supported Mac, display, network, and application test cohorts.

**Gate:** event names, privacy rules, and percentile calculations are reviewed; no team reports provider-only latency as end-to-end latency.

## Phase 1 Native interaction shell

**Outcome:** Bibbles feels immediate before any cloud service exists.

- Menu-bar-only SwiftUI/AppKit process.
- Global gesture monitor and deterministic gesture interpreter.
- Cursor-near, non-key, click-through floating pill.
- Interaction state machine with cancellation.
- Permission diagnostics for Accessibility, microphone, and screen recording.
- Coordinate transform contract and mixed-display unit tests.

**Gate:** 95% of hotkey events show the local overlay within 100 ms; overlay never steals focus or mouse clicks; coordinate fixtures pass.

## Phase 2 Push-to-talk and technical Hinglish STT

**Outcome:** speech becomes editable text at the release boundary.

- Pre-authorized AVAudioEngine session with 16 kHz mono output.
- Persistent authenticated STT WebSocket; 20 ms audio frames while held.
- Local VAD, streaming partials, explicit `end_of_utterance` on release.
- Session glossary from user corrections and explicitly collected visible technical tokens.
- N-best constrained rescoring; never use a generative rewrite as transcription truth.
- Provider benchmark harness and latency telemetry.

**Chosen MVP implementation:** Deepgram Nova-3 Multilingual (`language=multi`) is the initial streaming STT candidate. Provider selection remains behind `TranscriptionStreaming` until it passes the Bibbles Hinglish and latency fixtures. The API key is supplied at runtime through `BIBBLES_DEEPGRAM_API_KEY`.

**Gate:** p95 partial visible within 100 ms of release, p95 stable final within 260 ms on the warmed supported path, technical-token error rate at most 8%.

**Current physical-Mac result (2026-09-21):** the already-visible streaming transcript passes the release boundary, but Nova-3 explicit finalization measured p50 402 ms / p95 425 ms over five acoustic samples. Phase 2 remains open. See `LATENCY_TEST_2026-09-21.md`.

**Current hardening status (2026-09-29):** Verbatim and deterministic Clean modes, explicitly approved local correction rules, streamed assistant output, Cancel/Retry/Use-transcript recovery, a balanced 500-item English/Hindi/Hinglish manifest, WER/latency scoring, and the three-provider benchmark matrix are implemented. Live 500-recording provider results remain gated on matching human audio and an AssemblyAI key; see `STT_BENCHMARK_PROTOCOL.md`.

## Phase 3 Screen capture and spatial grounding

**Outcome:** Bibbles can identify and point to visible targets without relying on Accessibility trees.

- One-shot ScreenCaptureKit capture with cursor crop first and optional window crop in parallel.
- Exact `CaptureDescriptor` recorded at capture time.
- Raw-vision/OCR grounding for Electron, browser, and canvas fixtures; AX metadata is advisory.
- One click-through overlay per display; revalidate geometry before drawing.
- Sensitive-app blocklist, in-memory pixels, and visible capture glyph.

**Current implementation:** one-shot ScreenCaptureKit display capture, authoritative cursor-crop planning, local Vision OCR, OpenRouter-hosted Qwen structured grounding, confidence-based Qwen3-VL-30B-to-GPT-5.6-Luna fallback, validated coordinate mapping, and a click-through target highlight are implemented. Each request requires zero retention and denies provider data collection. A physical M1 test captured an exact 1024×900 cursor crop and detected 63 OCR regions locally in 846 ms without persisting pixels. Live model latency/accuracy, sensitive-app blocking, and the mixed-display fixture matrix remain.

**Screen guidance upgrade:** pointed chart questions now pass the captured cursor coordinate to the vision model and skip local OCR; control-finding questions use a full-display view. A click-through companion marker and guide path animate to a confidence-checked, recent target without moving the actual pointer. Capture, OCR, and grounding times are recorded locally without saving pixels or answers. Physical candle/control accuracy and end-to-end timing still require validation on signed builds.

**Gate:** at least 85% of curated targets land within 24 logical points or 10% of target size across Retina, scaled, mixed-DPI, rotated, and negative-origin layouts.

## Phase 4 Thin intelligence loop

**Outcome:** transcripts produce concise responses without slowing PTT.

- Three-way local/edge route: chat, screen, or search within 35 ms.
- One LLM/vision provider and one search provider behind narrow protocols.
- Text streaming first; vision/search results can enrich the response asynchronously.
- Short session context, Hinglish response policy, citations for current claims.
- No TTS on the critical path and no runtime provider marketplace.

**Chosen MVP implementation:** routing remains deterministic and local. Qwen3-VL 30B via OpenRouter is the default vision provider and GPT-5.6 Luna is the ambiguous-screen fallback. Explicit search phrases use OpenRouter's `openrouter:web_search` server tool with Exa fast mode and hard caps of two searches/six results; citations are rendered as source links. Ordinary chat requests do not receive the search tool. Jev and TTS are excluded from the initial critical path.

Screen capture is demand-driven after routing, so non-screen turns capture zero pixels. Explicit selected-text requests use a bounded local Accessibility snapshot instead of vision when available.

**Gate:** simple-answer first token p95 at most 1.2 s; routing policy passes its fixture suite; PTT latency does not regress.

## Phase 5 Privacy, onboarding, and private beta

**Outcome:** a new user can understand permissions and complete the core flow safely.

- Just-in-time onboarding and degraded modes.
- Capture controls, sensitive-app list, session deletion, opt-in analytics.
- Crash reporting without raw screen/audio/text payloads.
- Accessibility, reduced-motion, multi-display, failure, and offline passes.
- Optional TTS experiment only after Phase 2 and Phase 3 gates remain green.

**Gate:** 99% crash-free sessions, zero hidden capture events, all MVP acceptance scenarios pass with 20–50 beta users.

## Immediate backlog

1. Run and validate the Phase 1 shell on a physical Mac.
2. Replace the development global monitor with a reviewed event-tap implementation and capture latency spans.
3. Add an app bundle/Xcode project, signing configuration, usage descriptions, and CI once full Xcode is available.
4. Measure Nova-3 partial/final latency and technical-Hinglish token error on physical hardware.
5. Validate Accessibility-first focused-field insertion across native, Electron, and browser editors.
6. Build display fixtures from actual `NSScreen` and ScreenCaptureKit descriptors.
7. Benchmark Qwen/Luna grounding latency and target accuracy on physical screen fixtures.
8. Validate the bounded web-search path, returned citations, and cost/latency behavior with explicit search turns.
9. Validate the interactive readiness menu, typed-command routing, first-run guide, and consented grounding test with beta users.
10. Benchmark the implemented 100-term technical vocabulary editor and selected-text workflows against VoiceOS and Clico.
