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
//      a request this build cannot read. The CLI waits a second and a half for the claim and then
//      draws the old form, so a refusal here costs the person nothing but the native look.
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
        guard let id, isPickID(id), current == nil,
              // The same one-answer-per-launch question every other unprompted window asks
              // (LoginItemPreview.mayTakeForeground): a launch that is previewing something must not
              // be interrupted by a panel, and this is that policy rather than a second copy of it.
              LoginItemPreview.launchMayTakeForeground,
              let request = readPickRequest(id: id, dir: dir), !request.rows.isEmpty
        else { return }
        show(request)
        // Claimed only once the panel is really up, which is what the claim is FOR: it says a person
        // is looking at this, so the CLI may stop counting seconds and start waiting.
        try? Data().write(to: pickClaimFile(id: request.id, dir: dir), options: .atomic)
    }

    private func show(_ request: PickRequest) {
        current = request
        previousApp = NSWorkspace.shared.frontmostApplication
        let panel = PickPanel(
            contentRect: .zero,
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.finish(with: .cancelled) }
        let hosting = NSHostingController(rootView: PickPanelView(request: request) { [weak self] row in
            guard let row else {
                self?.finish(with: .cancelled)
                return
            }
            self?.finish(with: PickAnswer(value: row.value, effort: row.effort))
        })
        // ONE SIZE AUTHORITY, and this is the one. The content decides how big the panel is (the
        // list caps its own height and scrolls past it), so nothing here may set a frame or a
        // content size: two authorities recursed the layout engine into a stack overflow on this
        // repo's pinned panel in 2026-07 (~/.claude/docs/patterns/swiftui-appkit.md).
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentViewController = hosting
        // ORIGIN ONLY, which is why it does not fight the line above: the house rule for a window
        // the user summoned is the screen the pointer is on, at the standard dialog height.
        panel.centerOnPointerScreen()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    /// A click outside the panel is a cancellation, the same reading Escape gets: the person went
    /// back to what they were doing, which is the answer.
    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel else { return }
        finish(with: .cancelled)
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
        panel?.orderOut(nil)
        panel = nil
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
        shared.show(request)
    }

    /// The fixture the flag names. Two shapes, because the two lists are shaped differently: an
    /// account row carries three windows and a recommendation, a model row carries a pair.
    static func previewRequest(kind: String) -> PickRequest? {
        switch kind {
        case "account":
            return PickRequest(
                id: "preview", kind: .account,
                message: "Claude ×3 · Move this conversation to another account",
                rows: [
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
        case "model":
            var rows: [PickRow] = []
            for model in ["fable", "opus", "sonnet"] {
                rows.append(PickRow(value: model, label: model))
                for effort in ["high", "xhigh"] {
                    rows.append(PickRow(value: model, effort: effort,
                                        label: "\(model) · \(effort)",
                                        isCurrent: model == "fable" && effort == "high"))
                }
            }
            rows.append(PickRow(value: "auto", label: "auto  (follow this project's profile, then "
                + "the fleet default)"))
            return PickRequest(id: "preview", kind: .model,
                               message: "This session's last response was served by claude-fable-5",
                               rows: rows)
        default:
            return nil
        }
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
