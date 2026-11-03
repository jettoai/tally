import AppKit
import SwiftUI

/// Hosts the small "Add the tally command" window in a plain NSWindow, the way the welcome window
/// is hosted: `sizingOptions = []` makes this controller the ONLY size authority (a second one
/// recursed the layout engine into a stack overflow once, see PinnedPanelController), and the view
/// reports the height of the screen in front, which the window takes at once, top edge held.
@MainActor
final class TallyCommandWindowController {
    static let shared = TallyCommandWindowController()

    /// `-TallyCommandPreview <screen>`: Dev builds and demo data only, like every flag in the
    /// capture family, so a release launch cannot be talked into it.
    private static var flagsHonoured: Bool { BuildVariant.isDev || DemoUsage.isActive }
    private static var previewFlagCarried: Bool {
        flagsHonoured && CaptureLaunch.carries(CaptureLaunch.commandPreview)
    }
    private static var previewName: String? {
        guard previewFlagCarried else { return nil }
        return UserDefaults.standard.string(forKey: CaptureLaunch.commandPreview)
    }

    private(set) var window: NSWindow?
    private var reportedHeight: CGFloat = 0
    private let store = TallyCommandStore.shared

    /// Called once per launch: a held preview opens its screen by itself, nothing else does.
    func showPreviewIfRequested() {
        guard Self.previewFlagCarried else { return }
        show(activating: CaptureLaunch.launchMayTakeForeground)
    }

    /// The invite card's "Set Up": always opens on the question.
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
        let hosting = NSHostingController(rootView: TallyCommandView(
            store: store, onHeight: { [weak self] height in self?.apply(height: height) }))
        hosting.sizingOptions = []
        let window = Self.makeWindow(hosting)
        window.title = String(localized: "Add the tally command", bundle: AppLocale.bundle)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 480, height: 300))   // until the first report
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
        if previewFlagCarried { return TallyCommandCaptureWindow(contentViewController: hosting) }
        #endif
        return NSWindow(contentViewController: hosting)
    }
}

#if DEBUG
private final class TallyCommandCaptureWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    @objc func _hasActiveControls() -> Bool { true }
    @objc func _hasKeyAppearance() -> Bool { true }
    @objc func hasKeyAppearance() -> Bool { true }
}
#endif
