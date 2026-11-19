import AppKit
import AVFoundation
import ApplicationServices

/// The menu bar item, and the wiring between hotkey, recordings, typing, and the pill.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let hotkey = Hotkey()
    private let typist = Typist()
    private let indicator = Indicator()
    /// Recordings that are still capturing or waiting for their final text. The newest is last.
    private var dictations: [Dictation] = []
    private var trusted = false
    private var checkedOnce = false

    private var recording: Dictation? { dictations.last { $0.isRecording } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        hotkey.recording = { [weak self] in (self?.recording != nil, self?.recording?.handsFree ?? false) }
        hotkey.onStart = { [weak self] handsFree in self?.start(handsFree: handsFree) }
        hotkey.onStop = { [weak self] in self?.recording?.stop() }
        hotkey.onCancel = { [weak self] in self?.recording?.cancel() }
        typist.onChange = { [weak self] in self?.refresh() }
        indicator.onMessageEnd = { [weak self] in self?.refresh() }

        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        // Ask for Accessibility once, then pick up the grant without needing a relaunch.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAccessibility() }
        }
        checkAccessibility()
    }

    private func checkAccessibility() {
        let now = AXIsProcessTrusted()
        if now != trusted || !checkedOnce {
            let microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            log.notice("accessibility \(now, privacy: .public), microphone \(microphone, privacy: .public)")
        }
        if now && !trusted { hotkey.install() }
        trusted = now
        checkedOnce = true
        refresh()
    }

    private func start(handsFree: Bool) {
        guard recording == nil else { return }
        do {
            let dictation = try Dictation(provider: Config.provider, handsFree: handsFree, typist: typist)
            dictation.onLevel = { [weak self] level in self?.indicator.level = level }
            dictation.onStopped = { [weak self] in self?.refresh() }
            dictation.onEnd = { [weak self, weak dictation] problem in
                self?.dictations.removeAll { $0 === dictation }
                log.notice("recording ended: \(problem ?? "ok", privacy: .public)")
                if let problem { self?.indicator.flash(problem) }
                self?.refresh()
            }
            dictations.append(dictation)
            dictation.start()
            log.notice("recording started: \(Config.provider.rawValue, privacy: .public), hands-free \(handsFree, privacy: .public)")
        } catch {
            let message = (error as? Problem)?.message ?? "Could not start"
            log.notice("could not start: \(message, privacy: .public)")
            indicator.flash(message)
        }
        refresh()
    }

    /// Brings the pill and the menu bar icon in line with what is going on.
    private func refresh() {
        if let recording {
            indicator.show(recording.handsFree ? .handsFree : .listening)
        } else if !dictations.isEmpty {
            indicator.show(.finishing)
        } else if typist.isBusy {
            indicator.show(typist.isWaiting ? .waiting : .finishing)
        } else {
            indicator.show(.hidden)
        }
        statusItem.button?.image = Self.icon(recording: recording != nil, attention: attention != nil)
    }

    /// What the user needs to fix before dictation can work, if anything.
    private var attention: String? {
        if !trusted { return "Grant Accessibility Access…" }
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized { return "Allow Microphone Access…" }
        if Config.provider == .deepgram, Credentials.deepgramKey == nil { return "Set Deepgram API Key…" }
        if Config.provider == .chatgpt, (try? Credentials.chatGPT()) == nil { return "Open ChatGPT to sign in" }
        return nil
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Hold or double-tap Right Option", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        for provider in Provider.allCases {
            let item = menu.addItem(withTitle: provider.title, action: #selector(chooseProvider(_:)), keyEquivalent: "")
            item.representedObject = provider.rawValue
            item.state = provider == Config.provider ? .on : .off
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Set Deepgram API Key…", action: #selector(setDeepgramKey), keyEquivalent: "")
        if !trusted {
            menu.addItem(withTitle: "Grant Accessibility Access…", action: #selector(openAccessibility), keyEquivalent: "")
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            menu.addItem(withTitle: "Allow Microphone Access…", action: #selector(openMicrophone), keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit SayIt 2", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
    }

    @objc private func chooseProvider(_ item: NSMenuItem) {
        guard let name = item.representedObject as? String, let provider = Provider(rawValue: name) else { return }
        Config.provider = provider
        refresh()
    }

    @objc private func setDeepgramKey() {
        let alert = NSAlert()
        alert.messageText = "Deepgram API key"
        alert.informativeText = "Stored in your Keychain. Leave empty to remove it."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { Credentials.deepgramKey = field.stringValue }
        refresh()
    }

    @objc private func openAccessibility() { openSettings("Privacy_Accessibility") }
    @objc private func openMicrophone() { openSettings("Privacy_Microphone") }

    private func openSettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    // MARK: Menu bar icon

    /// Four bars: plain when ready, red while recording, dimmed with a badge when something is missing.
    private static func icon(recording: Bool, attention: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 16), flipped: false) { _ in
            let bars: [(x: CGFloat, height: CGFloat)] = [(4, 4), (8, 10), (12, 6), (16, 12)]
            let color = recording ? NSColor(red: 0.9, green: 0.22, blue: 0.17, alpha: 1) : NSColor.black
            color.withAlphaComponent(attention ? 0.45 : 1).setFill()
            for bar in bars {
                NSBezierPath(roundedRect: NSRect(x: bar.x, y: 8 - bar.height / 2, width: 2.2, height: bar.height), xRadius: 1.1, yRadius: 1.1).fill()
            }
            if attention {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 16.5, y: 9, width: 5.5, height: 5.5)).fill()
            }
            return true
        }
        image.isTemplate = !recording   // template images follow the menu bar's light or dark look
        return image
    }
}
