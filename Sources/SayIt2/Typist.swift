import AppKit
import ApplicationServices

/// Marks key events SayIt 2 posts, so its own hotkey listener can ignore them.
let syntheticEventTag: Int64 = 0x5341_5932

/// Inserts each dictation's final text into the text field that had focus when it started.
///
/// A job is created when recording starts, to remember the field, and receives its text once,
/// at the end. Text is sent as Unicode key events, never through the clipboard. While focus is
/// somewhere else, insertion waits for it to come back.
@MainActor
final class Typist {
    final class Job {
        let app: pid_t
        /// The field that had focus when dictation started, if the app exposes one.
        fileprivate let field: AXUIElement?
        /// The text to insert; nil until the dictation has finished.
        fileprivate var text: [Unicode.Scalar]?
        fileprivate var sent = 0
        fileprivate var finishedAt = Date()

        fileprivate init(app: pid_t, field: AXUIElement?) {
            self.app = app
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
    /// Text that could not be inserted within this long after its dictation ended is abandoned.
    private let patience: TimeInterval = 120

    init() {
        source?.localEventsSuppressionInterval = 0
        // An app that does not answer must not freeze insertion: focus questions give up quickly.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
    }

    /// Starts a job for the field that has keyboard focus right now.
    /// Text still waiting for a different app is abandoned.
    func begin() -> Job? {
        guard let app = Self.focusedApp() else { return nil }
        jobs.removeAll { $0.app != app }
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
        job.finishedAt = Date()
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
        if answer == .success, let focused = value as? Bool { return focused }
        if answer == .invalidUIElement { return false }   // the original field no longer exists
        // The app cannot say. A different window is certainly a different field.
        if let original = element(kAXWindowAttribute, of: field), let now = element(kAXWindowAttribute, of: current) {
            return CFEqual(original, now)
        }
        return true
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
            while let job = jobs.first {
                guard let text = job.text else {
                    try? await Task.sleep(for: .milliseconds(15))   // still recording
                    continue
                }
                if job.sent == text.count || NSRunningApplication(processIdentifier: job.app) == nil {
                    jobs.removeFirst()   // done, or the target app quit
                    continue
                }
                guard Self.isFocused(job) else {
                    if Date().timeIntervalSince(job.finishedAt) > patience {
                        jobs.removeFirst()   // the user never came back to this field
                        continue
                    }
                    setWaiting(true)
                    try? await Task.sleep(for: .milliseconds(150))
                    continue
                }
                setWaiting(false)
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
