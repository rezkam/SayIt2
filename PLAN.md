# SayIt2: design

How the app works today, and the verified facts behind it. Labels: **Observed** (confirmed by
a command, capture, or source read), **Inferred**, **Unknown**.

## 1. Behaviour

- **Hotkey:** Right Option only. Hold to dictate, release to finish. Double-tap for
  hands-free, tap once more to finish.
- **While you speak:** a black pill rises just above the Dock (or the bottom edge when the Dock
  is hidden or on a side). Five white bars follow your voice and the live words appear beside
  them, wrapping upward onto up to four lines with the newest words kept. Persian is drawn in
  Vazirmatn, right to left. Nothing reaches the text field yet.
- **When you stop:** the provider's final text is inserted once into the text field that had
  focus when dictation started, followed by a space. If focus is elsewhere, insertion waits
  for that field to have focus again.
- **Providers:** ChatGPT (the sign-in shared with the ChatGPT app and codex) or Deepgram Nova-3
  (API key), chosen in the menu. English and Persian are detected automatically.
- **Text:** inserted exactly as the provider returns it. ChatGPT punctuates. Deepgram punctuates
  and formats because the default config enables `smart_format`.
- **No** sounds, clipboard use, settings window, history, telemetry, or test code.

## 2. Files

Native Swift, AppKit only, no third-party dependencies.

| File | Job |
| --- | --- |
| `main.swift` | Starts the menu bar app |
| `App.swift` | Menu bar item and menu, permissions, wiring between hotkey, recordings, insertion and pill |
| `Hotkey.swift` | The Right Option gesture |
| `Dictation.swift` | One recording: audio buffer, connection, retries, timeouts, final text |
| `Audio.swift` | Microphone tap, one conversion to mono PCM16 at the provider's rate, voice level |
| `Transcriber.swift` | One WebSocket connection with ping-based liveness, shared by both providers |
| `ChatGPT.swift` | ChatGPT stream messages |
| `Deepgram.swift` | Deepgram stream messages |
| `Credentials.swift` | ChatGPT sign-in: reading and renewing `~/.codex/auth.json` |
| `Config.swift` | The settings file, the provider list, and the `Problem` error type |
| `Typist.swift` | Inserting final text into the captured field, waiting for focus |
| `Indicator.swift` | The pill |
| `Updates.swift` | Sparkle update checks, shown as a menu item rather than a window |
| `Resources/Fonts` | Vazirmatn (SIL Open Font License) and its license |
| `scripts/build-app.sh` | Build, sign (Sparkle inside out, then the app), optionally notarize |
| `scripts/release.sh` | Release candidate install, and publishing a DMG plus signed appcast to GitHub |
| `docs/pill-mockups.html` | The mockups the pill design was chosen from |
| `AGENTS.md` | Mandates, the feature contract, and rejected approaches (`CLAUDE.md` links to it) |

## 3. Settings

One plain text file, `~/.config/sayit2/config`, opened with **Edit Config…** in the menu. It is
read at the start of every dictation, so saved changes apply without a restart. It is created
on first use with every option listed and explained, and with owner-only permissions because
it holds the Deepgram key.

- `provider = chatgpt` or `deepgram`. The menu's provider choice rewrites only this line, and
  writes nothing if the file cannot be read.
- `deepgram.api_key`, `deepgram.url` (regional servers listed).
- Every other `deepgram.*` line is passed to Deepgram as a query parameter. `encoding`,
  `sample_rate` and `channels` are fixed by the app because they describe the audio it sends.
  `model` is always sent (default `nova-3`); without it Deepgram falls back to an old model.

## 4. Audio

- `AVAudioEngine` input tap on the default microphone, started once a press is confirmed as a
  hold (100 ms) or a double-tap.
- One `AVAudioConverter` step from the hardware format to the wire format:
  - ChatGPT: PCM16, 48,000 Hz, mono; Base64 inside `audio.append`, 4,096 bytes per message.
  - Deepgram: PCM16, 16,000 Hz, mono; binary frames of 100 ms.
- No VAD, gain, noise processing, or file encoding.
- The microphone stays open 0.2 s after you stop, so the end of the last word is not cut off.

## 5. Providers

**ChatGPT**
1. WebSocket `wss://chatgpt.com/backend-api/dictation/stream?dictation_surface=composer&client_type=desktop`
   with `Authorization: Bearer`, `ChatGPT-Account-Id`, `originator`, `User-Agent`, and the
   subprotocols `chatgpt-dictation,codex-desktop`, as captured from the desktop app.
2. `session.start` with the captured config (`pcm16`, 48,000 Hz, 1 channel, `segment` delivery),
   then `audio.append` after `session.started`.
3. `transcript.segment` carries the whole utterance so far with a rising revision;
   `transcript.final` is the last revision. The newest revision per utterance wins.
4. Stop: `session.close`; the final arrives about 0.5 to 1 s later.
5. No time limit. `session_ttl_ms: 300000` (copied from the desktop app) behaves as an
   inactivity timeout: a session that kept receiving audio ran past it (see section 12).
6. After a reconnect, buffered audio is replayed at about 3.2x real time. At 8.5x ChatGPT's
   recognizer fell behind on a 140 s replay and failed (`transcript.failed`,
   `BidiFlushTimeoutError`); at 2x, 3x and 3.2x it returned the complete text.

**Deepgram Nova-3**
1. WebSocket to `deepgram.url` (default `wss://api.deepgram.com/v1/listen`) with
   `Authorization: Token` and the query parameters from the config. Defaults: `model=nova-3`,
   `language=multi`, `language_hint=en`, `language_hint=fa`, `interim_results=true`,
   `endpointing=300`, `smart_format=true`.
2. A final (`is_final: true`) replaces the live text for its stretch of audio and is kept as is.
   The newest interim follows the finals.
3. Stop: `CloseStream`, then read until `Metadata`. From then on only finals count.
4. Flux models are not supported: they use `/v2/listen`, a different protocol, and lack Persian.

## 6. Hotkey

Right Option (key code 61), with the timings of ChatGPT's desktop dictation (Observed in its
installed build 26.1111.21308):

- A press becomes a hold after 100 ms; recording starts then.
- A release before 100 ms is a tap. A second press within 400 ms of a tap starts hands-free.
- A press while hands-free stops. A release in hold mode stops.
- Any other key while Right Option is held (an Option symbol) cancels silently if nothing was
  recognized yet; otherwise the dictation finishes and inserts its text.
- No key is captured or consumed. Key events SayIt2 posts are tagged and ignored by its listener.
- In hold mode the physical key state is also polled, so a missed release cannot leave
  recording on.
- macOS delivers no key events while a password field has secure input, so dictation cannot
  start there.

## 7. Text insertion

- Unicode key events of at most 20 UTF-16 units each, with modifier flags cleared. The
  clipboard is never read or written. (ChatGPT's own cross-app dictation pastes through the
  clipboard instead. Key events reached every app tried, Ghostty included.)
- Before every key event, focus must be in the captured field: the same element, or the
  original element still reporting itself focused. Another app, window, or field pauses
  insertion. Apps that expose no field information are checked at the app level only.
- Text is never abandoned. It waits for its field however long that takes. Dictations into
  the same app are inserted in order; text waiting for one app does not hold up another. If the
  target app quits, the text is inserted into that app's focused field once it is opened again.
- If a dictation ends with an error, the best text received so far is inserted anyway.
- Needs Accessibility permission (also for the hotkey).

Known limits: text still waiting when SayIt2 itself quits is lost. If you move the cursor
before the final text arrives, it is inserted at the new
cursor position. An app that replaces its field object can look like a different field, which
pauses insertion. Apps that read raw key codes instead of text (remote desktop, virtual
machines, some games and Java apps) may not receive it.

## 8. Credentials

- Deepgram: `deepgram.api_key` in the config file.
- ChatGPT: `~/.codex/auth.json`, shared with the ChatGPT app and codex. When the server rejects
  the token (401), SayIt2 renews it once with the refresh token, under the same lock file codex
  uses (`auth.json.lock`), skips renewing if another app already did, and replaces the file in
  one step with owner-only permissions. A refused renewal shows "Sign in to ChatGPT again".
  The server has ended a token five days before its own expiry date (Observed), which is why
  SayIt2 renews rather than relying on the ChatGPT app.
- Unknown: whether a running ChatGPT app re-reads the file before its own next renewal. If it
  does not, it may ask to sign in again after SayIt2 renewed.

## 9. Reliability

Every audio byte the provider has not finalized is kept. A retry opens a new connection and
replays it; since nothing reaches the text field before the end, a retry can neither lose nor
duplicate text. While a replay catches up, the pill keeps showing the earlier text.

| Failure | Response |
| --- | --- |
| Connection fails, drops, or shows no sign of life for 5 s (no message, no answer to a ping sent every 2 s) | Reconnect after 0.3 s, then 1 s; up to 2 retries in a row. Recording continues |
| All audio sent and the server silent for 10 s | Treated as a drop |
| ChatGPT asks the client to stop | Finish normally |
| ChatGPT token rejected | Renew once, reconnect, replay |
| Deepgram 401 / 403 / 400 | "Key rejected" / "No access to this model" (often a misspelled name) / "Rejected the config". Not retried |
| Missing ChatGPT sign-in or Deepgram key | Message in the pill and the menu |
| Microphone missing, denied, or changed mid-recording | Stop and finish with what was captured |
| Retries exhausted | Insert the best text so far, show the reason for 3 s |

Callbacks from an older connection or recording are ignored.

Private-endpoint risk: the ChatGPT stream is an internal, undocumented interface used with the
desktop app's client headers. It can change with any ChatGPT update and is outside the
published API terms. Each ChatGPT stream ends with an `asset.ready` event, so the server may
keep the session audio (Inferred). SayIt2 stores no audio and no transcripts.

## 10. Indicator and menu bar

| State | Pill |
| --- | --- |
| Idle | Not on screen |
| Hold | Bars follow the voice; live words beside them |
| Hands-free | Same, plus a small square ("tap to stop") |
| Finishing | Bars become a slow wave, words dimmed |
| Waiting for the target field | Bars dim and stand still, words dimmed |
| Problem | Red flat bars and a short message for 3 s |

The pill is a click-through, non-activating panel above all apps and full-screen spaces; it
never takes focus.

Menu bar icon: four black bars (follows a dark menu bar). While recording they move with your
voice. Dimmed with a badge when Accessibility, the microphone, or the provider's credentials are
missing. The menu's first line shows the version and build.

## 11. Build, sign, version, release, update

- `bash scripts/build-app.sh` builds `build/SayIt2.app` with Sparkle in `Contents/Frameworks`,
  signs it with the Developer ID certificate (hardened runtime, secure timestamp, microphone
  entitlement); `--notarize` also notarizes and staples it. Notarizing needs the Mac unlocked.
- `bash scripts/release.sh rc` builds a notarized release candidate and installs it to
  `/Applications`. `bash scripts/release.sh publish` then releases that same commit: it requires a
  clean tree, the commit on `origin/main`, and an unreleased `VERSION`; builds a signed and
  notarized DMG (the app plus a link to Applications); writes an `appcast.xml` with the DMG's
  EdDSA signature and signs the feed itself; creates the GitHub release `v<VERSION>` with both
  files; and re-downloads the DMG to check it matches and passes Gatekeeper.
- Updates: Sparkle reads `https://github.com/<repo>/releases/latest/download/appcast.xml` once a
  day. It requires a signed feed and a signed archive, verified with the public key in the app.
  The private key is in the login Keychain (Sparkle account `sayit2`), never in the repository.
  A newer version appears in the menu as "Update to SayIt2 X.Y.Z…" with a dot on the icon;
  choosing it opens Sparkle's window, which downloads, verifies, installs and relaunches.
  Builds without a known GitHub repository have updates switched off.
- Signing identity, notary profile, bundle ID and repository come from environment variables
  (`SAYIT2_*`, signing falling back to `SPEAKFLOW_*`) or the git remote. Nothing identifying is
  stored in the repository.
- Version: the `VERSION` file. Build number: the number of commits.
- Builds use `xcrun` because the second Swift toolchain on PATH fails against the current SDK
  (Observed).

## 12. Verified facts

All live checks used synthetic speech and one public-domain Persian clip, not a real voice.

| Topic | Finding | Label |
| --- | --- | --- |
| ChatGPT audio | PCM16, 48,000 Hz, mono, Base64 in JSON, about 43 ms per message | Observed (capture, re-run live) |
| ChatGPT utterances | A 42.5 s recording with pauses came back as one utterance: 135 revisions, one final | Observed |
| ChatGPT replay speed | 42.5 s of audio sent at 20x was transcribed 12 s after close | Observed |
| ChatGPT cross-app dictation in its own app | Batch upload after release, then clipboard paste | Observed (research guide) |
| Deepgram audio | `linear16`, 16,000 Hz, mono, binary frames | Observed |
| Deepgram `interim_results` | Default `false` gives no live text; `true` gives updates about once a second | Observed |
| Deepgram languages | `language=multi` with hints `en` and `fa` detected both | Observed |
| Deepgram word loss | A final sometimes has one to five fewer words than its live text, at stretch boundaries; not repeatable run to run | Observed |
| Deepgram replay speed | About 1.3x real time with `language=multi` | Observed |
| Both servers | Answer WebSocket pings while a receive is pending | Observed |
| ChatGPT session length | 373 s (6.2 min, 5 or 30 minutes requested) and 746 s (12.4 min, 5 minutes requested) of continuous audio in one session each returned the complete final 0.6 s after close. The server accepts any requested `session_ttl_ms` (tried up to 24 h) and sets expiry to last activity plus that value | Observed |
| ChatGPT replay pace | 140 s replayed at 8.5x failed with no final; at 2x, 3x, 3.2x complete | Observed |
| ChatGPT long sessions | The server stops saving its own copy of the audio (`asset.failed: capture_cap_hit`); text unaffected | Observed |

## 13. Manual checks still open

Tried by the user so far: hold and double-tap on both providers, switching apps and back (in
earlier versions that typed live). Not yet tried on the current version:

1. Hold, speak, release: words in the pill, then one insertion; clipboard unchanged.
2. Persian with a real voice, on both providers.
3. Double-tap, speak with pauses, tap: one insertion.
4. Single short tap: nothing happens. Right Option plus a letter: the symbol types, nothing is inserted.
5. Switch to another app before the text arrives, then come back: it is inserted on return.
6. Wi-Fi off mid-sentence and back on.
7. A long dictation: the pill wraps and keeps the newest words.
8. Apps: a native text field, a browser, a terminal, an Electron app.
