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

    private static let symbolCandidates = ["gauge.medium", "gauge", "chart.bar.fill"]

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
                                      onContentSize: { [weak self] size in self?.applyPopoverSize(size) }))
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

    /// Size the popover to the content's measured size (reported by `PopoverRootView.onContentSize`),
    /// deferred a run-loop turn so it never resizes from inside the SwiftUI update that reported it.
    private func applyPopoverSize(_ size: CGSize) {
        DispatchQueue.main.async { [weak self] in
            guard let self, size.width.isFinite, size.height.isFinite, size.width > 1, size.height > 1
            else { return }
            let maxHeight = (NSScreen.main?.visibleFrame.height ?? 1200) - 40
            self.popover.contentSize = CGSize(width: min(size.width, 900), height: min(size.height, maxHeight))
        }
    }

    /// Toggle the pinned floating panel (called from the popover/panel footer's pin button).
    static func togglePin() {
        shared?.setPinned(!SettingsStore.shared.isUsagePanelPinned)
    }

    private func setPinned(_ pinned: Bool) {
        SettingsStore.shared.isUsagePanelPinned = pinned
        if pinned {
            // Pinning is a transformation, not a copy: whichever surface the pin was clicked in
            // (popover or main window) hands its on-screen position to the panel and closes, so
            // the panel visibly takes over in place.
            let topLeft = popoverContentTopLeft() ?? MainWindowController.shared.contentTopLeft
            popover.performClose(nil)
            MainWindowController.shared.close()
            PinnedPanelController.shared.show(atTopLeft: topLeft)
        } else {
            PinnedPanelController.shared.hide()
        }
    }

    /// The screen-space top-left of the popover's content, so the panel can open exactly where the
    /// popover was (its own window frame includes the arrow, so measure the content view instead).
    private func popoverContentTopLeft() -> CGPoint? {
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
