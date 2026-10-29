# Physical-Mac STT Latency Test — 2026-09-21

## Environment

- MacBook Air (M1, 8 GB)
- macOS 26.5.1
- Deepgram Nova-3 Multilingual over a persistent WebSocket
- 16 kHz mono linear PCM, 20 ms frames
- Five speaker-to-physical-microphone English/Hinglish technical phrases
- Client monotonic-clock measurements; no transcript or audio persisted

## Final verification run

| Metric | p50 | p95 (nearest rank) | MVP gate |
|---|---:|---:|---:|
| Local self-test start → overlay | 3.8 ms | 176.2 ms | ≤100 ms |
| PTT release → already-visible streaming transcript | 0.016 ms | 0.018 ms | ≤100 ms visible partial |
| PTT release → explicit-final transcript | 402.4 ms | 424.8 ms | ≤260 ms stable final |

Five of five phrases completed with no transport errors. Four warmed overlay samples were 2.7–3.8 ms; the 176.2 ms p95 is the first cold panel construction sample in this small cohort and requires a larger run. All five phrases had streaming text visible before release. Explicit finals ranged from 365.4–424.8 ms.

## Findings

1. The local interaction path passes its acknowledgement budget after warm-up, but cold panel creation must be prewarmed and tested over a larger cohort.
2. Nova-3 explicit finalization from this network/hardware cohort does not meet the 260 ms p95 gate. Final verification observed 365.4–424.8 ms.
3. Two implementation races were found and fixed during the test: sending captured frames before the WebSocket open boundary, and treating a finalized segment as the utterance-final boundary instead of waiting for Deepgram `from_finalize`.
4. The product should keep the stable streaming partial visible at release and settle it asynchronously. Provider comparison remains required before declaring the Phase 2 latency gate passed.

## Decision

Keep Nova-3 as the working STT provider for Hinglish accuracy evaluation, but do not mark Phase 2 complete. Run the same fixture through Deepgram Flux Multilingual and one independent streaming STT provider, then select by end-to-end p95 and technical-token error rate.
## OpenRouter vision grounding follow-up (2026-09-28)

One physical M1 one-shot test completed with the cursor crop and OCR sent to OpenRouter under the authorized zero-retention/data-collection-denied routing policy. No image was persisted locally.

- Capture + local OCR: 291 ms
- OpenRouter Qwen3-VL 30B grounding: 5,246 ms
- Total capture → validated target: 5,538 ms
- OCR regions: 24
- Model confidence: 0.95
- Target returned and safely mapped: yes

This confirms the screen path works, but its model latency is asynchronous-only and must not be placed on the push-to-talk transcript critical path.
