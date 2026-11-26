import AppKit

/// Marks key events SayIt2 posts, so its own hotkey listener can ignore them.
let syntheticEventTag: Int64 = 0x5341_5932

/// Inserts each dictation's final text, in the order the dictations started, into whatever text
/// field has keyboard focus when the text is ready.
///
/// A job is created when recording starts and receives its text once, at the end. Text is sent
/// as Unicode key events, never through the clipboard. It never waits for focus to return to a
/// particular field: the text goes where the user is now.
@MainActor
final class Typist {
    final class Job {
        let bundle: String?
        /// The text to insert; nil until the dictation has finished.
        fileprivate var text: [Unicode.Scalar]?
        fileprivate var sent = 0
        fileprivate var parentSpan: Span?
        fileprivate var insertSpan: Span?

        fileprivate init(app: pid_t, parentSpan: Span?) {
            self.bundle = NSRunningApplication(processIdentifier: app)?.bundleIdentifier
            self.parentSpan = parentSpan
        }
    }

    /// Called when everything has been inserted.
    var onChange: (() -> Void)?
    var isBusy: Bool { !jobs.isEmpty }

    private var jobs: [Job] = []
    private var running = false
    private let source = CGEventSource(stateID: .privateState)

    init() {
        source?.localEventsSuppressionInterval = 0
        // An app that does not answer must not freeze SayIt2: focus questions give up quickly.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
    }

    /// Starts a job for the app that has keyboard focus right now.
    func begin(parentSpan: Span? = nil) -> Job? {
        guard let app = Self.focusedApp() else { return nil }
        let job = Job(app: app, parentSpan: parentSpan)
        jobs.append(job)
        return job
    }

    /// Hands over the job's final text. Empty text ends the job without inserting anything.
    func insert(_ text: String, for job: Job) {
        guard job.text == nil else { return }
        if !text.isEmpty {
            let span = Telemetry.startSpan("sayit2.insert", parent: job.parentSpan)
            span.setAttribute(key: "sayit2.text.characters", value: text.count)
            if let bundle = job.bundle { span.setAttribute(key: "sayit2.target_app.bundle_id", value: bundle) }
            job.insertSpan = span
        }
        job.text = text.precomposedStringWithCanonicalMapping.unicodeScalars.map {
            $0.properties.generalCategory == .control ? " " : $0
        }
        run()
    }

    static func focusedApp() -> pid_t? {
        var value: CFTypeRef?
        var app: pid_t = 0
        if AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID(),
           AXUIElementGetPid(value as! AXUIElement, &app) == .success { return app }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    private func run() {
        guard !running else { return }
        running = true
        Task {
            // Inserts jobs in start order; stops at a job still recording, whose `insert` resumes it.
            while let job = jobs.first, let text = job.text {
                guard job.sent < text.count else {
                    if let span = job.insertSpan {
                        span.status = .ok
                        span.end()
                    }
                    jobs.removeFirst()
                    continue
                }
                // Pack as many scalars as fit in 20 UTF-16 units, the safe size for one key event.
                var units: [UniChar] = []
                while job.sent < text.count {
                    let utf16 = text[job.sent].utf16
                    if units.count + utf16.count > 20 { break }
                    units.append(contentsOf: utf16)
                    job.sent += 1
                }
                post(units)
                try? await Task.sleep(for: .milliseconds(2))
            }
            running = false
            onChange?()
        }
    }

    /// Posts one key press carrying the text. Modifier flags are cleared so a held Right Option
    /// does not change its meaning.
    private func post(_ text: [UniChar]) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: down) else { continue }
            event.flags = []
            event.keyboardSetUnicodeString(stringLength: text.count, unicodeString: text)
            event.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
            event.post(tap: .cghidEventTap)
        }
    }
}
