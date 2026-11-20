import AppKit
import ApplicationServices

/// Marks key events SayIt 2 posts, so its own hotkey listener can ignore them.
let syntheticEventTag: Int64 = 0x5341_5932

/// Types transcripts into the text field that was focused when dictation started.
///
/// Each job remembers exactly what it has typed. One loop makes that equal the newest
/// transcript: type what is missing, or backspace to the common prefix first. Only the
/// newest transcript matters, so updates can never be applied twice or out of order.
///
/// Before each key press it checks that the caret is still right after the job's own text.
/// If the user moved it or edited the field, nothing typed so far is ever deleted again
/// and new text continues at the caret.
@MainActor
final class Typist {
    final class Job {
        let app: pid_t
        /// The field that had focus when dictation started, if the app exposes one.
        fileprivate let field: AXUIElement?
        fileprivate(set) var typed: [Unicode.Scalar] = []
        fileprivate var target: [Unicode.Scalar] = []
        fileprivate var isFinal = false
        fileprivate var finishedAt: Date?
        /// `typed[..<fixed]` can no longer be corrected: the caret left it.
        fileprivate var fixed = 0
        /// Caret position (UTF-16) where `typed[fixed...]` begins, once known.
        fileprivate var base: Int?
        /// How often the caret was not where expected. An app that keeps reporting it wrongly
        /// gets append-only typing, which never deletes anything.
        fileprivate var surprises = 0

        fileprivate init(app: pid_t, field: AXUIElement?) {
            self.app = app
            self.field = field
        }
    }

    /// Called when typing starts or stops waiting, and when everything has been typed.
    var onChange: (() -> Void)?
    /// Focus is somewhere other than the target field, so typing is paused until it returns.
    private(set) var isWaiting = false
    var isBusy: Bool { !jobs.isEmpty }

    private var jobs: [Job] = []
    private var running = false
    private let source = CGEventSource(stateID: .privateState)
    /// Text that could not be delivered within this long after its dictation ended is abandoned.
    private let patience: TimeInterval = 120

    init() {
        source?.localEventsSuppressionInterval = 0
        // An app that does not answer must not freeze typing: focus questions give up quickly.
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

    /// Sets the newest transcript. After `final`, the job accepts no more changes.
    func set(_ text: String, for job: Job, final: Bool = false) {
        guard !job.isFinal else { return }
        job.target = text.precomposedStringWithCanonicalMapping.unicodeScalars.map {
            $0.properties.generalCategory == .control ? " " : $0
        }
        job.isFinal = final
        if final { job.finishedAt = Date() }
    }

    /// Ends a job leaving whatever has been typed so far.
    func keepTyped(_ job: Job) {
        guard !job.isFinal else { return }
        job.target = job.typed
        job.isFinal = true
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
                let common = Self.common(job)
                if job.typed.count == common, common >= job.target.count {
                    if job.isFinal { jobs.removeFirst() } else { try? await Task.sleep(for: .milliseconds(15)) }
                    continue
                }
                if NSRunningApplication(processIdentifier: job.app) == nil {
                    jobs.removeFirst()   // the target app quit
                    continue
                }
                // Wait while focus is elsewhere, or while text is selected (typing would replace it).
                guard Self.isFocused(job), await caretIsReady(job) else {
                    if let finishedAt = job.finishedAt, Date().timeIntervalSince(finishedAt) > patience {
                        jobs.removeFirst()   // the user never came back
                        continue
                    }
                    setWaiting(true)
                    try? await Task.sleep(for: .milliseconds(150))
                    continue
                }
                setWaiting(false)
                let current = Self.common(job)   // the caret check may have fixed more text
                if job.typed.count > current {
                    post(key: 51)   // backspace: one Unicode scalar
                    job.typed.removeLast()
                } else if current < job.target.count {
                    let chunk = Self.chunk(job.target[current...])
                    post(key: 49, text: chunk.flatMap { Array(String($0).utf16) })
                    job.typed.append(contentsOf: chunk)
                }
                try? await Task.sleep(for: .milliseconds(2))
            }
            running = false
            isWaiting = false
            onChange?()
        }
    }

    /// How much of what was typed stays: the part matching the newest transcript, and never less
    /// than the fixed part. Beyond the fixed part the transcript is compared from the same index.
    private static func common(_ job: Job) -> Int {
        let prefix = zip(job.typed, job.target).prefix { $0 == $1 }.count
        if prefix >= job.fixed { return prefix }
        guard job.target.count > job.fixed else { return job.fixed }
        return job.fixed + zip(job.typed[job.fixed...], job.target[job.fixed...]).prefix { $0 == $1 }.count
    }

    /// Checks that the caret sits right after the job's unfixed text. Returns false while text is
    /// selected. If the caret moved, the text typed so far becomes fixed and typing continues there.
    /// Fields that do not report a caret are not checked.
    private func caretIsReady(_ job: Job) async -> Bool {
        guard job.surprises < 3,
              let field = Self.element(kAXFocusedUIElementAttribute, of: AXUIElementCreateSystemWide()),
              var caret = Self.selection(of: field)
        else {
            job.fixed = job.surprises >= 3 ? job.typed.count : job.fixed
            return true
        }
        if caret.length > 0 { return false }
        let pending = String(String.UnicodeScalarView(job.typed[job.fixed...])).utf16.count
        guard let base = job.base, pending > 0 else {
            job.base = caret.location - pending
            return true
        }
        // The app may not have handled the last key press yet, so give it a moment to catch up.
        for _ in 0..<15 where caret.location != base + pending {
            try? await Task.sleep(for: .milliseconds(10))
            guard let again = Self.selection(of: field) else { return true }
            caret = again
        }
        if caret.location != base + pending {
            log.notice("caret moved during dictation; earlier text left as is")
            job.surprises += 1
            job.fixed = job.typed.count
            job.base = caret.location
        }
        return caret.length == 0
    }

    private static func selection(of field: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    private func setWaiting(_ waiting: Bool) {
        guard isWaiting != waiting else { return }
        isWaiting = waiting
        onChange?()
    }

    /// The next scalars to type: as many as fit in 20 UTF-16 units, the safe size for one key event.
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

    /// Posts one key press. Modifier flags are cleared so a held Right Option does not change the meaning.
    private func post(key: CGKeyCode, text: [UniChar] = []) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = []
            if !text.isEmpty { event.keyboardSetUnicodeString(stringLength: text.count, unicodeString: text) }
            event.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
            event.post(tap: .cghidEventTap)
        }
    }
}
