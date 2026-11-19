import AppKit

// `SayIt2 --set-deepgram-key` stores the key read from standard input, without opening the app.
if CommandLine.arguments.contains("--set-deepgram-key") {
    Credentials.deepgramKey = readLine()
    exit(Credentials.deepgramKey == nil ? 1 : 0)
}

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.run()
}
