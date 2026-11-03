import AppKit
import SwiftUI

/// Hosts the first-run welcome window (WelcomeView) in a plain NSWindow, the way Settings is
/// hosted: `sizingOptions = []` makes this controller the ONLY size authority (a second one
/// recursed the layout engine into a stack overflow once, see PinnedPanelController), and the view
/// reports the height of the screen in front, which the window takes at once, top edge held.
@MainActor
final class WelcomeWindowController {
    static let shared = WelcomeWindowController()

    /// The one bit this window stores: it has been shown, so it never opens by itself again.
    private nonisolated static let seenKey = "welcomeWindowShown"

    /// `-TallyWelcomePreview <screen>` and `-TallyWelcomeForce YES`: Dev builds and demo data only,
    /// like every flag in the capture family, so a release launch cannot be talked into either.
    private static var flagsHonoured: Bool { BuildVariant.isDev || DemoUsage.isActive }
    private static var previewName: String? {
        guard previewFlagCarried else { return nil }
        return UserDefaults.standard.string(forKey: CaptureLaunch.welcomePreview)
    }
    private static var previewFlagCarried: Bool {
        flagsHonoured && CaptureLaunch.carries(CaptureLaunch.welcomePreview)
    }
    private static var forced: Bool {
        flagsHonoured && CaptureLaunch.carries(CaptureLaunch.welcomeForce)
    }

    private(set) var window: NSWindow?
    private var reportedHeight: CGFloat = 0
    private let store = WelcomeStore.shared

    var isWindowVisible: Bool { window?.isVisible == true }

    /// Called once per launch, after the other windows had their chance to come back.
    /// `hadLaunchedBefore` is read by the caller BEFORE the login-item default records this launch.
    func showAtLaunchIfNeeded(restoredWindow: Bool, hadLaunchedBefore: Bool, activating: Bool) {
        let seen = UserDefaults.standard.bool(forKey: Self.seenKey)
        let mayRecord = CaptureLaunch.launchMayRecordWindowState
        guard WelcomeFlow.shouldShow(seen: seen, hadLaunchedBefore: hadLaunchedBefore,
                                     restoredWindow: restoredWindow, mayRecordWindowState: mayRecord,
                                     forced: Self.forced, preview: Self.previewFlagCarried) else { return }
        if WelcomeFlow.shouldRecordSeen(forced: Self.forced, preview: Self.previewFlagCarried,
                                        mayRecordWindowState: mayRecord) {
            UserDefaults.standard.set(true, forKey: Self.seenKey)
        }
        show(activating: activating)
    }

    /// The menu's "Welcome": always opens, always from the top (a fresh detection pass).
    func show(activating: Bool = true) {
        StatusItemController.shared?.closePopover()
        if window == nil { makeWindow() }
        store.begin(previewName: Self.previewName)
        if window?.summonShouldFollowPointer == true {
            window?.centerOnPointerScreen()
            window?.clampOnScreen()
        }
        ActivationPolicy.promote()
        if activating {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        } else {
            window?.orderFront(nil)
        }
    }

    private func makeWindow() {
        store.closeWindow = { [weak self] in self?.window?.close() }
        let hosting = NSHostingController(rootView: WelcomeView(
            store: store, onHeight: { [weak self] height in self?.apply(height: height) }))
        hosting.sizingOptions = []
        let window = Self.makeWindow(hosting)
        window.title = String(localized: "Welcome", bundle: AppLocale.bundle)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 560, height: 420))   // until the first report
        ActivationPolicy.track(window)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.store.windowClosed() } }
        self.window = window
    }

    /// Take the screen's height in the same commit as the screen, keeping the top edge where the
    /// user sees it. Never animated: a window growing on a click reads as the page unrolling.
    private func apply(height: CGFloat) {
        guard let window, height.isFinite, height > 1, abs(height - reportedHeight) > 1 else { return }
        reportedHeight = height
        var frame = window.frame
        let chrome = frame.height - window.contentLayoutRect.height
        let target = height + max(0, chrome)
        let top = frame.maxY
        frame.size = NSSize(width: window.frame.width, height: target)
        frame.origin.y = top - target
        window.setFrame(frame, display: true)
    }

    private static func makeWindow(_ hosting: NSViewController) -> NSWindow {
        #if DEBUG
        // A background capture launch never has a key window, which draws the prominent button
        // grey; a Debug capture reports itself key so the shot shows what the user will see.
        if previewFlagCarried || forced { return WelcomeCaptureWindow(contentViewController: hosting) }
        #endif
        return NSWindow(contentViewController: hosting)
    }
}

#if DEBUG
private final class WelcomeCaptureWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    @objc func _hasActiveControls() -> Bool { true }
    @objc func _hasKeyAppearance() -> Bool { true }
    @objc func hasKeyAppearance() -> Bool { true }
}
#endif
