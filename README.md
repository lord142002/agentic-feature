# Bibbles

Optional, consent-based PostHog product analytics are configured through
`BIBBLES_POSTHOG_PROJECT_TOKEN` and `BIBBLES_POSTHOG_HOST`. Collection defaults to off;
users can opt in under Settings → General → Privacy. See [docs/ANALYTICS.md](docs/ANALYTICS.md)
for project setup, native screen events, privacy controls, and verification.

Bibbles is a native, screen-aware macOS companion with push-to-talk, dictation, chat, voice replies, and visual guidance.

## Accounts

Settings → Account offers email sign-up/sign-in, Google sign-in, and Apple sign-in through the Bibbles Supabase project. Sessions are refreshed and stored in the macOS Keychain. Sign-in is required for AI chat and transcription. The Account page reads plan usage from the Bibbles Worker. Local chat history is not uploaded by signing in.

The project's email provider is active. Google and Apple buttons become available after their provider credentials are configured in Supabase. See [docs/AUTH_SETUP.md](docs/AUTH_SETUP.md) for the required callback URL, provider setup, and Apple signing capability.

## Current architecture

All AI text requests use `POST /v1/chat` on the Bibbles Cloudflare Worker with a refreshed Supabase bearer token. Normal chat uses `ask`, explicit web search uses `search`, and long/hard tasks use `deep`. The Worker streams Anthropic SSE to the chat response card; planners use complete replies. Voice commands and dictation send WAV audio to `POST /v1/transcribe`; the Worker returns Deepgram JSON. The app never sends provider API keys. See [docs/WORKER_MIGRATION.md](docs/WORKER_MIGRATION.md).

Spoken answers use `POST /v1/tts` on the Worker; the returned raw 24 kHz PCM is wrapped as WAV for local playback. It skips emoji and decorative Markdown. Screen captures and local Vision OCR use `POST /v1/vision` with the image and text in Anthropic content blocks. Normal questions use the light tier; charts and low-confidence hand-overs use deep. Basic local doodles and deterministic visual examples do not need the Worker.

The menu reports sign-in and permission readiness. Typed commands use the same local intent router as voice commands. Control + Option records while held; audio is uploaded only after release. Selected-text requests use explicitly selected characters through Accessibility and do not require a screenshot.

## Run the development build

```bash
swift run Bibbles
```

Sign in under **Settings → Account** before using AI chat or dictation. No provider API key is needed in the Mac app. Only the Supabase publishable key is bundled.

The menu's **Technical Vocabulary…** editor still stores approved terms locally. The current Worker transcription contract does not accept keyterms, so these terms are not sent to Deepgram.

Provider/model selection now belongs to the Worker. The app sends only a task mode, not a provider key.

The command-line build is useful for development. A distributable app still requires full Xcode for bundle signing and macOS permission entitlements.

For physical-Mac development testing with microphone usage metadata, create an app bundle:

```bash
sh scripts/build-dev-app.sh
```

The bundle is written to `.build/dev-app/Bibbles.app`.
The bundle includes Bibbles' four-bar app icon. The same mark appears in the menu bar, chat sidebar, and response card. During push-to-talk and dictation, the floating panel shows a four-bar voice indicator driven by the existing microphone frames at up to 25 visual updates per second. It rests when idle and becomes static when microphone input is unavailable; macOS Reduce Motion removes the animated movement.
The build script uses an available Apple Development signing identity automatically, or one supplied through `BIBBLES_CODESIGN_IDENTITY`. If neither exists, it falls back to ad-hoc signing. Ad-hoc signing changes the app's macOS privacy identity on every rebuild: a Bibbles switch can remain on in System Settings while screen capture is denied. Set up an Apple Development certificate in Xcode before repeated physical testing. If you are using an ad-hoc build, remove the old Bibbles entry from **Privacy & Security → Screen & System Audio Recording**, add the exact `.build/dev-app/Bibbles.app` built most recently, enable it, then quit and reopen Bibbles. Do this only after the final rebuild.

## Controls

### Visual explanations

For explicit non-mathematical visual requests, Bibbles can show a bounded scene of lines, labels and steps. It validates coordinates, counts and text lengths before rendering. Math and geometry questions use the ordinary answer path; the dedicated visual lesson examples have been removed.

Screen-control questions now show a guided panel with **Refresh screen**. Guidance marks refer only to the captured screen, expire after ten seconds from capture, and are invalidated by detected clicks, scrolling or typing in another app. Refresh captures the current screen and asks the vision model again; Bibbles does not click controls. Geometry uses native vector animation and respects Reduce Motion. No Python runtime, Manim render process, or web drawing engine is needed for this first release.

### Keyboard and voice

- Hold Control + Option: begin push-to-talk; release either modifier to finish.
- Circle-to-Focus: hold Control + Option and drag around an area. A smooth lavender trail fades quickly; mouse-up captures only the bounded region (with 8-point padding) and asks about it using your spoken question, or “Explain the circled area” when silent. Mouse-up ends that voice turn. Tiny clicks and straight accidental swipes are ignored. Release a modifier before mouse-up or press Escape to cancel the selection. Normal desktop clicks remain unaffected when the chord is not held.
- Focus selections stay on the display where the drag began. Capture validates that display’s ID, frame, scale, and rotation; screen/Space changes cancel the drawing. Bibbles windows are excluded from capture, and only the selected crop is passed to the vision route.
- Hold Function + Control: record dictation for the focused text field; release either modifier to transcribe and insert the final text. The current Worker upload contract does not provide interim words.
- Browser fields and rich-text editors that do not expose a focused Accessibility text element receive the final dictation as keyboard text after release. Keep the target app and its text field focused until Bibbles finishes.
- New installs default to deterministic Clean dictation; Verbatim remains available in the menu. Clean mode removes a small documented filler set, normalizes spacing, capitalizes the first letter, and adds terminal punctuation without an LLM.
- Select text in another app and hold Control + Option to say “rewrite this” or “isko simple explain karo.” Bibbles reads only the selection; if none is found, it asks you to select text instead of silently sending a screenshot.
- For a pointing question, Bibbles remembers the cursor position at Control + Option release and captures that display area after transcription, so moving the pointer while it thinks does not change the target.
- Point at a chart candle and ask “Explain this candle” for a tight, high-detail crop. Bibbles gives the vision model the captured pointer coordinate, skips unnecessary OCR, and asks it to distinguish the visible body, wick, and color without inventing exact prices or a trading recommendation.
- Ask “How do I export this file?” to search the visible display for the actual control. A small teal locator appears while Bibbles looks; when it finds a reliable target, a click-through guide line and focus frame animate toward it. Bibbles does not move the system pointer or click the control.
- Say “Draw a coral circle here”, “Draw an arrow”, or “Draw a triangle on my screen” while pointing at the desired location. The local doodle canvas supports triangles, circles, rectangles, arrows, lines, underlines, and stars, with teal, coral, violet, or amber ink. These commands use no screenshot or vision API. Add up to 12 shapes on the current display, say “undo drawing” or “clear drawings”, or use the matching menu items. Escape clears the canvas. Asking about a visible object starts a new guidance scene; requests such as “circle this button” and “draw an arrow to Export” still use screen grounding.
- Screen explanations can include up to four numbered doodle callouts, with gentle pen animation and a small paper-colored companion. Invalid or low-confidence annotations are discarded individually; stale captures and changed display geometry do not get marks. The response card chooses an available corner when it would cover the marked objects. Reduce Motion disables the drawing animation.
- Use **Teach a Correction…** to approve a local heard-text → replacement rule. Bibbles never learns a correction silently.
- **Report a Dictation Correction…** stores only an explicitly reported heard/intended term pair locally. After three reports of the same pair, Bibbles offers to add the intended term to technical vocabulary; you must approve it. It never silently monitors edits in other apps.
- The menu shows estimated minutes saved this week from successful dictation, computed locally from 40 WPM typing time minus time spent speaking. No transcript is stored in this metric.
- Control + Command + A: open the full chat window with saved conversations and text/searchable-PDF attachments.
- Escape: close Bibbles panels and cancel any answer still generating. If chat was open near the top-center, the pointer must leave that region and re-enter before chat opens again.
- Double-tap Control: open typed input.

Global modifier monitoring and text insertion may require Accessibility permission. Microphone permission is requested when speech capture first begins. Screen Recording permission is requested when a screen-grounding action is first used. AI chat, screen help, transcription, and spoken answers require Bibbles sign-in; no provider key is configured in the app. Dictation does not call a chat LLM.

Assistant responses stream into the floating response card. The card supports Cancel; failed chat requests support Retry; recoverable STT failures with a non-empty partial expose **Use transcript anyway**.
The answer card offers **Copy** and **Continue in Chat**. After closing it, **Show Last Answer** and **Copy Last Answer** are available from the menu.

## Menu

The menu bar menu stays short: setup items appear only while something still needs attention, followed by everyday actions (Type to Bibbles, Open Chat, Quick Web Search, Show/Copy Last Answer).

- **Task history at the notch**: a small black Bibbles bar wraps the notch (on Macs without a notch it sits at the top centre of the menu bar). It appears on normal desktop Spaces and while Bibbles is listening, dictating, or taking typed input; it stays out of idle full-screen apps. It shows the Bibbles mark, a live waveform while Bibbles listens, a spinner while it works, and how many tasks were done today. Hover it or click it and a panel drops down listing the tasks Bibbles has finished — answers, screen help, web searches, Mac actions, fixes and writing — newest first. Click one to open it in chat. Turn it off in Settings → Show Task History at Notch.
- **Settings**: Account and monthly usage, Speak Answers Aloud, Show Task History at Notch, Voice, Dictation Mode, vocabulary and corrections, Clear Chat History, Open at Login.
- **Help**: Getting Started, Setup Tutorial, About Bibbles, and Permissions.

Setup Tutorial is a floating desktop companion, with live permission detection and automatic progress. Screen access advances only after a valid local ScreenCaptureKit frame; Accessibility advances when macOS reports trust, then demonstrates a native circle around the companion. When Settings is foreground and screen access is available, local OCR can highlight an unambiguous Bibbles row. It never guesses a switch location or changes permissions for you. Setup captures stay local and are discarded; ordinary screen questions may use cloud AI. A required permission restart resumes the pending step. Escape closes setup and cancels polling and marks. Replay from Help → Setup Tutorial, or launch with `open .build/dev-app/Bibbles.app --args --setup-tutorial` after quitting Bibbles.
- **Developer** (hold Option while opening the menu, or set `BIBBLES_DEVELOPER=1`): capture/OCR and screen-grounding tests.

Timing logs are off by default; set `BIBBLES_LATENCY_LOG=1` to write them to `/tmp`. Build for both Apple silicon and Intel Macs with `BIBBLES_UNIVERSAL=1 scripts/build-dev-app.sh`.

## Privacy and safety

- **AI actions are checked.** Mac commands run through a fixed list of tools. Lookups and quick, undoable changes (find files, show a folder, volume, brightness, dark mode) run straight away. Bibbles asks first before anything lasting (reminders, calendar events), anything you didn't name yourself (an app or website other than the one you said, a folder name you didn't say), and before every rename. A search that falls back from the screen to the Mac can only search.
- **Fixing text sends only what you agree to.** A selection is sent as is. Sending the whole editor's text, selecting and copying it in apps that don't share their text, or adding a screenshot (only for requests about errors or things on screen) first shows exactly what will go through the authenticated Bibbles Worker. You can choose "Don't ask again".
- **Pushing to GitHub is reviewed.** `Push-to-GitHub.command` builds and tests first. It stages only app files (tracked changes plus new files in `Sources`, `Tests`, `Resources`, `scripts`, `docs` and `Tools`), blocks API keys and files over 5 MB, and lists everything before asking you to type `y`.

## Tests

```bash
swift test
```

For the Swift tests, offline router contracts, and billing Worker tests (Node.js
required for billing), use the validation entry point below. With only Apple
Command Line Tools, it runs a SwiftPM build and offline contracts instead of
XCTest. Full Xcode is required for the complete Swift test suite.

```bash
sh scripts/check-phase1.sh
```

See [docs/BUILD_PLAN.md](docs/BUILD_PLAN.md) for phase gates and ownership boundaries.
