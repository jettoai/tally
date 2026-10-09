import AppKit
import QuartzCore

/// Live measurement of a Settings pane switch (`-TallySettingsTabBench <path.jsonl>`, demo and dev
/// builds only, argument domain so nothing persists). Driven by tests/settingstab-bench.sh.
///
/// Opens the window without taking the foreground, walks all 20 ordered pane pairs, and appends one
/// JSON line per switch, then quits. Per switch, on the window's own display link: how long until
/// the window and the pane on screen stopped changing, ticks that arrived late (a stand-in for main
/// thread stalls, not for what the compositor presented), and ticks on which the pane on screen was
/// cut by the window by more than the display itself forces.
@MainActor
enum SettingsTabBench {
    static let key = "TallySettingsTabBench"
    static let selectNotification = Notification.Name("TallySettingsTabBenchSelect")

    /// Read once: SettingsView asks on every pane change, and the answer cannot change mid-launch.
    static let isActive = (DemoUsage.isActive || BuildVariant.isDev) && CaptureLaunch.carries(key)

    /// The pane on screen and its natural height with its inset, published by SettingsView.
    struct Shown: Equatable {
        var section: String
        var height: CGFloat
    }
    static var shown = Shown(section: "", height: 0)

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
    /// Every ordered pair once, as one walk: for a step k, 0 -> k -> 2k -> ... -> 0 (mod 5) is a
    /// cycle through every pair k apart, and 5 being prime makes the four cycles cover all 20.
    private static let walk: [SettingsView.Section] = {
        let all = SettingsView.Section.allCases
        return (1..<all.count).flatMap { k in (1...all.count).map { all[$0 * k % all.count] } }
    }()
    private static let dwell: TimeInterval = 0.6

    private let output: URL
    private var step = 0
    private var from = SettingsView.Section.accounts
    private var link: CADisplayLink?

    private var start: CFTimeInterval = 0
    private var lastTick: CFTimeInterval = 0
    private var lastChange: CFTimeInterval = 0
    private var lastHeight: CGFloat = 0
    private var lastShown = SettingsTabBench.Shown(section: "", height: 0)
    private var frames = 0, dropped = 0, clipped = 0
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

    func next() {
        guard step < Self.walk.count, let view = window?.contentView else { return finish() }
        if link == nil {
            let link = view.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        let to = Self.walk[step]
        // `lastTick` carries over: the interval the click lands in is part of this switch, and a
        // switch that does its layout on that first frame would otherwise hide it.
        frames = 0; dropped = 0; clipped = 0; maxGap = 0
        start = CACurrentMediaTime()
        lastChange = start
        lastHeight = window?.frame.height ?? 0
        lastShown = SettingsTabBench.shown
        NotificationCenter.default.post(name: SettingsTabBench.selectNotification, object: to.rawValue)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dwell) { [self] in
            record(to: to)
            from = to
            step += 1
            next()
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        // The layout rect, not the content view: with a full-size content view (no title bar strip
        // since B-1355) the view spans the whole frame, so chrome read off it was 0. Same measure as
        // SettingsWindowController.fitHeight.
        guard let window else { return }
        let content = window.contentLayoutRect.height
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
        if abs(window.frame.height - lastHeight) > 0.5 || shown != lastShown {
            lastChange = now
            lastHeight = window.frame.height
            lastShown = shown
        }
        let chrome = window.frame.height - content
        let visible = window.screen?.visibleFrame.height ?? 900
        // Cut by more than the display forces: the most of this pane its window will ever show.
        let reachable = ResizeAnchor.fittedWindowHeight(reported: shown.height, chrome: chrome,
                                                        visibleHeight: visible) - chrome
        if min(shown.height, reachable) > content + 1 { clipped += 1 }
    }

    private func record(to: SettingsView.Section) {
        let line: [String: Any] = [
            "from": from.rawValue, "to": to.rawValue,
            "toPaneHeight": Double(SettingsTabBench.shown.height),
            "contentHeight": Double(window?.contentLayoutRect.height ?? 0),
            "settleMs": Int(((lastChange - start) * 1000).rounded()),
            "frames": frames, "droppedFrames": dropped, "clippedFrames": clipped,
            "maxGapMs": Int((maxGap * 1000).rounded()),
        ]
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
        // Quit only after the last line is on disk.
        queue.async { DispatchQueue.main.async { NSApp.terminate(nil) } }
    }
}
