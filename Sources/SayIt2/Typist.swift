import AppKit
import ApplicationServices

/// Marks key events SayIt2 posts, so its own hotkey listener can ignore them.
let syntheticEventTag: Int64 = 0x5341_5932

/// Inserts each dictation's final text into the text field that had focus when it started.
///
/// A job is created when recording starts, to remember the field, and receives its text once,
/// at the end. Text is sent as Unicode key events, never through the clipboard. While focus is
/// somewhere else, insertion waits for it to come back, however long that takes: text is never
/// thrown away. Dictations into the same app are inserted in order; a dictation waiting for one
/// app does not hold up another app.
@MainActor
final class Typist {
    final class Job {
        fileprivate var app: pid_t
        fileprivate let bundle: String?
        /// The field that had focus when dictation started, if the app exposes one.
        fileprivate var field: AXUIElement?
        /// The text to insert; nil until the dictation has finished.
        fileprivate var text: [Unicode.Scalar]?
        fileprivate var sent = 0

        fileprivate init(app: pid_t, field: AXUIElement?) {
            self.app = app
            self.bundle = NSRunningApplication(processIdentifier: app)?.bundleIdentifier
            self.field = field
        }
    }

    /// Called when insertion starts or stops waiting, and when everything has been inserted.
    var onChange: (() -> Void)?
    /// Focus is somewhere other than the target field, so insertion is paused until it returns.
    private(set) var isWaiting = false
    var isBusy: Bool { !jobs.isEmpty }

    private var jobs: [Job] = []
    private var running = false
    private let source = CGEventSource(stateID: .privateState)

    init() {
        source?.localEventsSuppressionInterval = 0
        // An app that does not answer must not freeze insertion: focus questions give up quickly.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
    }

    /// Starts a job for the field that has keyboard focus right now.
    func begin() -> Job? {
        guard let app = Self.focusedApp() else { return nil }
        let job = Job(app: app, field: Self.element(kAXFocusedUIElementAttribute, of: AXUIElementCreateSystemWide()))
        jobs.append(job)
        run()
        return job
    }

    /// Hands over the job's final text. Empty text ends the job without inserting anything.
    func insert(_ text: String, for job: Job) {
        guard job.text == nil else { return }
        job.text = text.precomposedStringWithCanonicalMapping.unicodeScalars.map {
            $0.properties.generalCategory == .control ? " " : $0
        }
    }

    static func focusedApp() -> pid_t? {
        var app: pid_t = 0
        if let focused = element(kAXFocusedApplicationAttribute, of: AXUIElementCreateSystemWide()),
           AXUIElementGetPid(focused, &app) == .success { return app }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    /// Whether keyboard focus is still in the field this job started in.
    private static func isFocused(_ job: Job) -> Bool {
        guard focusedApp() == job.app else { return false }
        // An app that exposed no field at the start can only be checked as a whole.
        guard let field = job.field else { return true }
        guard let current = element(kAXFocusedUIElementAttribute, of: AXUIElementCreateSystemWide()) else { return false }
        if CFEqual(current, field) { return true }
        // Some apps hand out a new object for the same field, so ask the original whether it has focus.
        var value: CFTypeRef?
        let answer = AXUIElementCopyAttributeValue(field, kAXFocusedAttribute as CFString, &value)
        switch answer {
        case .invalidUIElement:
            // The original field no longer exists; fall back to the app, like after a relaunch.
            job.field = nil
            return true
        case .cannotComplete:
            // The app did not answer in time; wait and try again.
            return false
        case .success:
            if let focused = value as? Bool { return focused }
            fallthrough
        default:
            // The element cannot say whether it has focus; a different window is certainly a different field.
            if let original = element(kAXWindowAttribute, of: field), let now = element(kAXWindowAttribute, of: current) {
                return CFEqual(original, now)
            }
            return true
        }
    }

    private static func element(_ attribute: String, of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func run() {
        guard !running else { return }
        running = true
        Task {
            while !jobs.isEmpty {
                guard let job = nextJob() else {
                    setWaiting(jobs.contains { $0.text != nil })
                    try? await Task.sleep(for: .milliseconds(jobs.contains { $0.text != nil } ? 150 : 15))
                    continue
                }
                setWaiting(false)
                guard let text = job.text, job.sent < text.count else {
                    jobs.removeAll { $0 === job }
                    continue
                }
                let chunk = Self.chunk(text[job.sent...])
                post(chunk.flatMap { Array(String($0).utf16) })
                job.sent += chunk.count
                try? await Task.sleep(for: .milliseconds(2))
            }
            running = false
            isWaiting = false
            onChange?()
        }
    }

    /// The first job that can be inserted now: its text is ready, no earlier job for the same app
    /// is still pending, and its field has focus.
    private func nextJob() -> Job? {
        var blocked: Set<pid_t> = []
        for job in jobs {
            relocate(job)
            guard !blocked.contains(job.app) else { continue }
            blocked.insert(job.app)
            if job.text != nil, job.sent == job.text?.count || Self.isFocused(job) { return job }
        }
        return nil
    }

    /// If the target app quit, waits for it to be opened again and then inserts into whatever
    /// field of it has focus. An app that is still launching would drop the key events.
    private func relocate(_ job: Job) {
        guard NSRunningApplication(processIdentifier: job.app) == nil, let bundle = job.bundle,
              let relaunched = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first,
              relaunched.isFinishedLaunching else { return }
        job.app = relaunched.processIdentifier
        job.field = nil
    }

    private func setWaiting(_ waiting: Bool) {
        guard isWaiting != waiting else { return }
        isWaiting = waiting
        onChange?()
    }

    /// The next scalars to send: as many as fit in 20 UTF-16 units, the safe size for one key event.
    private static func chunk(_ scalars: ArraySlice<Unicode.Scalar>) -> [Unicode.Scalar] {
        var result: [Unicode.Scalar] = []
        var units = 0
        for scalar in scalars {
            units += String(scalar).utf16.count
            if units > 20 { break }
            result.append(scalar)
        }
        return result
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
