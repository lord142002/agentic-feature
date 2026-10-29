# Bibbles STT benchmark protocol

The checked-in benchmark manifest is generated deterministically by `STTEvaluationCorpus` and contains 500 balanced English, Hindi, and technical Hinglish prompts. Record human speech as mono 16 kHz linear PCM WAV files named with each entry ID. Synthetic speech must not be used for accuracy claims.

Run the same audio, network, machine, chunk cadence, and release boundary against:

1. Deepgram Nova-3 multilingual (`/v1/listen`, `nova-3`, `language=multi`).
2. Deepgram Flux multilingual (`/v2/listen`, `flux-general-multi`, Hindi and English language hints, 80 ms chunks).
3. AssemblyAI Whisper Streaming (`/v3/ws`, `whisper-rt`, automatic language detection).

For every utterance retain only the fixture ID, reference, hypothesis, partial latency, final latency, disconnects, and provider/model version. Do not retain user microphone audio in product telemetry. Report WER by language, technical-token error rate, p50/p95 first-partial latency, p50/p95 release-to-final latency, empty rate, and reconnect rate.

Live provider conclusions are blocked until all 500 matching human recordings and an AssemblyAI API key are available. The app must keep Nova-3 as the production default until the complete matrix passes.
