# SayIt2

A minimal macOS menu bar dictation app. Hold Right Option and speak: your words appear in a
small pill above the Dock, and when you stop, the text is inserted into the app you were in.
No window, no sounds, no clipboard use.

- **Hold** Right Option to dictate, release to finish.
- **Double-tap** Right Option for hands-free, tap once more to finish.
- Pick **ChatGPT**, **Deepgram Nova-3**, or **ElevenLabs Scribe** in the menu bar menu. SayIt2 records from the
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

Everything is stored in one plain text file, `~/.config/sayit2/config`. Open **Settings…**
(`Cmd+,`) in the menu bar to edit settings per provider in your default browser, or edit the
file directly. Saved changes apply on the next dictation.

- **ChatGPT** uses the sign-in shared by the ChatGPT desktop app and codex on this Mac
  (`~/.codex/auth.json`). SayIt2 renews it when it expires and saves it back there. This is a
  private interface and may stop working. Its vocabulary hint support is not verified. The
  separate OpenAI transcription API's `keywords` setting is not sent to this interface.
- **Deepgram** needs `deepgram.api_key`. Every other `deepgram.*` line is passed to Deepgram's
  live streaming API as a parameter (model, language, formatting, key terms and so on); the
  file lists them all with a short explanation.

- **ElevenLabs** needs `elevenlabs.api_key` and defaults to `scribe_v3_live`. Set it up
  under **Settings… > ElevenLabs**. Use `transcript_edit` to give the model a formatting
  instruction for each committed segment. It is experimental, adds cost, and cannot be
  combined with entity detection or redaction. Live text is unedited, and a missing edit
  falls back to the original. With redaction on, SayIt2 hides unredacted text in the pill,
  skips raw message logging, and inserts `[redaction unavailable]` if redaction fails.
  Manual commits are the default. Voice activity and turn prediction segment text on the
  server. If an automatic stream drops after a commit, SayIt2 inserts the recognized text
  without replaying the audio, since the service does not give an exact replay boundary.
  The Settings page exposes the realtime options, including model, language, segmentation,
  keyterms, and metadata. Leave the primary language blank for automatic detection; set it
  to `en` for English or `fa` for Persian if you want one language. Use multilingual mode
  on Scribe v3 Live when switching languages within one dictation. `no_verbatim` removes
  fillers and disfluencies; it is not a punctuation control. SayIt2 does not automatically
  replace Scribe's punctuation. Provider-side logging is separate from local telemetry;
  zero retention may require an enterprise plan.

**Settings → Vocabulary** separates provider hints from local replacements. Deepgram Nova-3
and ElevenLabs accept hints for terms you'd like them to recognize. Hints are not guarantees.
Provider-side edits, such as Deepgram's `replace` and ElevenLabs' `transcript_edit`, are labeled
in their provider tabs. For any provider, set a local `text.replace = example term => Example Term`
rule in Vocabulary or the config file. There are no default rules. Matching is literal and
case-sensitive, uses whole-word edges for words, and applies once to the final text only.
The rules themselves are not sent to any provider.

## Telemetry and usage

SayIt2 writes local telemetry and daily usage counters under `~/.local/share/sayit2/`.
Nothing leaves your Mac unless you configure an OTLP endpoint.

- `~/.local/share/sayit2/otel/{traces,metrics,logs}.jsonl` holds OpenTelemetry traces, metrics,
  and logs in OTLP/JSON Lines format (each file rotates at 10 MB, keeping 5 archives).
- `~/.local/share/sayit2/usage_stats.json` keeps daily totals of recordings, audio seconds,
  words, and characters, broken down by model, language, hour of day, trigger mode, and target
  app bundle ID. Open **Dashboard…** in the menu bar to view a live yearly heatmap, peak hours,
  per-day stats, and settings in your default browser (served on `127.0.0.1` only).
- No audio is ever saved. Transcript text and raw provider messages are omitted by default; set
  `telemetry.transcripts = true` in `~/.config/sayit2/config` to include them in the OTel log
  stream for debugging.
- To also ship traces, cumulative metrics, and logs to an OTLP/HTTP backend such as Grafana
  Cloud, set `telemetry.otlp.endpoint` and `telemetry.otlp.authorization` in
  `~/.config/sayit2/config` (applies on the next dictation). If `telemetry.transcripts = true`
  is also set, those log records are sent to the configured endpoint too.

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
