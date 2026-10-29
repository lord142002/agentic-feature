# Bibbles Competitive Product Strategy — 2026-09-29

This comparison uses public product claims, not private architecture access or hands-on benchmarks. Claims should be rechecked during beta research.

## Market map

| Product | Strongest public position | Product advantage | Exposed tradeoff for Bibbles to exploit |
|---|---|---|---|
| VoiceOS | Voice-to-action across Mac and Windows | Polished system-wide dictation, selected-text editing, custom vocabulary, screen context, web sources, integrations, confirmations, and long-running work | Broad action surface raises trust, permission, reliability, and cloud-cost complexity; technical Hinglish and spatial target accuracy are not its stated wedge |
| Clico | AI workspace for the screen and creative work | Explicit page/app/file/selection context; separate Mac, Chrome, and Web surfaces; deep research; multi-model image/video/site creation | It is a broad creative suite rather than a low-latency voice layer; histories and capabilities differ by surface; relevant context may be processed online |
| Bibbles | Fast technical Hinglish plus precise cursor-area help | Native Mac interaction, hold-to-talk boundary, raw-vision grounding, local OCR, deterministic routing, local credentials, bounded web search | Early product: no action integrations, limited vocabulary adaptation, no polished dictation modes, and incomplete physical benchmark coverage |

## Evidence from primary sources

- VoiceOS says it provides dictation in standard fields, selected-text Edit Mode, screen-aware Agent Mode, connected-app actions with confirmation, and Mac/Windows support. Its pricing page lists 100 languages, custom vocabulary/replacements, MCP integrations, web search with sources, and local transcript storage. Sources: [VoiceOS product](https://www.voiceos.com/), [desktop assistant comparison](https://www.voiceos.com/siri-alternative), [pricing/features](https://www.voiceos.com/pricing), [changelog](https://www.voiceos.com/changelog).
- Clico positions Desktop around chosen screen, app, file, and selection context; Chrome around the active page/field/selection; and Web around longer research and creative projects. Its public data page says Desktop history is primarily local, while task context may be processed online. Sources: [Clico introduction](https://tryclico.com/blog/introducing-clico), [Desktop](https://tryclico.com/product/desktop), [data handling](https://tryclico.com/how-clico-handles-your-data), [product and plans](https://tryclico.com/).

## Product conclusion

Bibbles should not compete on the number of integrations or generative-media models. It should win the moment between pointing, speaking technical Hinglish, and receiving a trustworthy answer. The promise is:

> Hold, point, speak naturally, release, and get the right text or target—with no hidden capture and no mode selection.

The defensible wedge is the combination of:

1. Technical Hinglish transcription with user-controlled vocabulary and correction learning.
2. Evidence-backed screen grounding that can point accurately on Retina and mixed-DPI displays.
3. Local-first context selection: selected text before pixels, cursor crop before full window, and no speculative capture.
4. Transparent latency and cost budgets per path rather than a single opaque agent loop.

## Changes adopted now

- Screen pixels are no longer captured when push-to-talk begins. Capture occurs only after the final transcript explicitly routes to screen understanding. Ordinary chat, search, and dictation send no screenshot.
- “Rewrite/summarize/explain selected text” requests read at most 6,000 selected characters through macOS Accessibility and send that bounded context only when the user explicitly refers to it.
- Selected content is labeled as untrusted data; missing selection produces a local corrective message rather than an irrelevant model call.
- Deepgram 1011 failures receive one memory-only audio replay; full answers remain in a scrollable card and screen answers are preserved in chat.

## Next build order

1. **Completed:** vocabulary UI for repository symbols, names, and Hinglish technical terms, applied on the next voice turn without restart.
2. Two dictation outputs: **Verbatim** and deterministic **Clean**, with no LLM on the insertion path.
3. Correction learning that proposes vocabulary/replacement updates without silently changing transcription truth.
4. Capture gesture evidence: retain the pointer trail/region during the hold and send only its bounding crop.
5. Stream answer text into the response card and expose Cancel/Retry without losing the transcript.
6. Move provider secrets behind an authenticated gateway before external beta distribution.
7. Add actions only after the core gates pass; begin with reversible drafts and require confirmation for every external write.

## Release scorecard

| Metric | Gate |
|---|---:|
| Shortcut to visible listening state | p95 ≤100 ms |
| Release to stable/settling transcript | p95 ≤260 ms |
| Technical-token error rate | ≤8% |
| Screen capture rate on non-screen turns | 0% |
| Selected-context requests requiring screenshot | <10% |
| Correct pointer placement | ≥85% within tolerance |
| Simple-answer first token | p95 ≤1.2 s |
| Raw audio/screens persisted by default | 0 |
