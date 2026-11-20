# SayIt2

A minimal macOS menu bar dictation app. Hold Right Option and speak: your words appear in a
small pill above the Dock, and when you stop, the text is inserted into the app you were in.
No window, no sounds, no clipboard use.

- **Hold** Right Option to dictate, release to finish.
- **Double-tap** Right Option for hands-free, tap once more to finish.
- Pick **ChatGPT** or **Deepgram Nova-3** in the menu bar menu.
- If focus has left the text field when the text is ready (another app, window, or field),
  it waits and inserts the text when you return to that field.

## Build and run

```sh
bash scripts/build-app.sh              # build and sign
bash scripts/build-app.sh --notarize   # also notarize with Apple
open "build/SayIt2.app"
```

Requires Xcode. On first launch, grant Accessibility (for the hotkey and inserting text) and
Microphone access. The first line of the menu shows the version and build number.

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

See `PLAN.md` for the design, the verified facts behind it, and known limits.
