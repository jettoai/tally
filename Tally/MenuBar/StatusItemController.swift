import AppKit
import SwiftUI

/// Owns the `NSStatusItem` and its popover.
///
/// Uses raw `NSStatusItem` rather than SwiftUI `MenuBarExtra`: MenuBarExtra's label does not redraw
/// on `@Observable` changes (Apple FB13683957), so the at-a-glance percentage wouldn't update.
/// The button title is refreshed imperatively via `UsageStore.onChange`.
///
/// Left-click toggles the popover; right/control-click drops a small menu (Settings / Quit).
@MainActor
final class StatusItemController: NSObject {
    static private(set) weak var shared: StatusItemController?

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var popoverHost: NSHostingController<PopoverRootView>?
    /// The popover's own Usage / Tokens selection, kept here so the pin hand-off can read it.
    private let popoverTab = SurfaceTabState()

    private static let symbolCandidates = ["gauge.medium", "gauge", "chart.bar.fill"]

    /// Whether the transient popover is on screen. Read by the updater before it restarts the app
    /// into a new version: the popover is a surface the user opened to read something, and taking
    /// it away mid-read is the interruption the idle bar exists to avoid.
    var isPopoverShown: Bool { popover.isShown }

    func install() {
        Self.shared = self
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(handleClick)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.imagePosition = .imageLeading
        statusItem = item

        popover.behavior = .transient
        // Show instantly instead of playing NSPopover's expand/scale animation - that animation (not
        // the content) is the "laggy on expand" feel; other menu-bar apps just appear.
        popover.animates = false
        // `sizingOptions = []` (not `.preferredContentSize`, not the default `.standardBounds`) so the
        // host installs NO Auto Layout constraints - we set the popover's contentSize manually via
        // `sizeThatFits`. Two size authorities (SwiftUI constraints + manual sizing) recurse the layout
        // engine into a stack-overflow crash.
        let host = NSHostingController(
            rootView: PopoverRootView(store: UsageStore.shared, settings: SettingsStore.shared,
                                      onContentSize: { [weak self] size in self?.applyPopoverSize(size) },
                                      // The popover hangs off the status item, so it has to fit the
                                      // screen the menu bar is on, whichever display that is today.
                                      hostScreen: { [weak self] in self?.statusItem?.button?.window?.screen },
                                      tabState: popoverTab))
        host.sizingOptions = []
        popoverHost = host
        popover.contentViewController = host

        UsageStore.shared.onChange = { [weak self] in self?.updateButton() }
        updateButton()

        // Restore the pinned floating panel if it was pinned when the app last quit.
        if SettingsStore.shared.isUsagePanelPinned {
            PinnedPanelController.shared.show(atTopLeft: nil)
        }
    }

    private func updateButton() {
        guard let button = statusItem?.button else { return }
        let segments = UsageStore.shared.menuBarSegments
        button.attributedTitle = NSAttributedString(string: "")
        if segments.isEmpty {
            // No visible accounts - fall back to the app glyph.
            button.image = Self.symbolImage()
            button.toolTip = nil
        } else {
            // The whole strip is rendered as one template image (brand marks + stacked numbers).
            // Hover / VoiceOver carry the full per-account identity the compact strip can't.
            let tooltip = UsageStore.shared.menuBarTooltip
            button.image = MenuBarStripRenderer.stripImage(segments)
            button.image?.accessibilityDescription = tooltip
            button.toolTip = tooltip
            // README screenshot hook: demo mode + -TallyStripSnapshot <path> writes the strip
            // as a standalone PNG (idempotent - demo data never changes between refreshes).
            if DemoUsage.isActive,
               let path = UserDefaults.standard.string(forKey: "TallyStripSnapshot") {
                MenuBarStripRenderer.writeSnapshot(segments, to: path)
            }
        }
        button.imagePosition = .imageOnly
        // Surface resizing is handled by PopoverRootView.onContentSize (it reports the real content
        // size on every layout change), so nothing to do here.
    }

    private static func symbolImage() -> NSImage? {
        for name in symbolCandidates {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: "Tally") {
                image.isTemplate = true
                return image
            }
        }
        return nil
    }

    @objc private func handleClick() {
        guard let button = statusItem?.button else { return }
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if isSecondary {
            showMenu(from: button)
        } else {
            togglePopover(button: button)
        }
    }

    private func togglePopover(button: NSStatusBarButton) {
        // While pinned, the floating panel is the usage view; a status-item click just surfaces it
        // rather than opening a competing popover.
        if SettingsStore.shared.isUsagePanelPinned {
            PinnedPanelController.shared.bringToFront()
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Dismiss the popover when another Tally window takes the stage: that window steals key and
    /// promotes the activation policy, which defeats the transient popover's own click-outside
    /// dismissal and leaves it stuck on screen. No-op when closed, so callers need no condition.
    func closePopover() {
        popover.performClose(nil)
    }

    /// Size the popover to the content's measured size (reported by `PopoverRootView.onContentSize`),
    /// deferred a run-loop turn so it never resizes from inside the SwiftUI update that reported it.
    ///
    /// The measured size goes through verbatim, and that is load-bearing. NSPopover re-derives its
    /// anchor from whatever contentSize it is handed, while the window it draws is sized by SwiftUI's
    /// own layout: a cap never shrinks the popover, it only anchors it as if it were smaller, and the
    /// surface jumps a frame after the content changed. Both old caps fired on layouts the user can
    /// pick (four columns is 1108pt wide by design; one column with a full fleet is taller than the
    /// screen), which is why the jump appeared only after a column change. Fitting the screen belongs
    /// to the content that reports the size, never to a size reported back wrong - the content does
    /// it one layout pass earlier, in `ScreenFitStack`, so what arrives here already fits.
    private func applyPopoverSize(_ size: CGSize) {
        DispatchQueue.main.async { [weak self] in
            guard let self, size.width.isFinite, size.height.isFinite, size.width > 1, size.height > 1
            else { return }
            // NSPopover animates contentSize changes with a springy bounce; for in-place content
            // changes (collapsing a provider's cards) the bounce reads as the popover "jumping".
            // Suppress the animation just for the resize - show/close keep theirs.
            let animated = self.popover.animates
            self.popover.animates = false
            self.popover.contentSize = size
            self.popover.animates = animated
        }
    }

    /// Toggle the pinned floating panel (called from the popover/panel footer's pin button).
    static func togglePin() {
        shared?.setPinned(!SettingsStore.shared.isUsagePanelPinned)
    }

    /// Retire the pinned panel, the other half of the transformation below - called by the dashboard
    /// window as it takes the stage.
    ///
    /// The two are one surface in two forms, and the panel floats above every normal window, so
    /// leaving it up while the dashboard opens stacks two IDENTICAL views with the floating one on
    /// top: every click on the covered part of the dashboard is silently eaten by the panel. It
    /// looks like a dead region rather than an overlap precisely because both surfaces render the
    /// same view, and which part is covered changes as the window resizes - switching the dashboard
    /// to Tokens shrinks it (top-anchored), pulling its footer up into the panel's band, so the
    /// whole footer stops responding while the header above the panel still works.
    ///
    /// Unpinning rather than merely hiding keeps the state honest: the window's footer button reads
    /// "Pin on top" again, which is exactly what it now does.
    static func unpin() {
        guard SettingsStore.shared.isUsagePanelPinned else { return }
        SettingsStore.shared.isUsagePanelPinned = false
        PinnedPanelController.shared.hide()
    }

    private func setPinned(_ pinned: Bool) {
        guard pinned else { return Self.unpin() }
        SettingsStore.shared.isUsagePanelPinned = true
        // Pinning is a transformation, not a copy: whichever surface the pin was clicked in
        // (popover or main window) hands its on-screen position AND the view it is showing to
        // the panel and closes, so the panel visibly takes over in place. Handing over only the
        // position would have made pinning the Tokens tab a way to leave it.
        let fromPopover = popoverContentTopLeft()
        let source = fromPopover != nil ? popoverTab : MainWindowController.shared.surfaceTab
        let topLeft = fromPopover ?? MainWindowController.shared.contentTopLeft
        popover.performClose(nil)
        MainWindowController.shared.close()
        PinnedPanelController.shared.show(atTopLeft: topLeft, showing: source.tab)
    }

    /// The screen-space top-left of the popover's content, so the panel can open exactly where the
    /// popover was (its own window frame includes the arrow, so measure the content view instead).
    /// Returns nil unless the popover is actually on screen: after `performClose` AppKit keeps the
    /// content view attached to an off-screen window, so a `view.window` check alone stays non-nil
    /// forever once the popover has been shown, and callers using this as "the pin came from the
    /// popover" would misread every later pin from the main window.
    private func popoverContentTopLeft() -> CGPoint? {
        guard popover.isShown else { return nil }
        guard let view = popover.contentViewController?.view, let window = view.window else { return nil }
        let inWindow = view.convert(view.bounds, to: nil)
        let onScreen = window.convertToScreen(inWindow)
        return CGPoint(x: onScreen.minX, y: onScreen.maxY)
    }

    private func showMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        let open = NSMenuItem(title: String(localized: "Open Tally", bundle: AppLocale.bundle),
                              action: #selector(openMainWindow), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        let settings = NSMenuItem(title: String(localized: "Settings…", bundle: AppLocale.bundle),
                                  action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: String(localized: "Quit Tally", bundle: AppLocale.bundle),
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func openSettings() {
        StatusItemController.openSettingsWindow()
    }

    @objc private func openMainWindow() {
        MainWindowController.shared.show()
    }

    /// Opens the settings window (a reliable custom NSWindow, not the flaky `Settings` scene action).
    static func openSettingsWindow() {
        SettingsWindowController.shared.show()
    }
}
