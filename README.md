# SayIt2

A minimal macOS menu bar dictation app. Hold Right Option and speak: your words appear in a
small pill above the Dock, and when you stop, the text is inserted into the app you were in.
No window, no sounds, no clipboard use.

- **Hold** Right Option to dictate, release to finish.
- **Double-tap** Right Option for hands-free, tap once more to finish.
- Pick **ChatGPT** or **Deepgram Nova-3** in the menu bar menu. SayIt2 records from the
  system default microphone and recovers to the current default if it is unplugged.
- If focus has left the text field when the text is ready (another app, window, or field),
  it waits and inserts the text when you return to that field.

## Install

Download `SayIt2-<version>.dmg` from the latest GitHub release, open it, and drag SayIt2 to
Applications. On first launch, grant Accessibility (for the hotkey and inserting text) and
Microphone access. New versions are offered in the menu ("Update to SayIt2 X.Y.Z…").

## Build

```sh
bash scripts/build-app.sh              # build and sign build/SayIt2.app
bash scripts/build-app.sh --notarize   # also notarize with Apple
bash scripts/release.sh rc             # notarized release candidate, installed to /Applications
bash scripts/release.sh publish        # release the tested rc build on GitHub (run rc first)
```

Requires Xcode. The first line of the menu shows the version and build number.

## Settings

Everything is in one text file, `~/.config/sayit2/config`. Open it with **Edit Config…** in
the menu. Saved changes apply to the next dictation.

- **ChatGPT** uses the sign-in shared by the ChatGPT desktop app and codex on this Mac
  (`~/.codex/auth.json`), so there is nothing to set. SayIt2 renews it when it expires and
  saves it back there. This is a private interface and may stop working. Text is inserted exactly
  as ChatGPT returns it.
- **Deepgram** needs `deepgram.api_key`. Every other `deepgram.*` line is passed to Deepgram's
  live streaming API as a parameter (model, language, formatting, key terms and so on); the
  file lists them all with a short explanation.

## Crash and error reports

Builds made with a Sentry DSN (`SAYIT2_SENTRY_DSN`, or looked up for the Sentry project `sayit2`
with a signed-in `sentry` tool) send crash reports, app hangs, and the short
problem messages the pill shows (such as "Can't reach ChatGPT") to Sentry. They never include
what you said, audio, device names, settings, or IP addresses, nothing in them identifies
the installation or the Mac, and network activity is not recorded. Builds without a DSN send
nothing. Each published release uploads its debug symbols to Sentry, so crash reports show
function names.

## Telemetry and usage

SayIt2 writes local telemetry and daily usage counters under `~/.local/share/sayit2/`.
Nothing leaves your Mac.

- `~/.local/share/sayit2/otel/{traces,metrics,logs}.jsonl` holds OpenTelemetry traces, metrics,
  and logs in OTLP/JSON Lines format (each file rotates at 10 MB, keeping 5 archives).
- `~/.local/share/sayit2/usage_stats.json` keeps daily totals of recordings, audio seconds,
  words, and characters, broken down by model, language, hour of day, trigger mode, and target
  app bundle ID.
- No audio is ever saved. Transcript text and raw provider messages are omitted by default; set
  `telemetry.transcripts = true` in `~/.config/sayit2/config` to write them to
  `~/.local/share/sayit2/otel/logs.jsonl` for debugging (they are never sent to Sentry).

Example with `jq` to print audio seconds per day per model:

```sh
jq -r '.days | to_entries[] | .key as $d | .value.byModel | to_entries[] | "\($d)\t\(.key)\t\(.value.seconds)"' ~/.local/share/sayit2/usage_stats.json
```

## Limits

- Deepgram's final text sometimes leaves out a word or a few that its live text showed; the
  final text is used as is.
- If you move the cursor before the text arrives, it is inserted at the new position.
- If the original text field no longer exists when the text arrives, it is inserted into whatever
  field of that app has focus.
- Text still waiting for its field is lost if SayIt2 itself quits.
- Dictating with Bluetooth headphones' microphone switches them to call mode, which lowers
  playback quality until the dictation ends (true of every app). Choose the built-in microphone
  in macOS settings to keep music quality.
- Apps that read raw key codes instead of text (remote desktop, virtual machines, some games)
  may not receive the text.
