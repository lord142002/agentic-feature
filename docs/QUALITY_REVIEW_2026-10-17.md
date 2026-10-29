# Bibbles quality review — 17 October 2026

Scope: local `main` based on `3328af3`, with emphasis on the newly integrated
hybrid router, spoken answers, editing and screen walkthrough lifecycles.
This is a targeted code review and regression pass, not a penetration test,
dependency advisory audit, or public-launch certification.

## Findings addressed

- **Delayed insertion after dismissal:** response insertion now uses the existing
  cancellable context task. It checks its generation after both activation and
  Accessibility warm-up, and rechecks the foreground application before pasting.
- **Unsafe rewrite matching:** opening/closing-word matching could select a
  different paragraph that the user had edited. Replacement now needs the entire
  original text, exactly or with quote/whitespace normalization. A failed match
  retains the existing explicit copy-and-paste handoff instead of overwriting.
- **Speech cancellation races:** playback and walkthrough callbacks check their
  generation after suspension. A late request or an old playback loop cannot
  start audio or overwrite the new player's state after Escape/replacement.
- **Metered speech retries:** removed the client retry loop, which created a fresh
  Worker request/idempotency key on every retry. A failure now surfaces once and
  stops playback; text remains available. Already-started lookahead requests may
  still count at the server. Cancellation cannot refund completed requests.
- **Audio retention:** completed PCM tasks are removed, keeping live lookahead
  bounded rather than retaining audio for the whole reply. Stop clears the queue.
- **Walkthrough cancellation:** Cancel/new requests stop the old walkthrough and
  discard its marks and speech metadata. Display changes invalidate pending
  steps, and app switches end walkthrough marks. Ending a walkthrough no longer
  erases the separate local drawing canvas, which previously broke undo.
- **Late selection highlights:** selection/OCR rendering is now tracked context
  work. Escape cancels it rather than allowing a late result to reopen a panel.
- **Input robustness:** serialize router context flags with JSONSerialization;
  reject non-finite/boolean confidence; reject out-of-range tool integers instead
  of crashing on `Int(Double)` conversion.
- **Validation maintenance:** correct a test that assumed the router default was
  off; fix the Settings binding concurrency warning; remove unused voice reveal,
  no-op warm-up and unused speech error state. Replace obsolete raw `swiftc`
  validation with SwiftPM, offline router checks and billing tests.

Two redundant standalone Swift validation files were removed. Their core
contracts are covered by the package's hotkey, coordinate/crop, PCM, routing and
vision tests. They remain recoverable from Git history.

## Security decision

`RouterClient.live()` prefers a saved developer Anthropic key over the
authenticated Worker. This can bypass server accounting and centralized policy
for routing prompts, including when Developer settings are not visible. The user
explicitly requested that this behavior remain unchanged during this review.
Do not describe this configuration as universally Worker-only.

The tracked-file secret-pattern scan found no likely provider tokens, Supabase
secret keys, GitHub tokens or private-key blocks. That is not proof that every
secret format or historical commit has been audited. Ignored local configuration
and Keychain contents were not printed or committed.

## Verification

| Check | Result |
| --- | --- |
| Full Swift XCTest suite with coverage and WindowServer access | 325 tests, 0 failures, 0 skips |
| Optimized arm64 release build | Passed on final sources |
| Offline router self-test | 91/91 checks passed |
| Mocked billing Worker suite | 20/20 tests passed |
| Unified `scripts/check-phase1.sh` entry point | Passed end-to-end before the final canvas regression test was added; the subsequent full suite includes it |
| `git diff --check` and shell syntax check | Passed |

Coverage measured with `llvm-cov report`, excluding `.build` dependencies and
test sources: **25.57% of production lines**. Focused line coverage: coordinate
mapping 98.11%, annotation geometry 100%, hybrid router 62.44%, voice controller
65.59%. The application delegate is only 0.38%; task orchestration still needs
more integration coverage. High focused coverage does not verify a physical
display configuration or the behavior of a deployed model.

The initial baseline was 309 Swift tests: one failed because it assumed the AI
router was off by default, and one panel test skipped without WindowServer
access. The corrected default-state test and final WindowServer-enabled run pass.
There are 16 added regression tests. No production Swift compiler warnings were
reported in the final test build. Some runs emit macOS CoreData/XPC diagnostics
under the test host; all assertions still pass. The restricted release-build
environment can also emit SwiftPM cache warnings unrelated to source compilation.

Re-run the validation on a Mac with full Xcode selected:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer sh scripts/check-phase1.sh
```

The new voice lifecycle tests inject silent playback and synthesis. They do not
contact an AI endpoint, spend usage, play sound or require microphone access.
The billing tests use mocked requests; no payments or account changes are made.
The Command Line Tools-only fallback and Intel build were not exercised. The
running app was not relaunched, and this review has not been committed or pushed.

## Changed file groups

- Lifecycle orchestration: `App/BibblesMain.swift`.
- Speech/playback boundary and state: `Speech/VoiceReplyController.swift`.
- Safe replacement and numeric parsing: `Interaction/FocusedTextInserter.swift`,
  `Intelligence/CommandAgent.swift`.
- Overlay cleanup/invalidation: `Overlay/FloatingPillView.swift`,
  `Overlay/TargetHighlightController.swift`.
- Router serialization/validation and corrected documentation:
  `Routing/HybridRouter.swift`, `Routing/DeveloperControls.swift`.
- Settings closure isolation: `Overlay/SettingsWindowController.swift`.
- Regression tests: `AnnotationLifecycleTests`, `VoiceReplyLifecycleTests`,
  `HybridRouterTests`, `WorkMemoryTests`, `CommandAgentTests`, plus removal of the
  obsolete reveal-state assertion from `VoicePreviewCancellationTests`.
- Validation: `scripts/check-phase1.sh`, two retired standalone validators,
  `README.md`, and this report. Production paths above are relative to
  `Sources/BibblesApp`; tests are in `Tests/BibblesAppTests`.

## Physical Mac / integration checks still required

1. Speak short and 30–60-second English/Hindi/Hinglish requests with real
   microphone input; verify release/finalization and visible error recovery.
2. Escape during routing, speech synthesis, a thinking cue, playback and the
   delayed insertion window. Nothing should type, draw or reopen afterward.
3. Switch apps during an edit handoff; test Notes and a Chromium rich editor.
   Edits to the original draft must not be silently replaced.
4. Test screen annotations while scrolling, changing windows/Spaces, resizing
   and reconnecting Retina/mixed-DPI/rotated displays. Stop stale guidance and
   request a new capture where necessary; unit geometry tests are not enough.
5. Exercise signed-in Worker requests and quota/401/maintenance errors with
   server logs. This pass does not prove deployed Worker or model quality.
6. Profile UI responsiveness and resident memory with Instruments. No live
   dictation/grounding latency or CPU/memory improvement is claimed here.

The application delegate remains large, with limited automated integration
coverage. Extracting orchestration into testable task coordinators is a follow-up,
not something to combine with an uncontrolled rewrite during a bug-fix pass.
