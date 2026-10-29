# Bibbles Worker integration

The macOS app sends AI text and audio only to `https://bibbles-api.bibbles.workers.dev`. Every Worker request gets `Authorization: Bearer <Supabase access token>` from the Keychain-backed Supabase Swift Auth session. The SDK refreshes tokens near expiry (including the project's 3,600-second lifetime). A missing or rejected session shows “Please sign in”; no provider fallback is attempted.

| App operation | Worker request | Response |
| --- | --- | --- |
| Normal chat and text-based planners | `POST /v1/chat`, mode `ask` | `content[0].text` |
| Explicit web search | `POST /v1/chat`, mode `search` | `content[0].text` |
| Long/hard chat or advanced quality | `POST /v1/chat`, mode `deep` | `content[0].text` |
| Push-to-talk and dictation | `POST /v1/transcribe`, `audio/wav` raw bytes | Deepgram `results.channels[0].alternatives[0].transcript` |
| Screen help and visual grounding | `POST /v1/vision`, Anthropic image+text body | `content[].text` |
| Spoken answers | `POST /v1/tts`, JSON `text` and `voice` | Raw 24 kHz mono PCM |
| Account usage | `GET /v1/me` | Plan, month, usage and limits in Settings → Account |
| Account deletion | `DELETE /v1/account` | Only after an explicit destructive confirmation |

## Plan timeline contract for `/v1/me`

The current Worker does **not** return authoritative plan dates or history. The Account screen therefore labels them unavailable rather than guessing from `month` (which is only the usage bucket). Extend the existing authenticated `GET /v1/me` response with these fields, preserving its current `plan`, `month`, `usage`, `limits`, and `min_app_version` fields:

```json
{
  "plan": "plus",
  "month": "2026-10",
  "usage": { "asks": 4 },
  "limits": { "asks": 500 },
  "subscription": {
    "plan": "plus",
    "status": "active",
    "started_at": "2026-10-08T05:00:00Z",
    "access_ends_at": null,
    "renews_at": "2026-11-08T05:00:00Z"
  },
  "plan_history": [
    {
      "plan": "alpha",
      "started_at": "2026-09-01T05:00:00Z",
      "ended_at": "2026-10-08T05:00:00Z",
      "end_reason": "upgrade"
    }
  ]
}
```

All timestamps are ISO 8601 instants with a time zone (UTC `Z` is preferred). `subscription.started_at` is when the **current plan** became effective, not when the latest monthly quota reset. `access_ends_at` is the actual known entitlement expiry; send `null` for an auto-renewing or non-expiring plan with no scheduled end. `renews_at` is the next scheduled renewal and is separate from expiry; send `null` when there is no renewal. The top-level `plan` and `subscription.plan` must match. `plan_history` contains only **completed** plan periods, with their real effective start/end and an end reason such as `upgrade`, `downgrade`, `cancellation`, or `expiry`. An empty array means no prior plans; an omitted field means history is not available yet. Never generate past plan periods from usage months or login timestamps.

On the Worker, source these fields from an authoritative subscription/entitlement record and an append-only plan-period history. Close the old period and create the new one atomically when a verified billing event changes a plan; process billing webhooks idempotently. For legacy users without trustworthy dates, omit the new fields until they can be backfilled from reliable records. Do not log billing identifiers, bearer tokens, or payment details. The app validates the dates, orders completed periods newest first, and displays them in the Mac's time zone.

The deployed `/v1/chat` supports Anthropic SSE when `stream: true`; Bibbles updates the answer card from `content_block_delta` events. Non-streaming planner replies use `content[0].text`. Bibbles speaks the completed answer using the Worker TTS endpoint.

Vision requests send base64 JPEG image blocks to `/v1/vision` with an explicit `light` or `deep` tier. The client rejects bodies above 10 MB before sending. The app never retries a metered request on its own (the Worker counts usage before provider calls, so a retry could charge twice); a failure is shown with Retry for the user to choose. Every POST carries a fresh `Idempotency-Key` header per user action, so the Worker can charge a duplicate delivery only once. Dictation is re-sent without `language` only when the Worker rejects that parameter with 400/422. If an Alpha account has no deep-task allowance, a failed low-confidence hand-over keeps the paid-for light answer but suppresses unverified on-screen marks.

## Verification on a signed Mac build

1. Run `swift test --disable-sandbox --jobs 4` with Xcode selected. Build `sh scripts/build-dev-app.sh` and launch the signed app.
2. Sign out. Ask a typed chat question and try push-to-talk. Each should say “Please sign in” and no Worker chat/transcribe request should be made.
3. Sign in with an account enabled in Supabase. Ask “Hello,” use the Web toggle, and ask a long analysis question. Verify the Worker observes modes `ask`, `search`, and `deep`, each with a Supabase bearer token and no provider key header. Check that the answer appears progressively from SSE.
4. Dictate a sentence. Verify `POST /v1/transcribe` receives WAV bytes (`RIFF` header) and the final transcript is inserted. There is no live interim transcript with this upload-after-release contract.
5. Open Settings → Account. Compare displayed remaining counters to `GET /v1/me`. Confirm 401, 429, 503 and 500 map to the user-facing messages and Retry works.
6. Ask about an on-screen control and confirm `/v1/vision` receives a JPEG image block and `tier: light`. Test a chart on a plan with deep allowance and confirm `tier: deep`; on Alpha, expect a clear deep-task limit. Test spoken answers and verify `/v1/tts` PCM plays at 24 kHz. Test account deletion only with a disposable account and confirm Cancel leaves it intact.

No live Worker call can be verified from the repository alone without a signed-in test account. The old local provider-key entries, if any, remain in the user's Keychain but are no longer read by the app; do not delete them without the user's explicit permission.
