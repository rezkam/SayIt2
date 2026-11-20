import AppKit
import ApplicationServices

/// Marks key events SayIt 2 posts, so its own hotkey listener can ignore them.
let syntheticEventTag: Int64 = 0x5341_5932

/// Types transcripts into the text field that was focused when dictation started.
///
/// Each job remembers exactly what it has typed. One loop makes that equal the newest
/// transcript: type what is missing, or backspace to the common prefix first. Only the
/// newest transcript matters, so updates can never be applied twice or out of order.
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
                if job.typed == job.target {
                    if job.isFinal { jobs.removeFirst() } else { try? await Task.sleep(for: .milliseconds(15)) }
                    continue
                }
                if NSRunningApplication(processIdentifier: job.app) == nil {
                    jobs.removeFirst()   // the target app quit
                    continue
                }
                guard Self.isFocused(job) else {
                    if let finishedAt = job.finishedAt, Date().timeIntervalSince(finishedAt) > patience {
                        jobs.removeFirst()   // the user never came back to this field
                        continue
                    }
                    setWaiting(true)
                    try? await Task.sleep(for: .milliseconds(150))
                    continue
                }
                setWaiting(false)
                let common = zip(job.typed, job.target).prefix { $0 == $1 }.count
                if job.typed.count > common {
                    post(key: 51)   // backspace: one Unicode scalar
                    job.typed.removeLast()
                } else {
                    let chunk = Self.chunk(job.target[common...])
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
