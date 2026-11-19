# SayIt 2: implementation plan

Status: decisions settled (section 2), implementation in progress.

Visual mockups to choose from: `docs/mockups.html` (open it in a browser).

Labels used below: **Observed** (confirmed by a command, capture, or source read),
**Inferred**, **Unknown**.

## 1. What was verified

All live checks used a synthetic spoken phrase and one public-domain Persian clip. Probe
scripts are in `.agents/probes/` (not committed).

| Topic | Finding | Label |
| --- | --- | --- |
| ChatGPT live dictation transport | WebSocket `wss://chatgpt.com/backend-api/dictation/stream?dictation_surface=composer&client_type=desktop`, subprotocols `chatgpt-dictation,codex-desktop`, JSON text frames | Observed (guide section 4, re-run live) |
| ChatGPT audio format | PCM16 little-endian, 48,000 Hz, mono, Base64 inside `audio.append`, about 4,096 bytes (2,048 samples) per message | Observed (guide section 14, re-run live) |
| ChatGPT live text | `transcript.segment` carries the full text of the utterance with a rising `revision`; `transcript.final` ends it. A 42.5 s recording with pauses came back as one utterance, 135 revisions, one final | Observed |
| ChatGPT stop | Send `session.close`; final arrived 0.7 to 1.1 s later; server then closes with code 1000 | Observed |
| ChatGPT from a third-party client | A standalone client (Python, then native `URLSessionWebSocketTask`) was accepted using the desktop app's token and client headers | Observed |
| ChatGPT cross-app dictation in the real app | Used batch upload, not streaming, and pastes through the clipboard. Only its composer shows live text | Observed (guide sections 2, 7) |
| ChatGPT credentials | Stored in `~/.codex/auth.json` (mode 0600), not in Keychain. Access token lifetime 10 days. The desktop app refreshes it | Observed (file shape and token dates; no secret printed) |
| ChatGPT session limit | The client requests `session_ttl_ms: 300000` (5 minutes). What the server does at 5 minutes | Unknown |
| ChatGPT catch-up speed | 42.5 s of audio sent at 20x speed was fully transcribed 12 s after close (about 3.5x real time) | Observed |
| ChatGPT punctuation | Output is punctuated and capitalized. No option to disable it was found in the client code | Observed / Unknown if a server option exists |
| Deepgram format | `linear16`, 16,000 Hz, mono, raw binary frames (same as the Claude path that reaches `deepgram-nova3`) | Observed (guide section 13, re-run live) |
| Deepgram `interim_results` | Default is `false`. With `false` there is no live text, only finals every few seconds. `true` is required: interims arrived about once per second and were corrected in later messages | Observed (docs and live comparison) |
| Deepgram languages | `model=nova-3&language=multi&language_hint=en&language_hint=fa` is accepted. English and Persian were both detected with no manual switch | Observed |
| Deepgram plain text | Leaving out `smart_format` and `punctuate` returns lowercase text with no punctuation | Observed |
| Deepgram stop | Send `CloseStream`; server flushes remaining finals, sends `Metadata`, closes with 1000 (about 250 ms). `Metadata` or the clean close is the end marker | Observed |
| Deepgram idle timeout | Connection closes after 10 s with no audio and no `KeepAlive` (text frame). Not a concern while audio flows continuously | Observed (docs) |
| Deepgram catch-up speed | In `multi` mode, replayed audio was processed at only about 1.3x real time | Observed |
| ChatGPT hotkey timing | Press starts a hold session, confirmed after 100 ms. A press shorter than 100 ms is a tap. A second press within 400 ms of a tap starts hands-free. A press during hands-free stops it | Observed (installed build 26.1111.21308) |
| Text insertion without clipboard | Unicode keyboard events in bursts of at most 20 UTF-16 units, already used by SpeakFlow's batch path | Observed in SpeakFlow code; per-app behavior needs your test |
| Toolchain | The Xcode toolchain builds fine. The second Swift toolchain on PATH fails against the current SDK, so builds go through `xcrun` | Observed |

## 2. Decisions

Settled on 2026-11-19.

1. **Indicator:** concept A (drop pill), voice bars only, white accent, size M, menu bar glyph 2 (bars).
2. **Live text:** typed straight into the focused text field while you speak, with corrections.
   The pill shows no text (except a short message when something is wrong).
3. **Focus:** the app that was focused when dictation started is the target. If another app
   comes to the front, typing pauses and resumes when the target app is back.
4. **Punctuation:** none. Deepgram is asked for plain text. ChatGPT text has punctuation marks
   stripped locally (apostrophes and marks inside a word or number are kept, capitals are kept).
5. **ChatGPT credentials:** read `~/.codex/auth.json` read-only on every connection, never refresh.
6. **Length limit:** auto-finish at 4 min 45 s on ChatGPT (its sessions last 5 minutes), no cap on Deepgram.
7. **Name:** the app is "SayIt 2" everywhere; `sayit2` or `SayIt2` where a space is not allowed.

## 3. Shape of the app

Native Swift, AppKit only, zero third-party dependencies, no window, no tests.
About 1,200 lines including comments.

| File | Job |
| --- | --- |
| `App.swift` | Menu bar item, menu (provider choice, Deepgram key, permission status, quit), wiring |
| `Hotkey.swift` | Right Option gesture: hold, double-tap, tap to stop |
| `Audio.swift` | Microphone tap, one conversion to mono PCM16 at the provider's rate, voice level |
| `Dictation.swift` | One recording from key press to inserted text: buffer, timeouts, retry |
| `Transcriber.swift` | One streaming WebSocket connection, shared by both providers |
| `ChatGPT.swift` | ChatGPT stream messages, punctuation stripping |
| `Deepgram.swift` | Deepgram stream messages |
| `Indicator.swift` | The floating indicator |
| `Typist.swift` | Live typing into the target app, corrections, focus waiting |
| `Credentials.swift` | Keychain (Deepgram key), read-only ChatGPT token file |
| `Config.swift` | `~/.config/sayit2/config` (plain `key = value` text) |

Config file contents: `provider = chatgpt` or `provider = deepgram`. The menu writes the same
file. Nothing else is configurable.

## 4. Audio

- `AVAudioEngine` input tap on the default microphone, started on key down.
- Exactly one `AVAudioConverter` step from the hardware format to the wire format:
  - ChatGPT: PCM16, 48,000 Hz, mono. Sent as Base64 in `audio.append`, 4,096 bytes per message.
  - Deepgram: PCM16, 16,000 Hz, mono. Sent as binary frames, 100 ms each.
- No VAD, no gain, no noise processing, no file encoding.
- A voice level (RMS of each buffer) drives the indicator so you can see it hears you.

## 5. Providers

**ChatGPT**
1. Open the WebSocket with `Authorization: Bearer`, `ChatGPT-Account-Id`, `originator`,
   `User-Agent`, and the two subprotocols, as captured.
2. Send `session.start` with the captured config (`pcm16`, 48,000, 1 channel,
   `transcript_delivery_mode: segment`).
3. Wait for `session.started`, then send `audio.append`.
4. Text: keep the latest revision per `utterance_id`, in arrival order.
5. Stop: send `session.close`, wait for `transcript.final`.
6. No asset upload, no batch fallback.

**Deepgram Nova-3**
1. Open `wss://api.deepgram.com/v1/listen` with `Authorization: Token`, query:
   `model=nova-3`, `language=multi`, `language_hint=en`, `language_hint=fa`,
   `encoding=linear16`, `sample_rate=16000`, `channels=1`, `interim_results=true`,
   `endpointing=300`. No `smart_format`, no `punctuate`.
2. Text: finals (`is_final: true`) are appended and never change. The newest interim
   replaces the previous interim after them.
3. Stop: send `CloseStream`, read until `Metadata` or a clean close.

**Language notes**
- ChatGPT: no language setting exists in the stream; detection is automatic. Persian and
  English both worked. Mixed sentences are untested.
- Deepgram: `multi` handles both and reports the detected language per result. Persian word
  spacing differs slightly from ChatGPT's (for example separate "می شود").

## 6. Hotkey

Right Option only (key code 61), matching ChatGPT's timings:

- Press: nothing visible yet. After 100 ms of holding, recording starts (hold mode).
- Release before 100 ms: it was a tap. Nothing started. The tap is remembered.
- Second press within 400 ms of that tap: hands-free mode starts at once. Release is ignored.
- Press while hands-free: stop.
- Release in hold mode: stop.
- Any other key or modifier pressed while Right Option is held (typing a symbol such as `@`
  on layouts that need Option): cancel silently, so Option combinations keep working.

One deliberate difference from ChatGPT: it starts the microphone on key down and throws the
audio away if the press turns out to be a tap. SayIt 2 waits the same 100 ms before touching the
microphone, so typing Option symbols never flashes the microphone indicator.

No other key is captured or consumed. Key events SayIt 2 posts itself are tagged and ignored
by its own listener.

Safety net: in hold mode the physical key state is polled, so a missed release event cannot
leave recording stuck on.

Limit: macOS does not deliver key events while a password field has secure input, so
dictation cannot start there.

## 7. Text insertion

Live typing with a single rule: SayIt 2 remembers exactly what it has typed (`typed`) and what
the transcript currently says (`target`). One loop makes `typed` equal `target`:

- If `typed` is a prefix of `target`: type the missing part (Unicode key events, at most
  20 UTF-16 units per event).
- Otherwise: backspace to the common prefix, then type.

Only the newest transcript matters, so updates can never be applied out of order or twice.

- Before every key event the focused app is checked. If it is not the target app, the loop
  waits. When the target app is back, it continues from where it stopped.
- Starting a new dictation in a different app abandons text still waiting for another app.
  Dictations into the same app are typed in order.
- Events carry no modifier flags, so text and backspaces behave normally while Right Option
  is still held.
- Backspaces are counted in Unicode scalars of NFC text. Checked in a native text view: this
  is correct for Latin, Persian, and the zero-width non-joiner.
- A trailing space is added when a dictation finishes.
- The clipboard is never read or written.
- Needs Accessibility permission (for both the hotkey and typing). If it is missing, the menu
  bar icon shows a warning and the menu offers to open the settings pane.

Known limits: the focus check is per app, not per text field. If you move the cursor or type
in the target field while dictating, a later correction can backspace the wrong characters.
Apps that ignore synthetic Unicode events will not receive text.

## 8. Credentials

- Deepgram: one Keychain generic-password item owned by SayIt 2. Set through
  "Set Deepgram API Key…" in the menu (a small secure text prompt).
- ChatGPT: see decision 5. The token's expiry is checked locally before connecting so the
  message is clear ("open ChatGPT to sign in") instead of a failed connection.

## 9. Reliability

SayIt 2 keeps every audio byte the provider has not finalized. A retry opens a new connection
and replays that audio. Because typing always converges on the newest transcript, a replay
cannot produce duplicate text. While a replay is catching up, shorter transcripts are held
back so text already typed is not erased and retyped.

| Failure | Response |
| --- | --- |
| Connection fails to open, drops, or sends nothing for 5 s | Reconnect (after 0.3 s, then 1 s), up to 2 retries in a row. Recording continues |
| Reconnect on Deepgram | Resumes after its last final, so only a few seconds are replayed |
| Reconnect on ChatGPT | Replays the recording, paced at about 8x real time |
| ChatGPT asks the client to stop (`session.stop_requested`) | Finish normally |
| ChatGPT token expired, missing, or rejected | "Open ChatGPT to sign in". The file is re-read on each retry |
| Deepgram key missing or rejected | "Set Deepgram key" |
| Microphone missing, denied, or changed mid-recording | Cannot be resumed: stop and finish with what was captured |
| Retries exhausted | Keep the text typed so far, show the reason for 3 s, return to idle |

Each recording is its own object. Callbacks from an older connection or recording are ignored.

Private-endpoint risk: the ChatGPT stream is an internal, undocumented interface. SayIt 2
identifies itself with the desktop app's client headers. It can change or stop working with
any ChatGPT update, and it is outside the published API terms. Deepgram is the stable path.

Retention: each ChatGPT stream ended with an `asset.ready` event, so the server may keep the
session audio (uploads in the guide reported a 30 day TTL). Unknown for streams. SayIt 2 itself
stores no audio and no transcripts.

## 10. Indicator and menu bar

Concept A from `docs/mockups.html`: a black pill that drops from under the notch (or the top
edge on other displays) with five white bars that follow your voice.

| State | Pill |
| --- | --- |
| Idle | Not on screen |
| Hold | Bars follow the voice level |
| Hands-free | Same, plus a small square ("tap to stop") |
| Finishing | Bars turn into a slow wave |
| Waiting for the target app | Bars dim and stand still |
| Problem | Red flat bars and a short message for 3 s |

The pill is a borderless, click-through, non-activating panel above all apps and full-screen
spaces. It never takes focus. No sounds anywhere.

Menu bar icon (bars glyph): normal when ready, red while recording, dimmed with a badge when
something is missing (Accessibility, microphone, or the selected provider's credentials).

## 11. Build and run

- `xcrun swift build -c release`, then a short script assembles `SayIt 2.app`
  (`LSUIElement`, microphone usage text) and signs it with the local signing identity taken
  from an environment variable, so Accessibility and Microphone grants survive rebuilds.
- Launch through Finder or `open`, not by running the binary from a terminal.

## 12. Manual verification (no automated tests)

1. Hold Right Option in a text editor, speak English, release: text appears as you speak, once, clipboard unchanged.
2. Same in Persian.
3. Double-tap, speak, pause, speak, tap: one insertion.
4. Short single tap: nothing happens.
5. Right Option plus a letter: the special character types, no dictation.
6. Repeat 1 to 3 on the other provider.
7. Turn Wi-Fi off mid-sentence and back on: recording survives or ends with a clear message; no duplicate text.
8. Switch to another app mid-sentence and come back: typing pauses, then continues in the original app.
9. Remove Accessibility permission: warning icon, nothing typed, no clipboard change.
10. Apps to cover: a native text field, a browser, a terminal, an Electron app.

## 13. Out of scope

Local models, batch transcription, VAD, audio processing, other shortcuts, Escape or Enter
handling, settings screens, history of audio or text, launch at login, automated tests,
telemetry, sounds.
