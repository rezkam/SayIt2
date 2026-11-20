import AppKit

/// The black pill just above the Dock while SayIt2 is listening: voice bars and the live words.
@MainActor
final class Indicator {
    enum State: Equatable { case hidden, listening, handsFree, finishing, waiting }

    /// Voice level, 0...1.
    var level: Float = 0
    /// Called when a problem message has finished showing.
    var onMessageEnd: (() -> Void)?

    private let panel: NSPanel
    private let view = PillView()
    private var timer: Timer?
    private var energy: CGFloat = 0
    private var isShown = false

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = view
    }

    func show(_ state: State) {
        guard view.message == nil else { return view.state = state }
        view.state = state
        update()
    }

    /// The live words. Long text wraps; only the newest lines are shown.
    func setText(_ text: String) {
        guard view.text != text else { return }
        view.text = text
        if isShown { update() }
    }

    /// Shows a short problem message for three seconds.
    func flash(_ message: String) {
        view.message = message
        update()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.view.message == message else { return }
            self.view.message = nil
            self.update()
            self.onMessageEnd?()
        }
    }

    private func update() {
        let visible = view.state != .hidden || view.message != nil
        guard visible else { return hide() }
        guard let screen = NSScreen.main else { return }
        // Sit just above the Dock (or the bottom edge when the Dock is hidden or on a side),
        // growing upward as the text wraps.
        let size = view.fittingSize
        let frame = NSRect(x: (screen.frame.midX - size.width / 2).rounded(), y: screen.visibleFrame.minY + 8,
                           width: size.width, height: size.height)
        if isShown {
            panel.setFrame(frame, display: true)
        } else {
            isShown = true
            panel.setFrame(frame.offsetBy(dx: 0, dy: -(size.height + 12)), display: true)   // rise from below
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.19
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = 1
            }
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.animate() }
            }
        }
        view.needsDisplay = true
    }

    private func hide() {
        guard isShown else { return }
        isShown = false
        timer?.invalidate()
        level = 0
        energy = 0
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().setFrame(panel.frame.offsetBy(dx: 0, dy: -(panel.frame.height + 12)), display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isShown else { return }
                self.panel.orderOut(nil)
                self.view.text = ""
            }
        })
    }

    private func animate() {
        energy += (CGFloat(level) - energy) * 0.35
        view.energy = energy
        view.time = CACurrentMediaTime()
        view.needsDisplay = true
    }
}

/// Draws the pill: five voice bars, the live words (or a problem message), and a square while hands-free.
private final class PillView: NSView {
    var state: Indicator.State = .hidden { didSet { if state != oldValue { invalidateText() } } }
    var text = "" { didSet { if text != oldValue { invalidateText() } } }
    var message: String? { didSet { if message != oldValue { invalidateText() } } }
    var energy: CGFloat = 0
    var time: CFTimeInterval = 0

    private let lineHeight: CGFloat = 30, padding: CGFloat = 12, gap: CGFloat = 8, vertical: CGFloat = 7
    private let barWidth: CGFloat = 3, barGap: CGFloat = 2.5, square: CGFloat = 9
    private let maxTextWidth: CGFloat = 420, maxLines = 4
    private let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    /// Vazirmatn, bundled with the app, for Persian; the system font if it could not be loaded.
    private let persianFont: NSFont = {
        let descriptor = NSFontDescriptor(fontAttributes: [.family: "Vazirmatn", .traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.medium]])
        guard let vazirmatn = NSFont(descriptor: descriptor, size: 13), vazirmatn.familyName == "Vazirmatn" else {
            return NSFont.systemFont(ofSize: 13, weight: .medium)
        }
        return vazirmatn
    }()
    private let layoutManager = NSLayoutManager()
    private var layoutDirty = true
    private var cachedText: (text: NSAttributedString, size: NSSize)?
    private var barsWidth: CGFloat { 5 * barWidth + 4 * barGap }

    private func invalidateText() {
        layoutDirty = true
        cachedText = nil
    }

    private func currentText() -> (text: NSAttributedString, size: NSSize)? {
        if layoutDirty {
            layoutDirty = false
            cachedText = computeText()
        }
        return cachedText
    }

    /// The words to draw, wrapped to at most `maxLines` lines, keeping the newest words.
    private func computeText() -> (text: NSAttributedString, size: NSSize)? {
        let raw = message ?? text
        guard !raw.isEmpty else { return nil }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = .natural
        paragraph.baseWritingDirection = .natural   // Persian reads right to left
        let fade = message == nil && (state == .finishing || state == .waiting)
        let persian = raw.suffix(500).unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) || (0xFB50...0xFDFF).contains($0.value) }
        let font = persian ? persianFont : self.font
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .paragraphStyle: paragraph,
            .foregroundColor: NSColor.white.withAlphaComponent(fade ? 0.6 : 1),
        ]
        let limit = CGFloat(maxLines) * layoutManager.defaultLineHeight(for: font) + 1   // the font chosen above
        func measure(_ string: String) -> (text: NSAttributedString, size: NSSize) {
            let attributed = NSAttributedString(string: string, attributes: attributes)
            return (attributed, size(of: attributed))
        }
        let words = raw.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count > 1 else { return measure(raw) }
        var step = 16
        var lastFit: (text: NSAttributedString, size: NSSize)?
        while step < words.count {
            let candidate = measure("… " + words.suffix(step).joined(separator: " "))
            guard candidate.size.height <= limit else { break }
            lastFit = candidate
            step *= 2
        }
        if step >= words.count - 1 {
            let full = measure(raw)
            if full.size.height <= limit { return full }
        }
        var low = step > 16 ? step / 2 + 1 : 1
        var high = min(step, words.count) - 1
        var best = lastFit
        while low <= high {
            let mid = (low + high) / 2
            let candidate = measure("… " + words.suffix(mid).joined(separator: " "))
            if candidate.size.height <= limit {
                best = candidate
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best ?? measure("… " + words.suffix(1).joined(separator: " "))
    }

    private func size(of text: NSAttributedString) -> NSSize {
        let rect = text.boundingRect(with: NSSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading])
        return NSSize(width: ceil(rect.width), height: ceil(rect.height))
    }

    private var showsSquare: Bool { message == nil && state == .handsFree }

    override var fittingSize: NSSize {
        var width = padding * 2 + barsWidth, height = lineHeight
        if let (_, textSize) = currentText() {
            width += gap + textSize.width
            height = max(lineHeight, textSize.height + vertical * 2)
        }
        if showsSquare { width += gap + square }
        return NSSize(width: ceil(width), height: ceil(height))
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = min(bounds.height / 2, lineHeight / 2)
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        NSColor.black.setFill()
        pill.fill()
        NSColor.white.withAlphaComponent(0.22).setStroke()   // keeps the pill visible on dark backgrounds
        pill.lineWidth = 0.5
        pill.stroke()

        let rates: [Double] = [5.1, 7.3, 6.2, 8.4, 5.7], phases: [Double] = [0, 1.3, 2.1, 0.6, 2.9]
        for index in 0..<5 {
            var amount: CGFloat = 0, alpha: CGFloat = 1
            if message != nil {
                amount = 0
            } else if state == .finishing {
                amount = 0.1 + 0.5 * (0.5 + 0.5 * sin(time * 7 - Double(index) * 0.7))
                alpha = 0.75
            } else if state == .waiting {
                amount = 0.2
                alpha = 0.4
            } else {
                amount = 0.15 + 0.85 * abs(sin(time * rates[index] + phases[index])) * energy
            }
            let barHeight = 3 + 12 * amount
            let x = padding + CGFloat(index) * (barWidth + barGap)
            let bar = NSRect(x: x, y: (bounds.height - barHeight) / 2, width: barWidth, height: barHeight)
            (message != nil ? NSColor(red: 1, green: 0.42, blue: 0.34, alpha: 1) : NSColor.white.withAlphaComponent(alpha)).setFill()
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }

        var x = padding + barsWidth + gap
        if let (text, textSize) = currentText() {
            text.draw(with: NSRect(x: x, y: (bounds.height - textSize.height) / 2, width: textSize.width, height: textSize.height),
                      options: [.usesLineFragmentOrigin, .usesFontLeading])
            x += textSize.width + gap
        }
        if showsSquare {
            NSColor.white.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: (bounds.height - square) / 2, width: square, height: square), xRadius: 2.5, yRadius: 2.5).fill()
        }
    }
}
