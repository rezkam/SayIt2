# SayIt 2

A minimal macOS menu bar dictation app. Hold Right Option and speak: the text is typed live
into the app you are in. No window, no sounds, no clipboard use.

- **Hold** Right Option to dictate, release to finish.
- **Double-tap** Right Option for hands-free, tap once more to finish.
- Pick **ChatGPT** or **Deepgram Nova-3** in the menu bar menu.
- If you switch to another app while it is typing, it waits and continues when you return.

## Build and run

```sh
bash scripts/build-app.sh              # build and sign
bash scripts/build-app.sh --notarize   # also notarize with Apple
open "build/SayIt 2.app"
```

Requires Xcode. On first launch, grant Accessibility (for the hotkey and typing) and
Microphone access. The first line of the menu shows the version and build number.

## Settings

Everything is in one text file, `~/.config/sayit2/config`. Open it with **Edit Config…** in
the menu. Saved changes apply to the next dictation.

- **ChatGPT** uses the sign-in of the ChatGPT desktop app on this Mac (read-only), so there
  is nothing to set. If it has expired, open the ChatGPT app once. This is a private
  interface and may stop working. Text is typed exactly as ChatGPT returns it.
- **Deepgram** needs `deepgram.api_key`. Every other `deepgram.*` line is passed to Deepgram's
  live streaming API as a parameter (model, language, formatting, key terms and so on); the
  file lists them all with a short explanation.

See `PLAN.md` for the design, the verified facts behind it, and known limits.
