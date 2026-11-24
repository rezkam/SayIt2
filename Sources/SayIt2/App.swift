import AppKit
import AVFoundation

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
    private lazy var dashboard = Dashboard(onConfigChange: { [weak self] in self?.refresh() })
    private var iconTimer: Timer?
    private var iconEnergy: CGFloat = 0
    private var trusted: Bool?

    private var recording: Dictation? { dictations.last { $0.isRecording } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Telemetry.start()
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

    func applicationWillTerminate(_ notification: Notification) {
        Telemetry.flush(wait: true)
    }

    private func checkAccessibility() {
        let now = AXIsProcessTrusted()
        guard now != trusted else { return }
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        Telemetry.event("accessibility \(now), microphone \(microphone)")
        if now { hotkey.install() }
        trusted = now
        refresh()
    }

    private func start(handsFree: Bool) {
        guard recording == nil else { return }
        do {
            let config = Config.load()
            let dictation = try Dictation(config: config, handsFree: handsFree, typist: typist)
            indicator.setText("")
            dictation.onLevel = { [weak self] level in self?.indicator.level = level }
            // The pill shows the newest dictation; an earlier one still finishing must not overwrite it.
            dictation.onText = { [weak self, weak dictation] text in
                guard let self, dictation === self.dictations.last else { return }
                self.indicator.setText(text)
            }
            dictation.onStopped = { [weak self] in self?.refresh() }
            dictation.onEnd = { [weak self, weak dictation] problem in
                self?.dictations.removeAll { $0 === dictation }
                Telemetry.event("recording ended: \(problem ?? "ok")", severity: problem == nil ? .info : .error, span: dictation?.span)
                if let problem { self?.indicator.flash(problem) }
                self?.refresh()
            }
            dictation.onNotice = { [weak self] notice in self?.indicator.flash(notice) }
            dictations.append(dictation)
            Telemetry.event("recording started: \(config.provider.rawValue), hands-free \(handsFree)", span: dictation.span)
            dictation.start()
        } catch {
            let message = (error as? Problem)?.message ?? "Could not start"
            if !(error is Problem) { Telemetry.event("could not start: \(message)", severity: .error) }
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
            statusItem.button?.image = Self.icon()
        }
    }

    /// What the user needs to fix before dictation can work, if anything.
    private var attention: String? {
        if trusted != true { return "Grant Accessibility Access…" }
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized { return "Allow Microphone Access…" }
        let config = Config.load()
        if let hint = config.missingKeyHint { return hint }
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
            menu.addItem(withTitle: "Update to SayIt2 \(available)…", action: #selector(Updates.check), keyEquivalent: "")
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "SayIt2  \(version) (build \(build))", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: attention ?? "Hold or double-tap Right Option", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let config = Config.load()
        for provider in Provider.allCases {
            let item = menu.addItem(withTitle: provider.title, action: #selector(chooseProvider(_:)), keyEquivalent: "")
            item.representedObject = provider
            item.state = provider == config.provider ? .on : .off
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Dashboard…", action: #selector(openDashboard), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(openDashboardSettings), keyEquivalent: ",")
        if trusted != true {
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
        guard let provider = item.representedObject as? Provider else { return }
        if !Config.set("provider", to: provider.rawValue) { indicator.flash("Config file could not be read") }
        refresh()
    }

    @objc private func openDashboard() { dashboard.open(section: "stats") }
    @objc private func openDashboardSettings() { dashboard.open(section: "settings") }

    @objc private func openAccessibility() { openSettings("Privacy_Accessibility") }
    @objc private func openMicrophone() { openSettings("Privacy_Microphone") }

    private func openSettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    // MARK: Menu bar icon

    /// Redraws the menu bar icon while recording, so its bars follow the voice like the pill's.
    private func animateIcon() {
        guard recording != nil else { return refresh() }
        iconEnergy += (CGFloat(indicator.level) - iconEnergy) * 0.4
        let time = CACurrentMediaTime()
        let rates: [Double] = [5.1, 7.3, 6.2, 8.4], phases: [Double] = [0, 1.3, 2.1, 0.6]
        let amounts = (0..<4).map { CGFloat(0.2 + 0.8 * abs(sin(time * rates[$0] + phases[$0]))) * iconEnergy }
        statusItem.button?.image = Self.icon(amounts: amounts)
    }

    /// Monochrome Si² mark at rest; four bars that follow the voice while recording.
    private static func icon(amounts: [CGFloat]? = nil) -> NSImage {
        let image = NSImage(size: NSSize(width: 24, height: 18), flipped: false) { rect in
            if let amounts {
                NSColor.black.setFill()
                for index in 0..<4 {
                    let height = 3 + 11 * amounts[index]
                    let bar = NSRect(x: CGFloat(5 + 4 * index), y: rect.midY - height / 2, width: 2.2, height: height)
                    NSBezierPath(roundedRect: bar, xRadius: 1.1, yRadius: 1.1).fill()
                }
                return true
            }
            let color = NSColor.black
            let baseFont = NSFont.systemFont(ofSize: 13.5, weight: .bold)
            let expFont = NSFont.systemFont(ofSize: 8.5, weight: .bold)
            let base = NSAttributedString(string: "Si", attributes: [.font: baseFont, .foregroundColor: color, .kern: -0.5])
            let exp = NSAttributedString(string: "2", attributes: [.font: expFont, .foregroundColor: color])
            let baseSize = base.size(), expSize = exp.size()
            let totalWidth = baseSize.width + 0.5 + expSize.width
            let x = (rect.width - totalWidth) / 2
            let y = (rect.height - baseSize.height) / 2 - 0.5
            base.draw(at: NSPoint(x: x, y: y))
            exp.draw(at: NSPoint(x: x + baseSize.width + 0.5, y: y + baseSize.height * 0.44))
            return true
        }
        image.isTemplate = true   // drawn in the menu bar's own text color, black on a light menu bar
        return image
    }
}
