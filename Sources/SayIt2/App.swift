import AppKit
import AVFoundation
import ApplicationServices

/// The menu bar item, and the wiring between hotkey, recordings, text insertion, and the pill.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let hotkey = Hotkey()
    private let typist = Typist()
    private let indicator = Indicator()
    /// Recordings that are still capturing or waiting for their final text. The newest is last.
    private var dictations: [Dictation] = []
    private let updates = Updates()
    private var iconTimer: Timer?
    private var iconEnergy: CGFloat = 0
    private var trusted = false
    private var checkedOnce = false

    private var recording: Dictation? { dictations.last { $0.isRecording } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Vazirmatn (SIL Open Font License) draws Persian words in the pill.
        if let font = Bundle.main.url(forResource: "Vazirmatn", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        hotkey.recording = { [weak self] in (self?.recording != nil, self?.recording?.handsFree ?? false) }
        hotkey.onStart = { [weak self] handsFree in self?.start(handsFree: handsFree) }
        hotkey.onStop = { [weak self] in self?.recording?.stop() }
        hotkey.onCancel = { [weak self] in self?.recording?.cancel() }
        typist.onChange = { [weak self] in self?.refresh() }
        indicator.onMessageEnd = { [weak self] in self?.refresh() }
        updates.onChange = { [weak self] in self?.refresh() }
        updates.start()

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
        guard now != trusted || !checkedOnce else { return }
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        log.notice("accessibility \(now, privacy: .public), microphone \(microphone, privacy: .public)")
        if now { hotkey.install() }
        trusted = now
        checkedOnce = true
        refresh()
    }

    private func start(handsFree: Bool) {
        guard recording == nil else { return }
        do {
            let config = Config.load()
            let dictation = try Dictation(config: config, handsFree: handsFree, typist: typist)
            indicator.setText("")
            dictation.onLevel = { [weak self] level in self?.indicator.level = level }
            dictation.onText = { [weak self] text in self?.indicator.setText(text) }
            dictation.onStopped = { [weak self] in self?.refresh() }
            dictation.onEnd = { [weak self, weak dictation] problem in
                self?.dictations.removeAll { $0 === dictation }
                log.notice("recording ended: \(problem ?? "ok", privacy: .public)")
                if let problem { self?.indicator.flash(problem) }
                self?.refresh()
            }
            dictations.append(dictation)
            dictation.start()
            log.notice("recording started: \(config.provider.rawValue, privacy: .public), hands-free \(handsFree, privacy: .public)")
            if let notice = dictation.notice { indicator.flash(notice) }
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
        if recording != nil {
            if iconTimer == nil {
                iconTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.animateIcon() }
                }
            }
        } else {
            iconTimer?.invalidate()
            iconTimer = nil
            iconEnergy = 0
            statusItem.button?.image = Self.icon(attention: attention != nil)
        }
    }

    /// What the user needs to fix before dictation can work, if anything.
    private var attention: String? {
        if !trusted { return "Grant Accessibility Access…" }
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized { return "Allow Microphone Access…" }
        let config = Config.load()
        if config.provider == .deepgram, config.deepgramKey == nil { return "Add the Deepgram key in the config" }
        if config.provider == .chatgpt, !Credentials.hasChatGPTLogin { return "Sign in to ChatGPT (ChatGPT app or codex)" }
        return nil
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?", build = info?["CFBundleVersion"] as? String ?? "?"
        if let available = updates.available {
            menu.addItem(withTitle: "Update to SayIt2 \(available)…", action: #selector(Updates.check), keyEquivalent: "").target = updates
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "SayIt2  \(version) (build \(build))", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: attention ?? "Hold or double-tap Right Option", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let config = Config.load()
        for provider in Provider.allCases {
            let item = menu.addItem(withTitle: provider.title, action: #selector(chooseProvider(_:)), keyEquivalent: "")
            item.representedObject = provider.rawValue
            item.state = provider == config.provider ? .on : .off
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Microphone"))
        let systemDefault = menu.addItem(withTitle: "System Default", action: #selector(chooseMicrophone(_:)), keyEquivalent: "")
        systemDefault.representedObject = ""
        systemDefault.state = config.microphone == nil ? .on : .off
        if let name = Microphone.systemDefault()?.name {
            if #available(macOS 14.4, *) { systemDefault.subtitle = "Now: \(name)" } else { systemDefault.title = "System Default (\(name))" }
        }
        let microphones = Microphone.all().map(\.name)
        for name in microphones {
            let item = menu.addItem(withTitle: name, action: #selector(chooseMicrophone(_:)), keyEquivalent: "")
            item.representedObject = name
            item.state = name == config.microphone ? .on : .off
        }
        if let chosen = config.microphone, !microphones.contains(chosen) {
            menu.addItem(withTitle: "\(chosen) (not connected)", action: nil, keyEquivalent: "").state = .on
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Edit Config…", action: #selector(editConfig), keyEquivalent: ",")
        if !trusted {
            menu.addItem(withTitle: "Grant Accessibility Access…", action: #selector(openAccessibility), keyEquivalent: "")
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            menu.addItem(withTitle: "Allow Microphone Access…", action: #selector(openMicrophone), keyEquivalent: "")
        }
        if updates.isEnabled {
            menu.addItem(withTitle: "Check for Updates…", action: #selector(Updates.check), keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit SayIt2", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.target == nil && item.action != #selector(NSApplication.terminate(_:)) {
            item.target = item.action == #selector(Updates.check) ? updates : self
        }
    }

    @objc private func chooseProvider(_ item: NSMenuItem) {
        guard let name = item.representedObject as? String, let provider = Provider(rawValue: name) else { return }
        if !Config.set("provider", to: provider.rawValue) { indicator.flash("Config file could not be read") }
        refresh()
    }

    @objc private func chooseMicrophone(_ item: NSMenuItem) {
        guard let name = item.representedObject as? String else { return }
        if !Config.set("microphone", to: name) { indicator.flash("Config file could not be read") }
    }

    /// Opens the settings file in the default text editor.
    @objc private func editConfig() {
        _ = Config.load()   // creates the file with every option listed, if it is missing
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-t", Config.file.path]
        try? open.run()
    }

    @objc private func openAccessibility() { openSettings("Privacy_Accessibility") }
    @objc private func openMicrophone() { openSettings("Privacy_Microphone") }

    private func openSettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    // MARK: Menu bar icon

    /// Redraws the menu bar icon while recording, so its bars follow the voice like the pill's.
    private func animateIcon() {
        guard recording != nil else {
            iconTimer?.invalidate()
            iconTimer = nil
            iconEnergy = 0
            return
        }
        iconEnergy += (CGFloat(indicator.level) - iconEnergy) * 0.4
        let time = CACurrentMediaTime()
        let rates: [Double] = [5.1, 7.3, 6.2, 8.4], phases: [Double] = [0, 1.3, 2.1, 0.6]
        let amounts = (0..<4).map { CGFloat(0.2 + 0.8 * abs(sin(time * rates[$0] + phases[$0]))) * iconEnergy }
        statusItem.button?.image = Self.icon(amounts: amounts)
    }

    /// Four black bars. At rest they have fixed heights; while recording `amounts` (0...1) sets them.
    /// Dimmed with a badge when something is missing.
    private static func icon(amounts: [CGFloat]? = nil, attention: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 16), flipped: false) { _ in
            let rest: [CGFloat] = [4, 10, 6, 12]
            NSColor.black.withAlphaComponent(attention ? 0.45 : 1).setFill()
            for index in 0..<4 {
                let height = amounts.map { 3 + 11 * $0[index] } ?? rest[index]
                let bar = NSRect(x: CGFloat(4 + 4 * index), y: 8 - height / 2, width: 2.2, height: height)
                NSBezierPath(roundedRect: bar, xRadius: 1.1, yRadius: 1.1).fill()
            }
            if attention {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 16.5, y: 9, width: 5.5, height: 5.5)).fill()
            }
            return true
        }
        image.isTemplate = true   // drawn in the menu bar's own text color, black on a light menu bar
        return image
    }
}
