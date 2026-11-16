import AppKit

/// The pinned strips' secondary-click menu: Unpin first, then the three pin styles and the two
/// directions (a check marks the current one), then Settings. The full panel does not get it, it has
/// its own pin button. Built fresh on every click so the checks always read the live setting.
///
/// A strip has no title bar and no footer, so before this the only way to put one away was the
/// close button that shows on hover, which nobody had been told about ("can this not be closed?").
@MainActor
enum PinnedStripMenu {
    static func make() -> NSMenu {
        let target = PinnedStripMenuTarget.shared
        let settings = SettingsStore.shared
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, value: String? = nil, on: Bool = false, key: String = "") {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target
            item.representedObject = value
            item.state = on ? .on : .off
            menu.addItem(item)
        }
        add(L("Unpin window"), #selector(PinnedStripMenuTarget.unpin))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: L("Pin style")))
        for style in PinnedStyle.allCases {
            add(PinnedStylePicker.label(style), #selector(PinnedStripMenuTarget.pickStyle(_:)),
                value: style.rawValue, on: settings.pinnedStyle == style)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: L("Direction")))
        for axis in PinnedAxis.allCases {
            add(PinnedStylePicker.label(axis), #selector(PinnedStripMenuTarget.pickAxis(_:)),
                value: axis.rawValue, on: settings.pinnedAxis == axis)
        }
        menu.addItem(.separator())
        add(L("Open Settings…"), #selector(PinnedStripMenuTarget.openSettings), key: ",")
        return menu
    }

    /// `-TallyStripMenuCapture YES` (demo or dev builds only): three seconds after the pinned panel
    /// comes up, pop this menu at the strip's top left so it can be photographed without a
    /// synthesized click. `-TallyStripMenuCapture unpin` instead runs the first item through the
    /// menu's own action path, for a before and after of the unpinning it stands for.
    static func showForCaptureIfAsked(in window: NSWindow) {
        let key = "TallyStripMenuCapture"
        guard DemoUsage.isActive || BuildVariant.isDev, CaptureLaunch.carries(key) else { return }
        let unpins = UserDefaults.standard.string(forKey: key)?.lowercased() == "unpin"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard let view = window.contentView else { return }
            let menu = make()
            if unpins { return menu.performActionForItem(at: 0) }
            let top = view.isFlipped ? 24 : view.bounds.height - 24
            list(menu, as: "strip-menu")
            menu.popUp(positioning: nil, at: NSPoint(x: 24, y: top), in: view)
        }
    }

    /// A text listing of a menu's rows (a check mark on the ones that carry one) written next to the
    /// window snapshot's pictures (`-TallyWindowSnapshot <dir>`): a capture instance in the
    /// background gets no menu window on screen to photograph, so what the menu holds is read back
    /// from the menu itself instead.
    static func list(_ menu: NSMenu, as name: String) {
        guard let dir = UserDefaults.standard.string(forKey: WindowSnapshot.flagKey), !dir.isEmpty else { return }
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let rows = menu.items.map { item in
            item.isSeparatorItem ? "---" : (item.state == .on ? "[x] " : "    ") + item.title
                + (item.keyEquivalent.isEmpty ? "" : "  (cmd-\(item.keyEquivalent))")
        }
        try? rows.joined(separator: "\n").write(to: url.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
    }
}

/// Where the menu's items land. A menu item's target is weak, so this lives for the whole process.
@MainActor
final class PinnedStripMenuTarget: NSObject {
    static let shared = PinnedStripMenuTarget()

    @objc func unpin() { StatusItemController.unpin() }

    @objc func pickStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = PinnedStyle(rawValue: raw) else { return }
        SettingsStore.shared.pinnedStyle = style
    }

    @objc func pickAxis(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let axis = PinnedAxis(rawValue: raw) else { return }
        SettingsStore.shared.pinnedAxis = axis
    }

    @objc func openSettings() { StatusItemController.openSettingsWindow() }
}
