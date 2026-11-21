# SayIt2: mandates

SayIt2 is a minimal macOS menu bar dictation app. It exists because the previous app became
unreliable and too complicated. Read this file before changing anything; it says what the app
must stay. The code and `README.md` describe how it works.

## The guiding principle

Build the smallest app that reliably does exactly what is listed here, and nothing more.
Reliability, simplicity, and consistency come before features. It should be as dependable as
dictation in the ChatGPT desktop app.

## Mandates

0. **Never lose text.** Whatever ends a dictation (release, tap, error, timeout, dropped
   connection, expired sign-in, microphone loss, focus away, the target app quitting), the
   words recognized so far must reach the text field. Text waits for its field as long as it
   takes. Only a dictation in which nothing was recognized may end without inserting anything.
1. **Small and readable.** Native Swift and AppKit. No layers of abstraction. One file per
   concern. A protocol, service, or helper type needs at least two real users. The whole app is about 1,500 lines; keep it near that.
2. **No tests.** No test files, test targets, test tooling, or test harnesses in the repository.
   The user tests by hand. Verify a change by building it and, where needed, by a one-off check
   outside the repository that is deleted afterwards.
3. **No feature creep.** Do not add a feature, setting, or option that is not listed below
   without asking first. Do not keep something only because an earlier version had it.
4. **Delete over patch.** When an approach stops being used, remove its code, comments, and
   documentation in the same change. No dead code, no compatibility shims, no leftovers.
5. **Settings live in one text file.** No settings window. New settings go in
   `~/.config/sayit2/config`, are explained in its template, and apply on the next dictation.
6. **Silent and private.** No sounds. No clipboard use. No audio or transcript history. Never
   write keys or personal data anywhere but the config file and the shared ChatGPT sign-in file.
7. **Keep the docs true.** A change in behaviour updates this file and `README.md`
   in the same commit.
8. **Every build is versioned, and releases are tested first.** Bump `VERSION` for each build
   handed to the user. Builds are signed with the Developer ID certificate and notarized.
   Releases follow `scripts/release.sh`: `rc` installs a release candidate, the user tries it,
   and only then `publish` releases that tested `rc` build (requiring `rc` for that commit first).
   Never publish without the user's go-ahead.

## Features (the contract)

**App**
- Menu bar app only: no window, no Dock icon. No launch at login.
- Menu: version and build, status or hint line, provider choice (ChatGPT, Deepgram Nova-3),
  Edit Config…, permission shortcuts only while a permission is missing, Check for Updates…,
  Quit. When a daily check finds a newer release, "Update to SayIt2 X.Y.Z…" appears at the top
  of the menu. The menu bar icon does not change and no window pops up on its own.
- Crash and error reports through Sentry (`Reports.swift`, Sentry project `sayit2`), only in
  builds with a DSN (`SAYIT2_SENTRY_DSN`, else looked up with the signed-in `sentry` tool).
  `release.sh publish` uploads the release's dSYM so stack traces are readable. Reports carry crashes, hangs, and the pill's problem messages. Never transcripts, audio,
  device names, settings, keys, IP addresses, or anything that identifies the installation or
  the Mac; network breadcrumbs, failed-request capture, and session tracking are off; no
  performance tracing.
- Installed from a notarized DMG on GitHub releases; updates through Sparkle, signed with the
  update key in the login Keychain (Sparkle account `sayit2`).

**Hotkey**
- Right Option is the only shortcut. Hold to dictate, release to finish. Double-tap for
  hands-free, tap once more to finish. Timings follow ChatGPT's desktop app: 100 ms to confirm
  a hold, 400 ms between the taps of a double-tap.
- Another key pressed with Right Option (an Option symbol) cancels silently if nothing was
  recognized yet; otherwise the dictation finishes and inserts its text.
- No time limit on a dictation.
- Never capture, consume, or repurpose any other key, including Escape and Enter.

**Providers**
- ChatGPT streaming, using the sign-in shared with the ChatGPT app and codex
  (`~/.codex/auth.json`). SayIt2 renews it itself when the server rejects it, and writes the
  renewed tokens back, so the user never has to open the ChatGPT app.
- Deepgram Nova-3 streaming, with its API key and every parameter in the config file.
  `interim_results=true` (needed for live words) and `smart_format=true` by default.
- Microphone: the system default. If it is lost mid-dictation, recording switches to the current
  system default without a message. Only real problems, such as a muted microphone, are shown.
- Audio formats match the working reference apps: ChatGPT PCM16 48 kHz mono, Base64 in JSON;
  Deepgram PCM16 16 kHz mono, binary frames. macOS delivers the capture at that rate.
- Microphone handling follows the ChatGPT and Claude apps: input-only capture, a fallback to
  the system default, a device lost mid-dictation replaced without ending the dictation, a
  health watch (no audio: recover; only zeros: tell the user). Audio is sent as captured: no noise suppression, gain or
  echo cancellation (see the measured facts).
- English and Persian, detected automatically on both providers.

**Text**
- While speaking, the live words are shown only in the pill. Nothing touches the text field.
- When done, the provider's final text is inserted once, as the provider returned it
  (punctuation kept). The final text always wins over the live text.
- Insertion uses Unicode key events, never the clipboard, and goes to the text field that had
  focus when dictation started. If focus is elsewhere, it waits until that field is back, with
  no time limit. If that field no longer exists, it inserts into whatever field of the app has
  focus. If the target app quit, it waits for that app to be opened again and to finish
  launching.
- If a dictation fails, the best text received so far is still inserted.

**Look**
- The pill: black, just above the Dock, with five white bars that follow the voice and the live
  words beside them. It grows upward up to four lines and always keeps the newest words visible.
  Persian is drawn in Vazirmatn, right to left.
- Menu bar icon: monochrome `Si²` mark at rest, four bars that move with the voice while
  recording, never red.
- No animations or controls beyond these.

**Reliability**
- Retries replay buffered audio and must never lose or duplicate text.
- Connection failures, timeouts, expired sign-ins, and microphone loss always return the app to
  a clean idle state with a short message in the pill.

## Out of scope

Local transcription models, batch transcription, voice activity detection, more shortcuts, Escape or Enter handling, settings screens, customization beyond
the config file, recording or transcript history, launch at login, automated tests, sounds.

## Measured facts the code relies on

Measured with synthetic speech and one public-domain Persian clip, not a real voice.

- ChatGPT stream: PCM16 48 kHz mono, Base64 in JSON. One session ran 12.4 minutes of continuous
  audio and returned the complete final 0.6 s after close; `session_ttl_ms` acts as an idle
  timeout, not a cap. Replaying 140 s at 8.5x failed with no final; 2x to 3.2x worked, so
  replays are capped near 3.2x.
- Deepgram: `linear16` 16 kHz mono binary frames. `interim_results=false` (the default) gives
  no live text. `language=multi` with hints `en` and `fa` detected both. Finals sometimes miss
  words at stretch boundaries, not repeatable run to run. Replays run at about 1.3x real time.
- Both servers answer WebSocket pings while a receive is pending (used for liveness).
- The ChatGPT server once ended a sign-in five days before the token's own expiry, which is why
  SayIt2 renews it.
- Microphone capture uses AVCaptureSession (input only), like the browser engines the ChatGPT
  and Claude apps record with. AVAudioEngine also drives the output side; with Bluetooth
  headphones as speaker and microphone it kept reporting configuration changes and recorded
  0 s of audio. AVCaptureSession delivered audio after 0.06 s on the same headset, already in
  the wire format (48 or 16 kHz mono PCM16).
- Like Claude's app, a microphone unplugged mid-dictation is replaced by the system default and
  recording continues, and SayIt2 watches microphone health as Claude's app does.
- Apple's voice isolation effect (`AUSoundIsolation`) removed 45 to 49 dB of synthetic noise and
  left clean synthetic speech intact, but on real room noise from a Bluetooth headset ChatGPT
  invented text from the processed audio (2 of 6 recordings, with or without added gain) and
  from none of 5 raw recordings. A user dictation with it produced unrelated text. Removed.
- Recording from Bluetooth headphones' microphone puts them in call mode (playback drops from
  44.1 kHz until recording ends). Expected for every app.
- Retries: a replay can produce live text and still fail again, so the reconnect count per
  dictation (at most three) is never reset; otherwise a failing dictation looped forever.
- Unknown: whether a running ChatGPT app re-reads `~/.codex/auth.json` before its own renewal.

## Tried and rejected

Do not bring these back without the user asking.

| Approach | Why it was dropped |
| --- | --- |
| Typing live into the text field with corrections | Visible backspacing and garbled text; replaced by one insertion at the end |
| Checking the cursor position before corrections | Misfired in terminals such as Ghostty and glued corrections onto words ("badter") |
| Putting back words Deepgram's final text skipped | The user prefers Deepgram's final text as is |
| Stripping punctuation from ChatGPT text | The user wants text exactly as the provider returns it |
| Deepgram key in the Keychain, set through a dialog | Replaced by the config file, which holds every setting |
| Reading the ChatGPT sign-in read-only | The server ended a token early; SayIt2 now renews it itself |
| Pill under the notch at the top of the screen | Moved to the bottom, above the Dock |
| Red menu bar icon while recording | The icon stays black |
| Auto-stop at 4 min 45 s for ChatGPT | Measured: sessions run past 5 minutes; stopping cut off speech |
| Abandoning text after 2 minutes, or when dictating in another app | Lost text; it now waits |
| Replaying audio at 8.5x after a ChatGPT reconnect | ChatGPT's recognizer failed on long replays; capped at 3.2x |
| A dot on the menu bar icon for an available update | Did not read as "new version"; updates show only in the menu |
| Noise suppression (Apple voice isolation) and gain control | Made ChatGPT invent text from background noise |
| AVAudioEngine for microphone capture | Recorded nothing from Bluetooth headphones; replaced by AVCaptureSession |
| Clipboard and paste for insertion | Unicode key events reach every app tried and leave the clipboard alone |

## Working in this repository

- No pull requests. Commit in a worktree, then push the commits straight to `main` as a
  fast-forward. Never open a PR in this repository.
- Build: `bash scripts/build-app.sh` (add `--notarize` for a build to hand over). Release:
  `bash scripts/release.sh rc`, then `bash scripts/release.sh publish` after the user's approval. Builds use
  `xcrun`; the other Swift toolchain on PATH fails against the current SDK.
- Launch the installed build through Finder or `open`, never by running the binary directly.
- Signing identity and notary profile come from environment variables; never store them,
  keys, or personal data in the repository.
- No em dashes in code, comments, docs, or commit messages.
