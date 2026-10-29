# Product analytics

Bibbles uses the official PostHog Swift SDK, pinned to 3.92.0 through Swift Package Manager.
The app is native macOS (AppKit/SwiftUI); there is no SSR, hydration, or browser router.
The separate static legal website and JavaScript billing Worker are not instrumented.

## Project setup

Signing into PostHog is not sufficient configuration. Use the project switcher at the
top of PostHog to select or create a Bibbles project. Open **Settings → Project** and
copy its **Project API key** (also called the project token). In that project's
Swift/iOS installation snippet, copy the ingestion `host`. Use the matching region:
`https://us.i.posthog.com`, `https://eu.i.posthog.com`, or your HTTPS self-hosted origin.
Do not use the dashboard URL as the ingestion host. Never use a personal API key or
project secret key. This integration accepts public `phc_` project tokens only.

Copy `.env.example` to `.env.local` and fill in:

```sh
BIBBLES_POSTHOG_PROJECT_TOKEN=
BIBBLES_POSTHOG_HOST=
```

Both files are shell-compatible. `.env.local` is ignored; it is not read automatically.
Export it into the process that runs or builds the native app:

```sh
set -a
. ./.env.local
set +a
swift run Bibbles
# Or, for a Finder-launched app:
sh scripts/build-dev-app.sh
```

The bundle script puts these public settings into the generated, ignored app's
Info.plist before signing. No actual values belong in `Resources/Info.plist`, source,
or the example file. Set the same variables in the release build environment.
Configuration is optional: missing, malformed, personal/secret-key, or non-HTTPS
configuration disables analytics and has no effect on the rest of Bibbles.

## Consent and privacy

Collection defaults to **off**. The SDK is not initialized until the user turns on
**Settings → General → Privacy → Share product analytics**. The preference is local
to this Mac profile. Turning it off stops new captures and resets analytics identity.
Events from before consent are never buffered or backfilled. Consent is independent
of signing in; restoring or signing out of an account does not grant consent.

Automatic screen/lifecycle/element collection, method swizzling, feature-flag
preloading/events, crash capture, and default person properties are disabled.
Session replay is not enabled (the pinned SDK does not offer it on native macOS).
GeoIP enrichment is disabled; the ingestion service still receives network requests.
Review **Settings → Project → General → IP data capture configuration** in PostHog
and disable IP storage. Configure project retention/access for your privacy policy.

Only fixed screen names and the events below are accepted by the SDK filter.
Properties are allowlisted. No prompts, responses, transcripts, emails, passwords,
tokens, screenshots, document contents/names, external app titles, payment details,
checkout URLs or billing identifiers are passed to analytics. Auth identity is only
the stable Supabase user UUID. No email or profile attributes are set.

## Events

| Event | Actual success point | Properties |
| --- | --- | --- |
| `$screen` | Chat, Plans, or a Settings section is shown; Settings navigation is explicit | Fixed `$screen_name` |
| `user_logged_in` | Email, Google, or Apple returns a successful session | `method`: fixed enum |
| `user_signed_up` | Email signup returns a session, or its pending verification completes | `method`: fixed enum |
| `chat_response_received` | A successful remote reply is stored, including search/write requests | `mode`: `ask`, `search`, `write` |
| `dictation_completed` | Final dictation has been inserted successfully | None |
| `screen_help_completed` | A current, uncancelled screen-help answer returns | None |
| `tutorial_completed` | The user finishes the ready step of the first-run tutorial | None |

These four product events measure activation, repeat usage, and the value of the
core flows. Local quick answers are excluded from `chat_response_received`.
OAuth methods report login success. They do not guess whether an OAuth session
created a new account; an authoritative server signup signal would be needed for that.
Restoring a session identifies the user but does not fabricate a login event.
Token refreshes, failures, cancelled requests, password recovery and button clicks
are not counted as successful logins/signups. Signup completion is reported once
for email signups initiated on this Mac, including verification after a restart.

`ProductAnalytics` is the sole SDK adapter. It initializes once per process,
deduplicates repeated screen calls, updates identity on Supabase user-ID changes,
and calls `reset()` on logout or direct account switches before capturing new events.

## Verification

Local tests use a recording client and never send events. They cover missing config,
consent, no backfill, restored identity, logout/account switching, screen navigation,
SDK privacy defaults, and the bounded event properties.

In your configured project, open **Activity → Live events** (or the Product Analytics
live-events view in your PostHog navigation):

1. Start with analytics off. Use the app; verify there are no new events.
2. Enable analytics. Open Chat and Settings, navigate between Settings sections, and
   close/reopen them. Check `$screen` names and that a repeated show of the same
   visible screen produces one event, not duplicate events.
3. Sign in. Verify `user_logged_in` uses your Supabase UUID as `distinct_id`, with
   no email/name properties. Restart with that session: identity should be restored
   without another login event. Test an email signup through verification separately.
4. Complete a chat/search, dictate into a field, request screen help, and finish the
   tutorial. Check the corresponding success events. Inspect their complete payloads.
5. Sign out. Subsequent screen events should have a new anonymous ID. Sign in with
   a different account and check it is identified separately.
6. Turn analytics off. New actions must stop producing events. Re-enable and confirm
   actions performed while it was off do not arrive later.

Allow the SDK's normal batch interval (about 30 seconds), or background and reopen
the app, before checking delivery. No events have been verified in your project as
part of the local tests. Publish the updated privacy-policy source alongside any
release that enables this integration.

Official references:
- https://posthog.com/docs/libraries/ios
- https://posthog.com/docs/libraries/ios/configuration
- https://posthog.com/docs/libraries/ios/usage
- https://github.com/PostHog/posthog-ios/releases/tag/3.92.0
