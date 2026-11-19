# SayIt 2: implementation plan

Status: research done, waiting on the decisions in section 2. No app code is written yet.

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

## 2. Decisions needed

My recommendation is listed first for each.

1. **Indicator look.** Pick a concept, detail level, accent, and size in `docs/mockups.html`.
   Recommendation: concept A (drop pill) with voice bars and a live text tail.

2. **Where live text appears.**
   - (a) Live text and corrections show in the indicator. The finished text is inserted
     once when you stop. *Recommended.* This is how ChatGPT's cross-app dictation delivers
     text, it cannot produce duplicates or backspace storms, and it makes every retry safe.
   - (b) Text is typed into the app while you speak, in finalized chunks. More "live", but
     a focus change mid-sentence splits the text, and a reconnect has to be much more careful.

3. **Punctuation on ChatGPT.** Deepgram can simply be asked for plain text. ChatGPT always
   returns punctuation and capitals.
   - (a) Strip punctuation marks from ChatGPT text locally (keep apostrophes, keep capitals).
     *Recommended, given your no-punctuation preference.*
   - (b) Also lowercase everything, to match Deepgram exactly.
   - (c) Leave ChatGPT text as the model wrote it.

4. **ChatGPT credentials.** Read the ChatGPT app's `~/.codex/auth.json` each time, read-only,
   and never refresh the token from SayIt 2. *Recommended.* Refresh tokens rotate, so a second
   client refreshing could sign the ChatGPT app out (Inferred). The cost: if the ChatGPT app
   has not run for 10 days, SayIt 2 shows "open ChatGPT to sign in" and you switch to Deepgram
   until you do. Nothing is copied into Keychain for ChatGPT.

5. **Focus at the end.** Insert into whatever field is focused when dictation finishes
   (ChatGPT's behavior). *Recommended.* The alternative, refusing to insert unless the original
   app is still frontmost, is safer against surprises but drops text when you switch on purpose.

6. **Length limit.** ChatGPT sessions are capped at 5 minutes by its own protocol. Plan:
   auto-finish and insert at 4 min 45 s on ChatGPT, no cap on Deepgram.

## 3. Shape of the app

Native Swift, AppKit only, zero third-party dependencies, no window, no tests.
Target: under about 900 lines.

| File | Job |
| --- | --- |
| `App.swift` | Menu bar item, menu (provider choice, Deepgram key, permission status, quit), wiring |
| `Hotkey.swift` | Right Option gesture: hold, double-tap, tap to stop |
| `Audio.swift` | Microphone tap, one conversion to mono PCM16 at the provider's rate, voice level |
| `Dictation.swift` | One recording from key press to inserted text: buffer, timeouts, retry |
| `ChatGPT.swift` | ChatGPT stream messages |
| `Deepgram.swift` | Deepgram stream messages |
| `Indicator.swift` | The floating indicator |
| `Inserter.swift` | Clipboard-free text insertion |
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

- Press: start recording at once (audio is buffered while the connection opens).
- Release before 100 ms: it was a tap. Cancel, insert nothing, remember the tap.
- Second press within 400 ms of that tap: hands-free mode. Release is ignored.
- Press while hands-free: stop and insert.
- Release after 100 ms in hold mode: stop and insert.
- Any other key pressed while Right Option is held (typing a special character): cancel
  silently, so normal Option shortcuts keep working.

No other key is captured, consumed, or synthesized apart from the inserted text itself.

Limit: macOS does not deliver key events while a password field has secure input, so
dictation cannot start there.

## 7. Text insertion

- Unicode keyboard events, at most 20 UTF-16 units per event, with modifier flags cleared.
  The clipboard is never read or written.
- Wait (briefly, bounded) until no modifier key is physically down before posting.
- Needs Accessibility permission. If it is missing, the indicator says so and the menu
  offers to open the settings pane. Text is never silently dropped onto the clipboard.
- Tradeoff against ChatGPT's method: ChatGPT stages text on the clipboard and triggers Paste,
  which works in nearly every app but touches the clipboard. Key events avoid the clipboard;
  a few apps may handle synthetic Unicode poorly. That is the part that needs your hands-on
  check in the apps you use.

## 8. Credentials

- Deepgram: one Keychain generic-password item owned by SayIt 2. Set through
  "Set Deepgram API Key…" in the menu (a small secure text prompt).
- ChatGPT: see decision 4. The token's expiry is checked locally before connecting so the
  message is clear ("open ChatGPT to sign in") instead of a failed connection.

## 9. Reliability

One rule makes retries safe: text is inserted once, at the end, and until then SayIt 2 keeps
every audio byte the provider has not finalized. A retry opens a new connection, replays that
audio, and replaces the unfinished text. Nothing is typed twice because nothing has been
typed yet.

| Failure | Response |
| --- | --- |
| Connection fails to open (5 s timeout) | Retry up to 2 more times (0.3 s, then 1 s). Recording continues, audio is buffered |
| Stream drops mid-recording | Same retry. Deepgram resumes after its last final; ChatGPT replays the recording (catches up at about 3.5x) |
| No server message for 5 s while audio is flowing | Treated as a drop |
| No final within 8 s after stop | One replay retry; if that fails too, insert the latest live text and show a warning |
| ChatGPT token expired or rejected (401/403) | Re-read the token file once; if still rejected, show "open ChatGPT to sign in". No further retries |
| Provider error message | Show it; retry only if it is a transport error |
| Microphone missing, denied, or changed mid-recording | Cannot be resumed: stop, transcribe what was captured, show the reason |
| All retries exhausted with no text | Show the error for 3 s. Recording state always returns to idle |

Every recording has an id. Late callbacks from an older recording are ignored, so a stale
connection can never write into the next dictation.

Private-endpoint risk: the ChatGPT stream is an internal, undocumented interface. SayIt 2
identifies itself with the desktop app's client headers. It can change or stop working with
any ChatGPT update, and it is outside the published API terms. Deepgram is the stable path.

Retention: each ChatGPT stream ended with an `asset.ready` event, so the server may keep the
session audio (uploads in the guide reported a 30 day TTL). Unknown for streams. SayIt 2 itself
stores no audio and no transcripts.

## 10. Indicator and menu bar

Chosen from `docs/mockups.html`. Whatever the concept, these states exist: idle (nothing on
screen), listening (hold), listening (hands-free), finishing, problem. No sounds.

The indicator is a borderless, click-through, non-activating panel above all apps and
full-screen spaces. It never takes focus.

## 11. Build and run

- `xcrun swift build -c release`, then a short script assembles `SayIt 2.app`
  (`LSUIElement`, microphone usage text) and signs it with the local signing identity taken
  from an environment variable, so Accessibility and Microphone grants survive rebuilds.
- Launch through Finder or `open`, not by running the binary from a terminal.

## 12. Manual verification (no automated tests)

1. Hold Right Option in a text editor, speak English, release: text appears once, clipboard unchanged.
2. Same in Persian.
3. Double-tap, speak, pause, speak, tap: one insertion.
4. Short single tap: nothing happens.
5. Right Option plus a letter: the special character types, no dictation.
6. Repeat 1 to 3 on the other provider.
7. Turn Wi-Fi off mid-sentence and back on: recording survives or ends with a clear message; no duplicate text.
8. Remove Accessibility permission: clear message, no insertion, no clipboard change.
9. Apps to cover: a native text field, a browser, a terminal, an Electron app.

## 13. Out of scope

Local models, batch transcription, VAD, audio processing, other shortcuts, Escape or Enter
handling, settings screens, history of audio or text, launch at login, automated tests,
telemetry, sounds.
