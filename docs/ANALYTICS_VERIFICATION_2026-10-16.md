# Live analytics verification — 16 October 2026

## Build and configuration

- Verified the local app built from `b1dd532`, version 0.1.0 (1), using the pinned PostHog Swift SDK 3.92.0.
- Rebuilt and signed `.build/dev-app/Bibbles.app` with the existing public PostHog settings from `.env.local`, then relaunched it.
- Confirmed the generated bundle contains a public project token and `https://us.i.posthog.com` as its ingestion host. No token is reproduced here.
- Confirmed `.env.local` is ignored by Git. These settings were not added to tracked source or `Resources/Info.plist`.
- The earlier build lacked configuration because the build script does not load `.env.local` automatically. Future builds must receive the two documented environment variables.

## Observed in PostHog

Project 665346, shown as “Default project,” received actual app events in both Live and the stored Events view:

- `$screen`: `settings_general`, `settings_about`, and `chat`.
- `chat_response_received`: two successful test replies appeared in the stored event list.
- `$identify`: the restored signed-in session was identified; no login event was expected solely from restoration.

The stored chat-success event's displayed properties contained `mode: ask`, app version/build, the PostHog library/version, `chat` as the screen name, session/timestamp metadata, and `GeoIP disabled: true`. No question, answer, email, screenshot, or recording appeared in the inspected event properties. This is a sampled payload inspection, not an audit of every possible event or server-side retention setting.

One chat test encountered a lost network connection. It completed after one user-interface retry.

## Consent check

- The existing analytics preference was on at the start.
- Turned it off in Settings → General → Privacy and visited Permissions.
- Kept live monitoring active through an additional 30-second observation interval. No Permissions screen event appeared; the later stored event list likewise had no `settings_permissions` entry for that visit.
- Restored the preference to on. The stored event list subsequently showed identification and the current General screen, confirming delivery resumed. This is the current screen at opt-in, not a replay of the off-consent Permissions visit.

## Remaining checks

- Live dictation, screen-help, tutorial-completion, login, and signup events were not exercised during this verification.
- A two-account identity switch was not exercised live during this verification.
- PostHog project IP-storage and retention settings were not changed or audited.
- No private screen content or audio was uploaded for the analytics test, and no purchase or account deletion was performed.

For configuration and the full verification matrix, see [ANALYTICS.md](ANALYTICS.md).
