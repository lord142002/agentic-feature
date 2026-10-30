# Models (Local mode, developer builds only)

Verified live on **2026-10-29** (02:20 UTC). Pinned IDs only, never a `latest` alias.
Customers never see these names: the app shows "Light Task", "Deep Task" and "Agent Task".
`Sources/BibblesApp/Intelligence/ModelCatalog.swift` holds the same table for cost estimates.

## Verified table

Prices are US dollars per million tokens (input / output) unless noted.

| Feature | Model | Pinned ID | Provider (key) | Price |
|---|---|---|---|---|
| Light chat, search, light vision | DeepSeek V4.1 Flash | `deepseek/deepseek-v4.1-flash` | OpenRouter | $0.045 / $0.50 |
| Light backup, router, agent backup (default) | Claude Haiku 4.5 | `claude-haiku-4-5-20251001` | Anthropic | $1.00 / $5.00 |
| Deep chat, deep vision | Claude Sonnet 5.5 | `claude-sonnet-5-5` | Anthropic | $2.00 / $10.00 |
| Agent planner and screen agent (default) | GPT-5 mini | `openai/gpt-5-mini` | OpenRouter | $0.25 / $2.00 |
| Agent planner / backup option | Claude Haiku 5.5 | `claude-haiku-5-5` | Anthropic | $0.10 / $0.50 (prompts up to 100K tokens) |
| Deep chat, deep vision (option) | GPT-6.1 Sol | `openai/gpt-6.1-sol` | OpenRouter | $2.00 / $10.00 (checked 2026-10-30) |
| AI router option | Jev 1.14 (TypeSafe) | `typesafe/jev-1.14` | OpenRouter (Decisions API) | $0.042 / $0 (checked 2026-10-30) |
| Agent planner and screen agent option | Gemini 3.8 Flash | `google/gemini-3.8-flash` | OpenRouter | $0.825 / $4.125 |
| Speech to text | Nemotron 3.5 ASR (multilingual) | `nvidia/nemotron-3.5-asr-streaming-multilingual-0.6b` | OpenRouter | $0.00000333 per unit (listed `prompt` price) |
| Speech to text backup | Deepgram Nova-3 | `nova-3` | Deepgram | Deepgram's own pricing |
| Spoken answers | Gemini 3.8 Flash Lite TTS | `google/gemini-3.8-flash-lite-tts` | OpenRouter | $0.50 / $6.00 |

## Findings

- **`openai/gpt-5-mini` is still listed** on OpenRouter ($0.25 / $2.00), so it stays the agent planner default. It does not accept `temperature`; Bibbles leaves it out for that model.
- **Claude Haiku 5.5**: the direct ID is `claude-haiku-5-5`. Anthropic's model ID page says that from the Claude 4.6 generation on, IDs have no date and each ID "identifies a pinned version of the model", so this dateless ID is pinned. On OpenRouter it is `anthropic/claude-haiku-5.5` ($0.10 / $0.50). The planner calls it directly with the Anthropic key. Its price is higher for prompts over 100K tokens, which agent prompts never reach.
- **`google/gemini-3.8-flash`** is listed ($0.825 / $4.125). It accepts `temperature` and structured outputs.
- **DeepSeek V4.1 Flash** also has a dated variant, `deepseek/deepseek-v4.1-flash-1017` ($0.30 / $1.20). Local mode uses `deepseek/deepseek-v4.1-flash` because that is what the live Worker uses, and Local mode must match the Worker. If the Worker moves to the dated ID, change `ModelCatalog.deepSeekFlash` too.
- OpenRouter lists `~anthropic/claude-haiku-latest`. This is an alias, so it is not used.
- The speech models don't appear in the default `/api/v1/models` listing. They are listed with `?output_modalities=speech` and `?output_modalities=transcription` (evidence below).
- Haiku 5.5 and Sonnet 5.5 use adaptive thinking. OpenRouter does not list `temperature` for them, so Bibbles doesn't send it.

## Evidence

The command from the task:

```bash
curl -s https://openrouter.ai/api/v1/models | \
  python3 -c "import sys,json; [print(m['id'], m['pricing']['prompt'], m['pricing']['completion']) for m in json.load(sys.stdin)['data'] if any(k in m['id'] for k in ['gpt-5-mini','gpt-6','haiku','sonnet-5','gemini-3.8-flash','deepseek-v4.1','nemotron','gemini-3.8-flash-lite-tts'])]"
```

Output (prices per token), lines used by Bibbles:

```text
deepseek/deepseek-v4.1-flash-1017 0.0000003 0.0000012
anthropic/claude-haiku-5.5 0.0000001 0.0000005
anthropic/claude-sonnet-5.5 0.000002 0.00001
deepseek/deepseek-v4.1-flash 0.000000045 0.0000005
google/gemini-3.8-flash 0.000000825 0.000004125
~anthropic/claude-haiku-latest 0.0000001 0.0000005
anthropic/claude-haiku-4.5 0.000001 0.000005
openai/gpt-5-mini 0.00000025 0.000002
```

Speech models:

```text
$ curl -s "https://openrouter.ai/api/v1/models?output_modalities=speech"         # filtered
google/gemini-3.8-flash-lite-tts 0.0000005 0.000006
$ curl -s "https://openrouter.ai/api/v1/models?output_modalities=transcription"  # filtered
nvidia/nemotron-3.5-asr-streaming-multilingual-0.6b 0.00000333 0
deepgram/nova-3 0.0000716666666667 0
```

Anthropic (platform.claude.com, models overview and pricing pages, 2026-10-29):

```text
Claude API ID   claude-fable-5-1   claude-opus-5-5   claude-sonnet-5-5   claude-haiku-5-5
Pricing         $10 / $50          $4 / $20          $2 / $10            From $0.10 / From $0.50
Claude Haiku 4.5   $1 / MTok input   $5 / MTok output
Claude Haiku 5.5   $0.10 / MTok for prompts up to 100,000 tokens   $0.50 / MTok output
"Each Claude model ID identifies a pinned version of the model." (Model IDs and versioning)
```

## Re-checking

Run the command above again before changing an ID or a price. Then update this file and `ModelCatalog` together. Every ID must be pinned.
