# SayIt 2

A minimal macOS menu bar dictation app. Hold Right Option and speak: the text is typed live
into the app you are in. No window, no sounds, no clipboard use.

- **Hold** Right Option to dictate, release to finish.
- **Double-tap** Right Option for hands-free, tap once more to finish.
- Pick **ChatGPT** or **Deepgram Nova-3** in the menu bar menu.
- If you switch to another app while it is typing, it waits and continues when you return.

## Build and run

```sh
bash scripts/build-app.sh
open "build/SayIt 2.app"
```

Requires Xcode. On first launch, grant Accessibility (for the hotkey and typing) and
Microphone access.

## Providers

- **ChatGPT** uses the sign-in of the ChatGPT desktop app on this Mac (read-only). If it has
  expired, open the ChatGPT app once. This is a private interface and may stop working.
- **Deepgram** needs an API key: menu, "Set Deepgram API Key…". It is stored in the Keychain.

The chosen provider is kept in `~/.config/sayit2/config`.

See `PLAN.md` for the design, the verified facts behind it, and known limits.
