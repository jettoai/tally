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
//   4. IT IS CLOSED EXPLICITLY, NEVER BY LOOKING AWAY. Escape, the ✕ on its header and choosing a
//      row are the ways out; losing the key window is not one of them. Somebody who switches away
//      to look something up before answering comes back to the panel they left, instead of to a
//      cancelled pick and a command to retype (Albert, 2026-08-10). What ends a panel nobody comes
//      back to is a deadline rather than a guess about their attention (`pickPanelDeadline`).
@MainActor
final class PickPanelController: NSObject {
    static let shared = PickPanelController()

    private var panel: PickPanel?
    private var current: PickRequest?
    /// The app the person was in when this was raised, so it can have the foreground back.
    private var previousApp: NSRunningApplication?
    /// Whether somebody asked for this panel and is waiting on it. False for a panel raised by a
    /// launch flag for a look, which must never take the foreground it was deliberately launched
    /// without, and which nothing is waiting on (`pickShouldRetryActivation`).
    private var prompted = true
    /// The timer that asks whether the foreground ask landed. Held so a panel that is answered
    /// inside the grace can cancel it.
    private var graceTimer: Timer?
    /// The timer that closes a panel nobody came back to. Held for the same reason, and because a
    /// panel that is answered must not be able to answer twice five minutes later.
    private var deadlineTimer: Timer?

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

    /// HOW LONG THIS LAUNCH HAS BEEN RUNNING, which is what ages a handed-back claim out
    /// (`CaptureLaunch.pickClaimOverrideLifetime`).
    ///
    /// Read off the process rather than stamped at start-up. A `static let` initialised on first
    /// use would start its clock at the first pick request instead, which is the one moment that
    /// makes any build look freshly launched however long it has been sitting in the corner of
    /// somebody's screen: exactly the reading the lifetime exists to refuse.
    ///
    /// A launch date AppKit declines to give reads as long ago, so an unreadable clock retires the
    /// override rather than granting it forever. That failure lands in front of the developer who
    /// asked for the override (their own build stops claiming, while they are driving it) rather
    /// than behind the back of whoever runs a real pick on this machine.
    static func launchAge(now: Date = Date()) -> TimeInterval {
        now.timeIntervalSince(NSRunningApplication.current.launchDate ?? .distantPast)
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
        // The escape hatch ages out with the launch that carried it, which is the same incident one
        // step in: a dev build left running answers picks again the moment somebody switches the
        // stand-down off and then stops thinking about the window (twice on 2026-08-10).
        //
        // The dev preview is untouched by this: it never comes through here at all
        // (`previewIfRequested` shows the panel directly and writes no answer), so a build that may
        // not answer a real request can still be the one a developer is looking at.
        guard pickMayBeClaimed(isUnshipped: BuildVariant.isUnshipped,
                               overridden: CaptureLaunch.carries(CaptureLaunch.pickClaimOverride),
                               overrideAge: Self.launchAge())
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
    private func show(_ request: PickRequest, prompted: Bool = true,
                      circled: [PickKind: Int]? = nil) {
        let activating = CaptureLaunch.mayTakeForeground(
            prompted: prompted, activeKeys: CaptureLaunch.activeKeys())
        current = request
        self.prompted = prompted
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
        // FLOATING AND SURVIVING DEACTIVATION, which is what a panel that outlives its own focus
        // needs to be: an unanswered pick stays in front of whatever the person switched to, so
        // coming back to it is looking at it rather than hunting for it behind a browser window.
        // Both lines are the persistence contract in AppKit's own vocabulary - a normal level would
        // bury it, and hiding on deactivate would take it off the screen the instant they left.
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.onCancel = { [weak self] in self?.finish(with: .cancelled) }
        let hosting = PickHostingView(rootView: PickPanelView(request: request,
                                                              circled: circled) { [weak self] answer in
            // The answer names its axes, which is what tells the CLI whether this submit moved the
            // conversation, changed what answers it, or did both (`pickSubmission`).
            self?.finish(with: answer ?? .cancelled)
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
        // FROM HERE ON THE TOP EDGE IS THE ONE THAT STAYS (`PickPanel.setFrame`). Armed after the
        // placement rather than at construction, because everything before this line is the panel
        // getting its first size at all - held from the zero rect it was created with, it would
        // anchor itself to the bottom of the screen.
        panel.keepsTopEdge = true
        // `orderFront` rather than `makeKeyAndOrderFront` when the foreground is not ours: a panel
        // nobody asked for must not take the keyboard away from whatever the person is typing in.
        if activating {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFront(nil)
        }
        self.panel = panel
        // One look at whether the foreground ask landed, and one clock on a panel nobody answers.
        // Every panel gets the first; only a panel somebody is waiting on gets the second.
        armGrace()
        if prompted { armDeadline() }
    }

    /// The grace has run out: the panel either has the keyboard or the foreground ask did not land,
    /// and this is the one second ask it gets (`pickShouldRetryActivation` carries what is left of
    /// the machine, and why nothing here cancels anything any more).
    ///
    /// Raising this panel from an accessory app means requesting activation, and that request does
    /// not complete on this turn of the loop: the panel is made key here and AppKit may take the key
    /// window straight back while the ask settles. So the state a moment after raising says nothing,
    /// and one grace later is the first honest reading of it.
    private func judgeGrace() {
        guard let panel,
              pickShouldRetryActivation(prompted: prompted, isKey: panel.isKeyWindow)
        else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Look at the panel once, one grace-length from now. Scheduled on the main run loop, which is
    /// where the panel lives.
    ///
    /// ONCE, NOT REPEATEDLY, and that is the whole reason the retry cannot run twice: a second ask
    /// would be an accessory app taking the screen again from somebody who has visibly moved on, and
    /// there is nothing else for a repeat to decide now that focus decides nothing.
    private func armGrace() {
        graceTimer?.invalidate()
        graceTimer = Timer.scheduledTimer(withTimeInterval: pickPanelActivationGrace,
                                          repeats: false) { [weak self] _ in
            Task { @MainActor in self?.judgeGrace() }
        }
    }

    /// Close a panel nobody came back to, just before the CLI stops waiting for it
    /// (`pickPanelDeadline` states why "just before" rather than "with").
    private func armDeadline() {
        deadlineTimer?.invalidate()
        deadlineTimer = Timer.scheduledTimer(withTimeInterval: pickPanelDeadline,
                                             repeats: false) { [weak self] _ in
            Task { @MainActor in self?.expire() }
        }
    }

    /// The deadline: nothing was chosen, AND NOBODY IS HANDED THE FOREGROUND. Every other way out of
    /// this panel is somebody acting on it, so putting them back in the terminal they typed into
    /// finishes what they started. Five minutes of silence is the opposite case: they are somewhere
    /// else entirely, and activating the app they had captured would take the screen from whatever
    /// they moved on to, for a panel they had already forgotten.
    private func expire() {
        previousApp = nil
        guard let request = current else { return }
        // AND NOBODY IS ANSWERED WHO IS NO LONGER THERE. The wait discards the whole request the
        // moment it ends - request, claim, seal and answer together (`discard`, NativePick.swift) -
        // and it can end before this deadline does: a client that closed its stdin, a session that
        // was killed, a machine that slept through the wait and came back past the CLI's own clock.
        // Writing an answer then creates a file under `~/.tally/pick` that no process will read and
        // none will remove either, because the reader that cleans up is precisely the one that has
        // gone. The panel is the last owner of that id.
        //
        // The REQUEST FILE is the liveness signal rather than a guess about it: it is written before
        // the knock and removed by that same discard, so its absence is the wait having ended. The
        // panel still comes down - it is five minutes stale on somebody's screen either way - it
        // just comes down without speaking (`dismiss`).
        guard FileManager.default.fileExists(atPath: pickRequestFile(id: request.id, dir: dir).path)
        else {
            dismiss()
            return
        }
        finish(with: .cancelled)
    }

    /// Answer once, put the foreground back, and forget everything. Idempotent by construction: the
    /// request is cleared first, so a timer that has already been scheduled onto the main loop finds
    /// nothing left to answer and returns.
    private func finish(with answer: PickAnswer) {
        guard let request = current else { return }
        current = nil
        if answersOnDisk, let data = encodePick(answer) {
            try? data.write(to: pickAnswerFile(id: request.id, dir: dir), options: .atomic)
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name(pickAnsweredNotification), object: request.id,
                userInfo: nil, deliverImmediately: true)
        }
        takeDown()
    }

    /// Take the panel down WITHOUT answering, for the one case where there is nobody left to answer
    /// (`expire`). Idempotent through the same field as `finish`, and for the same reason.
    private func dismiss() {
        guard current != nil else { return }
        current = nil
        takeDown()
    }

    /// What both ways out do: stop both clocks, so a panel that is gone cannot answer five minutes
    /// later; take the window off the screen; and hand back whatever foreground was borrowed -
    /// without this last part every pick would leave the person in Tally instead of the terminal
    /// they typed the command into. Shared rather than copied, because a second copy is how one of
    /// the two paths ends up leaving a timer running.
    private func takeDown() {
        graceTimer?.invalidate()
        graceTimer = nil
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        prompted = true
        panel?.orderOut(nil)
        panel = nil
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
        //
        // WITH A ROW ALREADY CIRCLED, if asked for. That is the state the apply bar exists for, and
        // the panel cannot rest in it: the circle starts on the row the session is already on, so
        // nothing is pending until somebody clicks. The alternative to this flag is synthesized
        // clicks on a real desktop, which is what the capture family exists to avoid
        // (`CaptureLaunch.modifierKeys`). Index 1 of the fleet is the account the fixture is NOT on.
        let pending = UserDefaults.standard.bool(forKey: "TallyPickPending")
        shared.show(request, prompted: false, circled: pending ? [.account: 1] : nil)
    }

    /// The fixture the flag names: BOTH sections, in the order the named one opens them.
    ///
    /// Both are built for either flag, because the two commands now raise the same palette and a
    /// preview that showed one section would be a picture of a surface nobody sees. What the flag
    /// decides is which section leads and which way out is pinned, which is the whole difference
    /// between the two commands.
    static func previewRequest(kind: String) -> PickRequest? {
        // The windows read exactly as the CLI writes them, countdowns included (`mcpAccountWindows`):
        // this fixture is what the panel is looked at and captured through, so a shape it cannot
        // produce here is a shape nobody sees until a real fleet is in front of it.
        let accounts = PickSection(kind: .account, rows: [
            PickRow(value: "claude:.claude", label: "Claude",
                    detail: "fable 54% · session 86% (2h14m) · weekly 47% (5d7h)",
                    tags: [switchCurrentSessionTag], isCurrent: true),
            PickRow(value: "claude:.claude2", label: "Claude 2",
                    detail: "fable 91% · session 74% (46m) · weekly 63% (6d23h)",
                    tags: [switchRecommendedTag]),
            PickRow(value: "claude:.claude3", label: "Claude 3",
                    detail: "fable 12% · session 40% (3h1m) · weekly 22% (2d4h)"),
            PickRow(value: "--auto", label: pickAutoLabel),
        ])
        var modelRows: [PickRow] = []
        for model in ["fable", "opus", "sonnet"] {
            modelRows.append(PickRow(value: model, label: model))
            // EVERY DEPTH, because that is what the CLI now expands (`pickerExpandedEfforts`, which
            // is this same list): a fixture drawing two of them is a picture of a panel nobody sees,
            // and the length of the real list is exactly what a capture is looked at for.
            for effort in claudeEffortNames() {
                // …and the resting pair wears the tag the real builder gives it, which is the same
                // word the fleet's own current row wears (`mcpModelPickRows`): the capture is what
                // the two columns are compared on.
                let isCurrent = model == "fable" && effort == "high"
                modelRows.append(PickRow(value: model, effort: effort,
                                         label: "\(model) · \(effort)",
                                         tags: isCurrent ? [switchCurrentSessionTag] : [],
                                         isCurrent: isCurrent))
            }
        }
        modelRows.append(PickRow(value: "auto", label: "auto  (follow this project's profile, then "
            + "the fleet default)"))
        let models = PickSection(kind: .model, rows: modelRows)
        // …AND WHOSE SESSION IT IS, which is drawn at the head of the sentence (`PickProject`). The
        // fixture carries a parallel line as well, because that is the shape a capture is looked at
        // for: the lead is the one part of this panel that is different for every session on the
        // machine, and a preview naming no project would be a picture of the panel nobody gets.
        let project = PickProject(name: "tally", path: "/Users/you/workspace/tally-feat-cart",
                                  worktree: "feat-cart")
        switch kind {
        case "account":
            return PickRequest(
                id: "preview", kind: .account,
                message: "Claude ×3 · Move this conversation to another account",
                rows: accounts.rows, sections: [accounts, models], project: project)
        case "model":
            return PickRequest(id: "preview", kind: .model,
                               message: "This session's last response was served by claude-fable-5",
                               rows: models.rows, sections: [models, accounts], project: project)
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

    /// Whether a change of HEIGHT keeps the top edge where it is. Off until the panel has been
    /// placed, because before that its frame is the zero rect it was created with and there is no
    /// edge worth holding - the placement itself is the first height it ever has (`show`).
    var keepsTopEdge = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// THE TOP EDGE IS WHAT STAYS STILL when the content changes height, so the panel grows
    /// DOWNWARD: the apply bar appears under the columns when a row is circled
    /// (`pickApplyBlockHeight`), and a surface that grew upward would take every row out from under
    /// the pointer that had just circled one. That is the defect the bar's reserved space used to
    /// be avoiding, and it is why the space could stop being reserved.
    ///
    /// WHAT WAS MEASURED, rather than what is assumed (instrumented launch, 2026-08-11): a launch
    /// makes exactly ONE frame write reach this panel, `(1024, 768, 0, 0)` to `(1024, 202, 758,
    /// 566)`, and AppKit's own proposal already held the old top edge (768 = 202 + 566). So this is
    /// a GUARANTEE rather than a correction on that path: the write it produced was identical. The
    /// resize that happens when the bar appears on a panel already on screen could not be observed
    /// without synthesized clicks on a real desktop, which is exactly what is not done here - so the
    /// property is pinned rather than left resting on undocumented behaviour that was checked once.
    ///
    /// THE SIZE AUTHORITY IS UNTOUCHED, which is the red line on this repo's SwiftUI-in-AppKit
    /// surfaces (~/.claude/docs/patterns/swiftui-appkit.md, and the pinned panel's stack overflow
    /// that paid for it): the size in this write is AppKit's, passed through byte for byte. Only the
    /// ORIGIN is rewritten, and only in the one case that has an origin worth correcting.
    ///
    /// A MOVE PASSES STRAIGHT THROUGH, which is what keeps the panel draggable: this surface is
    /// movable by its background, and a frame write that keeps its height is the person dragging it
    /// rather than the content resizing (`ResizeAnchor.changesHeight`).
    override func setFrame(_ frameRect: NSRect, display displays: Bool) {
        guard keepsTopEdge, ResizeAnchor.changesHeight(from: frame.size, to: frameRect.size) else {
            super.setFrame(frameRect, display: displays)
            return
        }
        var held = frameRect
        held.origin = ResizeAnchor.origin(for: frameRect, edges: resizeEdges, corner: .topLeading)
        super.setFrame(held, display: displays)
    }

    /// Escape, at the AppKit level as well as the SwiftUI one: the list handles it while it has
    /// focus, and this catches the case where it does not.
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
