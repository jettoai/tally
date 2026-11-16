import AppKit

/// `-TallyPinnedDropProbe "x,y"` (demo or dev builds only): put the pinned panel's top-left at the
/// given screen point (AppKit coordinates, y up), post the same `PanelDrag.ended` a real release
/// posts, and force one data refresh 20 s later. An outside sampler reading the window list can then
/// tell whether anything moves the panel after a drop, which no in-process log can say for the
/// writes that come from AppKit itself. Writes no frame of its own beyond the one `show` does.
/// A third field, `x,y,rings`, also switches the strip to the rings-only form 10 s in: a content
/// size change, which is the other thing that resizes the panel after a drop.
/// `x,y,cycle` starts on the full panel and steps to the labeled strip and then the rings every 4 s,
/// so a clip of one window (`-TallyWindowBurst`) can show all three forms switching (B-4640).
@MainActor
enum PinnedDropProbe {
    static func runIfAsked() {
        let key = "TallyPinnedDropProbe"
        guard DemoUsage.isActive || BuildVariant.isDev, CaptureLaunch.carries(key),
              let text = UserDefaults.standard.string(forKey: key) else { return }
        let fields = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let parts = fields.prefix(2).compactMap { Double($0) }
        guard parts.count == 2 else { return }
        let point = CGPoint(x: parts[0], y: parts[1])
        let switchesToRings = fields.dropFirst(2).first == "rings"
        let cycles = fields.dropFirst(2).first == "cycle"
        // Delayed for the same reason `showMenuForCaptureIfAsked` is: the first moments of a launch
        // have no settled windows, and the panel's restore from its autosaved frame is still landing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if cycles { SettingsStore.shared.pinnedStyle = .full }
            PinnedPanelController.shared.show(atTopLeft: point)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: PanelDrag.ended, object: nil)
            }
            if switchesToRings {
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { SettingsStore.shared.pinnedStyle = .rings }
            }
            if cycles {
                for (n, style) in [PinnedStyle.labeled, .rings].enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4 * Double(n + 1)) {
                        SettingsStore.shared.pinnedStyle = style
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                Task { await UsageStore.shared.refresh(userInitiated: true) }
            }
        }
    }
}
