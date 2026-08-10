import AppKit
import SwiftUI

// The panel behind `/tally-account` and `/tally-model`: Tally draws the list, so choosing a row IS
// the answer. What is being replaced, and why it could not be replaced inside the protocol, is the
// design's §1; the wire it answers on is PickContract.swift.
//
// THREE THINGS THIS CONTROLLER OWNS, and each of them is a rule rather than a detail:
//
//   1. CLAIMING. Writing the claim file is what tells the waiting CLI "somebody is looking at this",
//      and NOT writing it is how every fallback works: no app, an app that will not draw right now,
//      a request this build cannot read, a build nobody installed (`pickMayBeClaimed`). The CLI
//      waits a second and a half for the claim and then draws the old form, so a refusal here costs
//      the person nothing but the native look.
//   2. ONE AT A TIME. A second request arriving while a panel is up is not queued and not stacked:
//      it is simply not claimed, so it falls back. Two panels would be two answers competing for one
//      keyboard, and the fallback is a complete surface rather than a degraded one.
//   3. THE FOREGROUND IS BORROWED. The person triggered this from a terminal, so taking focus is
//      right; keeping it is not. Whatever was frontmost is captured before activating and restored
//      when the panel goes, or every pick would throw them out of the window they were typing in.
@MainActor
final class PickPanelController: NSObject, NSWindowDelegate {
    static let shared = PickPanelController()

    private var panel: PickPanel?
    private var current: PickRequest?
    /// The app the person was in when this was raised, so it can have the foreground back.
    private var previousApp: NSRunningApplication?
    /// When the panel went up, which is what separates the activation settling from a person putting
    /// it down (`pickDismissalIsFromPerson`).
    private var shownAt: Date?
    /// A resign that arrived while the ask was still settling. AppKit sends no second one, so this
    /// is the only record that it happened, and the grace's expiry is where it is judged.
    private var sawResignInGrace = false
    /// Whether the foreground has already been asked for a second time (`PickGraceVerdict`).
    private var retriedActivation = false
    /// Whether somebody asked for this panel and is waiting on it. False for a panel raised by a
    /// launch flag for a look, which must never take the foreground it was deliberately launched
    /// without (`pickGraceVerdict`).
    private var prompted = true
    /// The timer that judges the grace. Held so a panel that is answered first can cancel it.
    private var graceTimer: Timer?

    /// Where the request files live. Injected only so a preview can drive the panel from a fixture
    /// without writing into the real directory.
    private var dir: URL = pickRequestDir
    /// Whether an answer should be written and announced at all. False for the dev preview, which is
    /// showing the panel to look at it rather than to answer anything.
    private var answersOnDisk = true

    /// Start listening. Registered once for the process lifetime, exactly as the update check's
    /// observer is (UpdaterController.swift) and for the same reason: there is nothing to tear down
    /// and a missed registration is a feature that silently never fires.
    func install() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(pickRequested(_:)),
            name: Notification.Name(pickRequestedNotification), object: nil)
    }

    /// The knock. The notification carries the id and nothing else; the request is read off disk,
    /// because a distributed notification is a machine-wide bus and its delivery is not guaranteed
    /// either way (PickContract.swift).
    @objc nonisolated private func pickRequested(_ note: Notification) {
        let id = note.object as? String
        Task { @MainActor in self.present(id: id) }
    }

    private func present(id: String?) {
        // STAND DOWN IF THIS IS NOT THE INSTALLED APP, before anything else is even looked at. The
        // knock is machine-wide, so every Tally running here hears it, and the exclusive claim below
        // only guarantees that ONE of them wins: a build left running from yesterday is the likelier
        // winner precisely because it does less before it claims. On 2026-08-09 one was, and it was
        // built before the panel's self-cancelling defect was fixed, so every pick on that machine
        // died in 147ms with an installed 0.42.0 sitting right beside it (`pickMayBeClaimed` carries
        // the trace, the escape hatch, and what standing down costs a DMG launch).
        //
        // The dev preview is untouched by this: it never comes through here at all
        // (`previewIfRequested` shows the panel directly and writes no answer), so a build that may
        // not answer a real request can still be the one a developer is looking at.
        guard pickMayBeClaimed(isUnshipped: BuildVariant.isUnshipped,
                               overridden: CaptureLaunch.carries(CaptureLaunch.pickClaimOverride))
        else { return }
        guard let id, isPickID(id), current == nil,
              // The same one-answer-per-launch question every other unprompted window asks
              // (CaptureLaunch.mayTakeForeground): a launch that is there to be looked at must not
              // be interrupted by a panel, and this is that policy rather than a second copy of it.
              // Widened with the rest of the family: it used to ask only about the login-item state
              // preview, so a demo capture or a panel snapshot could still be walked over.
              CaptureLaunch.launchMayTakeForeground,
              let request = readPickRequest(id: id, dir: dir), !request.everyRow.isEmpty
        else { return }
        // CLAIMED FIRST, and exclusively. The knock reaches every listener on the machine, so a
        // release build and a dev build running side by side both get here with nothing drawn yet;
        // whoever loses the file system's race draws nothing and leaves quietly, rather than putting
        // a second panel on screen for a question that can only be answered once (`takePickClaim`).
        guard takePickClaim(id: request.id, dir: dir) else { return }
        show(request)
    }

    /// `prompted` = somebody asked for this panel just now and is waiting on it, which is what
    /// point 3 in the file header is about. True for the picker a CLI is blocked on; false for the
    /// same panel raised by a launch flag for a look, where taking the foreground would walk over
    /// whoever is using the machine. Both answers come from one place (CaptureLaunch), so neither
    /// path can quietly grow its own policy.
    private func show(_ request: PickRequest, prompted: Bool = true) {
        let activating = CaptureLaunch.mayTakeForeground(
            prompted: prompted, activeKeys: CaptureLaunch.activeKeys())
        current = request
        self.prompted = prompted
        shownAt = Date()
        // Captured only when the foreground is actually being borrowed. Nothing was taken on a
        // background preview, so there is nothing to hand back, and handing it back anyway would
        // activate whatever the person had moved on to.
        previousApp = activating ? NSWorkspace.shared.frontmostApplication : nil
        // BORDERLESS, LIKE THE PINNED PANEL, which is the surface this one is now a sibling of: the
        // content draws its own backdrop and its own 12pt corner (`PanelBackdrop`, PickPanelView),
        // so nothing is inherited from a window frame. The titled panel this replaced kept a
        // titlebar for its rounded chrome and spent 32 points on it while drawing nothing there,
        // which is the empty band at the top of the panel Albert kept seeing.
        //
        // NOT `.nonactivatingPanel`, which the pinned panel does use and this one must not: that
        // style asks AppKit to keep the panel out of the key window chain, and the whole point here
        // is that the keyboard can answer it (arrow keys and Enter).
        let panel = PickPanel(contentRect: .zero, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Movable by its background, unlike the pinned panel: there are no cards to reorder here, so
        // AppKit's own window drag can have the whole surface and the rows keep their clicks.
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.finish(with: .cancelled) }
        let hosting = PickHostingView(rootView: PickPanelView(request: request) { [weak self] choice in
            // The choice carries the section it came from, which is what tells the CLI whether this
            // click moved the conversation or changed what answers it (`PickChoice.answer`).
            self?.finish(with: choice?.answer ?? .cancelled)
        })
        // ONE SIZE AUTHORITY, and this is the one. The content decides how big the panel is (the
        // list caps its own height and scrolls past it), so nothing here may set a frame or a
        // content size: two authorities recursed the layout engine into a stack overflow on this
        // repo's pinned panel in 2026-07 (~/.claude/docs/patterns/swiftui-appkit.md).
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        // ORIGIN ONLY, which is why it does not fight the line above: the house rule for a window
        // the user summoned is the screen the pointer is on, at the standard dialog height.
        panel.centerOnPointerScreen()
        // `orderFront` rather than `makeKeyAndOrderFront` when the foreground is not ours: taking
        // key would also arm `windowDidResignKey`, and the first click anywhere else would read as
        // the person cancelling a question nobody asked them.
        if activating {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFront(nil)
        }
        self.panel = panel
        // The grace is a deadline of its own, not just a filter: something has to come back and look
        // at a panel whose resign was swallowed.
        armGrace()
    }

    /// A click outside the panel is a cancellation, the same reading Escape gets: the person went
    /// back to what they were doing, which is the answer.
    ///
    /// EXCEPT WHILE THE FOREGROUND ASK IS STILL SETTLING. Raising this panel from an accessory app
    /// means requesting activation, and that request does not complete on this turn of the loop: the
    /// panel is made key here, the request settles afterwards, and AppKit takes the key window back
    /// in between. Read as a dismissal, that answered every pick the instant it was asked - which is
    /// exactly what shipped in 0.41.0 (`pickPanelActivationGrace` carries the trace). The judgement
    /// itself is pure and lives with the contract, where it can be asserted without an app.
    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel else { return }
        guard pickDismissalIsFromPerson(shownAt: shownAt) else {
            // REMEMBERED RATHER THAN DROPPED. A person really can click away inside the grace, and
            // AppKit will not tell us twice: the window is already not key, so no second resign is
            // coming. Dropping it outright left the panel on screen and the CLI waiting out its
            // five-minute deadline (review of the first fix).
            sawResignInGrace = true
            return
        }
        finish(with: .cancelled)
    }

    /// The grace has run out: judge what the panel is doing, and make sure something is still
    /// watching it unless it has genuinely settled (`PickGraceVerdict` carries the full machine).
    private func judgeGrace() {
        guard let panel else { return }
        switch pickGraceVerdict(prompted: prompted, sawResign: sawResignInGrace,
                                isKey: panel.isKeyWindow,
                                appIsActive: NSApp.isActive,
                                alreadyRetried: retriedActivation) {
        case .settled:
            return   // it holds the key window: an ordinary resign answers from here on
        case .keepWatching:
            armGrace()
        case .retryActivation:
            retriedActivation = true
            // A FRESH GRACE FOR THE SECOND ASK. `NSApp.activate` resigns asynchronously exactly as
            // the first one did, and judging that against the ORIGINAL `shownAt` made the very first
            // defect reappear on this path: the retry's own settling read as past the grace and
            // cancelled instantly. The observation window is reset with it, so a resign from before
            // the retry cannot be counted against it either.
            shownAt = Date()
            sawResignInGrace = false
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            armGrace()
        case .dismissed, .abandoned:
            // Both end the same way and for the same reason: nobody is going to answer this panel,
            // and leaving it up holds a claimed request until the CLI's deadline. `finish` hands the
            // foreground back on the way out.
            finish(with: .cancelled)
        }
    }

    /// Judge the grace one grace-length from now. Scheduled on the main run loop, which is where the
    /// panel lives.
    private func armGrace() {
        graceTimer?.invalidate()
        graceTimer = Timer.scheduledTimer(withTimeInterval: pickPanelActivationGrace,
                                          repeats: false) { [weak self] _ in
            Task { @MainActor in self?.judgeGrace() }
        }
    }

    /// Answer once, put the foreground back, and forget everything. Idempotent by construction: the
    /// request is cleared first, so the resign-key that follows an ordered-out panel finds nothing
    /// left to answer and returns.
    private func finish(with answer: PickAnswer) {
        guard let request = current else { return }
        current = nil
        if answersOnDisk, let data = encodePick(answer) {
            try? data.write(to: pickAnswerFile(id: request.id, dir: dir), options: .atomic)
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name(pickAnsweredNotification), object: request.id,
                userInfo: nil, deliverImmediately: true)
        }
        panel?.delegate = nil
        graceTimer?.invalidate()
        graceTimer = nil
        sawResignInGrace = false
        retriedActivation = false
        prompted = true
        panel?.orderOut(nil)
        panel = nil
        shownAt = nil
        // Handed back to whoever had it. Without this, every pick would leave the person in Tally
        // instead of the terminal they typed the command into.
        previousApp?.activate()
        previousApp = nil
    }

    // MARK: - Dev preview

    /// Raise the panel on a fixture, so it can be looked at without an MCP client, a session, or a
    /// request on disk. The launch-flag family this belongs to is LoginItemPreview's: read through
    /// `UserDefaults` (launch arguments land there on their own) and reachable only in a dev or demo
    /// build.
    static func previewIfRequested() {
        guard LoginItemPreview.previewable(isDemo: DemoUsage.isActive, isDev: BuildVariant.isDev),
              let kind = UserDefaults.standard.string(forKey: "TallyPickPreview"),
              let request = previewRequest(kind: kind) else { return }
        shared.answersOnDisk = false
        // Nobody asked for this one: it is a launch flag putting the panel up to be looked at.
        shared.show(request, prompted: false)
    }

    /// The fixture the flag names: BOTH sections, in the order the named one opens them.
    ///
    /// Both are built for either flag, because the two commands now raise the same palette and a
    /// preview that showed one section would be a picture of a surface nobody sees. What the flag
    /// decides is which section leads and which way out is pinned, which is the whole difference
    /// between the two commands.
    static func previewRequest(kind: String) -> PickRequest? {
        let accounts = PickSection(kind: .account, rows: [
            PickRow(value: "claude:.claude", label: "Claude",
                    detail: "fable 54% · session 86% · weekly 47%",
                    tags: [switchCurrentSessionTag], isCurrent: true),
            PickRow(value: "claude:.claude2", label: "Claude 2",
                    detail: "fable 91% · session 74% · weekly 63%",
                    tags: [switchRecommendedTag]),
            PickRow(value: "claude:.claude3", label: "Claude 3",
                    detail: "fable 12% · session 40% · weekly 22%"),
            PickRow(value: "--auto", label: pickAutoLabel),
        ])
        var modelRows: [PickRow] = []
        for model in ["fable", "opus", "sonnet"] {
            modelRows.append(PickRow(value: model, label: model))
            for effort in ["high", "xhigh"] {
                modelRows.append(PickRow(value: model, effort: effort,
                                         label: "\(model) · \(effort)",
                                         isCurrent: model == "fable" && effort == "high"))
            }
        }
        modelRows.append(PickRow(value: "auto", label: "auto  (follow this project's profile, then "
            + "the fleet default)"))
        let models = PickSection(kind: .model, rows: modelRows)
        switch kind {
        case "account":
            return PickRequest(
                id: "preview", kind: .account,
                message: "Claude ×3 · Move this conversation to another account",
                rows: accounts.rows, sections: [accounts, models])
        case "model":
            return PickRequest(id: "preview", kind: .model,
                               message: "This session's last response was served by claude-fable-5",
                               rows: models.rows, sections: [models, accounts])
        default:
            return nil
        }
    }
}

/// The panel's content, answering the FIRST click rather than spending it on focus.
///
/// The same fix the pinned panel already carries, one surface over (`MeasuredHostingView` in
/// SurfaceSizer.swift, passed `acceptsFirstMouse: true` by PinnedPanelController): a floating panel
/// belonging to an app that is not active gets its first click taken by activation, so the panel
/// could not be dragged until it had been clicked once to wake it. Both halves are needed and the
/// second is the one that is easy to miss: SwiftUI only tracks a gesture in the KEY window, so the
/// window is made key synchronously as the press lands before the event is routed on.
///
/// A hosting VIEW rather than a controller for the same reason that one is: `NSHostingController`
/// makes its own hosting view and there is nowhere to put these two overrides. The size authority is
/// unchanged and still single - `sizingOptions` on this view, no frame written by anybody - and the
/// panel's measured height is what proves it (tests/supervisor/pickheightchecks, and the window
/// bounds recorded with it).
private final class PickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if let window, !window.isKeyWindow { window.makeKey() }
        super.mouseDown(with: event)
    }
}

/// The panel itself. Key, because the whole point is that the keyboard can answer it; never main,
/// like every other panel here.
final class PickPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Escape, at the AppKit level as well as the SwiftUI one: the list handles it while it has
    /// focus, and this catches the case where it does not.
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
