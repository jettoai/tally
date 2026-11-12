import AppKit
import QuartzCore

/// Live measurement of a Settings pane switch (`-TallySettingsTabBench <path.jsonl>`, demo and dev
/// builds only, argument domain so nothing persists). Driven by tests/settingstab-bench.sh.
///
/// Opens the window without taking the foreground and walks every ordered pane pair once (an Euler
/// circuit over the sidebar's panes), appending one JSON line per switch, then a closing `done`
/// line, then quits. The window is a fixed size on every pane, so the question per switch is
/// whether anything moved: the window's size and the right-hand content column's size before the
/// switch, after it, and on every display-link tick in between (`resizedFrames`), whether the new
/// pane opened at its top although the column was left scrolled down (`scrolledFromTop`), the window
/// size on every tick (`samples`), plus how long
/// until the pane on screen stopped changing and how many ticks arrived late (a stand-in for main
/// thread stalls, not for what the compositor presented).
@MainActor
enum SettingsTabBench {
    static let key = "TallySettingsTabBench"
    static let selectNotification = Notification.Name("TallySettingsTabBenchSelect")

    /// Read once: SettingsView asks on every pane change, and the answer cannot change mid-launch.
    static let isActive = (DemoUsage.isActive || BuildVariant.isDev) && CaptureLaunch.carries(key)

    /// The pane on screen and the sidebar's panes in order, published by SettingsView. The walk is
    /// taken from the view so a pane a private build adds is in it without this file knowing.
    struct Shown: Equatable {
        var section: String
        var sections: [String]
    }
    static var shown = Shown(section: "", sections: [])

    private static var run: Run?

    /// Starts the bench if this launch asked for one; stands in for the Settings restore when it does.
    static func startIfRequested() -> Bool {
        guard isActive, let path = UserDefaults.standard.string(forKey: key) else { return false }
        SettingsWindowController.shared.show(activating: false)
        let bench = Run(output: URL(fileURLWithPath: path))
        run = bench
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { bench.next() }
        return true
    }
}

@MainActor
private final class Run: NSObject {
    private static let dwell: TimeInterval = 0.6
    /// A size counts as moved past this, the same half point `ResizeAnchor` calls noise.
    private static let tolerance: CGFloat = 0.5

    private let output: URL
    private var walk: [String]?
    private var step = 0
    private var from = ""
    private var link: CADisplayLink?
    private var column: NSScrollView?

    private var start: CFTimeInterval = 0
    private var lastTick: CFTimeInterval = 0
    private var lastChange: CFTimeInterval = 0
    private var lastShown = SettingsTabBench.Shown(section: "", sections: [])
    private var windowBefore = CGSize.zero, columnBefore = CGSize.zero
    private var frames = 0, dropped = 0, resized = 0
    /// Every tick's window size, `[ms since the switch, width, height]`: the whole sequence rather
    /// than only the verdict, so a reader can see that no sampled frame was any other size.
    private var samples: [[Double]] = []
    private var maxGap: CFTimeInterval = 0

    /// File IO off the main thread: the numbers are taken there, the lines are written here.
    private let queue = DispatchQueue(label: "tally.settings-tab-bench.writer")

    init(output: URL) {
        self.output = output
        queue.async {
            try? Data().write(to: output)
        }
    }

    private var window: NSWindow? { SettingsWindowController.shared.window }

    /// Every ordered pair once, as one walk: an Euler circuit of the complete directed graph over the
    /// panes (Hierholzer), which exists for any count, prime or not. Starts from the pane on screen.
    private static func circuit(over sections: [String], from first: String) -> [String] {
        guard let start = sections.firstIndex(of: first) else { return [] }
        var remaining = sections.indices.map { a in sections.indices.filter { $0 != a } }
        var stack = [start], path: [Int] = []
        while let v = stack.last {
            if let w = remaining[v].popLast() { stack.append(w) } else { path.append(stack.removeLast()) }
        }
        return path.reversed().dropFirst().map { sections[$0] }
    }

    /// The right-hand content column: the largest scroll view in the window (the sidebar has none).
    private func findColumn(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        var best: NSScrollView?
        func area(_ s: NSScrollView) -> CGFloat { s.bounds.width * s.bounds.height }
        func visit(_ v: NSView) {
            if let s = v as? NSScrollView, area(s) > (best.map(area) ?? 0) { best = s }
            v.subviews.forEach(visit)
        }
        visit(view)
        return best
    }

    private var columnSize: CGSize { column.map { $0.convert($0.bounds, to: nil).size } ?? .zero }

    /// How far the column is scrolled from its top, in points (0 = at the top). The document is
    /// flipped, and with a full-size content view the top rests at minus the title bar's inset.
    private var scrolledFromTop: Double {
        guard let column else { return 0 }
        return Double(column.contentView.bounds.minY + column.contentView.contentInsets.top)
    }

    /// Leaves the column at the foot of the pane in front, so a switch that forgets to scroll the
    /// new pane to its top shows up as an offset after it.
    private func scrollColumnToBottom() {
        guard let column, let doc = column.documentView else { return }
        let clip = column.contentView
        clip.scroll(to: NSPoint(x: 0, y: max(0, doc.frame.height - clip.bounds.height)))
        column.reflectScrolledClipView(clip)
    }

    private static func moved(_ a: CGSize, _ b: CGSize) -> Bool {
        abs(a.width - b.width) > tolerance || abs(a.height - b.height) > tolerance
    }

    func next() {
        guard let view = window?.contentView else { return finish() }
        if walk == nil {
            let shown = SettingsTabBench.shown
            walk = Self.circuit(over: shown.sections, from: shown.section)
            from = shown.section
        }
        guard let walk, step < walk.count else { return finish() }
        if link == nil {
            let link = view.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        let to = walk[step]
        column = findColumn(in: view)
        // `lastTick` carries over: the interval the click lands in is part of this switch, and a
        // switch that does its layout on that first frame would otherwise hide it.
        frames = 0; dropped = 0; resized = 0; maxGap = 0; samples = []
        start = CACurrentMediaTime()
        lastChange = start
        lastShown = SettingsTabBench.shown
        scrollColumnToBottom()
        windowBefore = window?.frame.size ?? .zero
        columnBefore = columnSize
        NotificationCenter.default.post(name: SettingsTabBench.selectNotification, object: to)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dwell) { [self] in
            record(to: to)
            from = to
            step += 1
            next()
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let window else { return }
        let now = link.timestamp
        let interval = link.targetTimestamp - link.timestamp
        if lastTick > 0 {
            let gap = now - lastTick
            if gap > 1.5 * interval { dropped += 1 }
            maxGap = max(maxGap, gap)
        }
        lastTick = now
        frames += 1
        let shown = SettingsTabBench.shown
        if shown != lastShown {
            lastChange = now
            lastShown = shown
        }
        if Self.moved(window.frame.size, windowBefore) || Self.moved(columnSize, columnBefore) { resized += 1 }
        samples.append([Double(max(0, Int(((now - start) * 1000).rounded()))),
                        Double(window.frame.width), Double(window.frame.height)])
    }

    private func record(to: String) {
        let after = window?.frame.size ?? .zero
        func pair(_ s: CGSize) -> [Double] { [Double(s.width), Double(s.height)] }
        write([
            "from": from, "to": to,
            "windowBefore": pair(windowBefore), "windowAfter": pair(after),
            "contentBefore": pair(columnBefore), "contentAfter": pair(columnSize),
            "resizedFrames": resized, "scrolledFromTop": scrolledFromTop,
            "settleMs": max(0, Int(((lastChange - start) * 1000).rounded())),   // a tick stamped before `start` reads negative
            "frames": frames, "droppedFrames": dropped,
            "maxGapMs": Int((maxGap * 1000).rounded()),
            "samples": samples,
        ])
    }

    private func write(_ line: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: line, options: .sortedKeys)
        else { return }
        data.append(0x0A)
        queue.async { [output, data] in
            guard let handle = try? FileHandle(forWritingTo: output) else { return }
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    }

    private func finish() {
        link?.invalidate()
        write(["done": true, "switches": step])
        // Quit only after the last line is on disk.
        queue.async { DispatchQueue.main.async { NSApp.terminate(nil) } }
    }
}
