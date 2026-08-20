import Foundation

/// Which Settings pane a capture launch opens on (`-TallySettingsCapture integrations`, demo and dev
/// builds only, argument domain so nothing persists).
///
/// The other half of `-TallySettingsCapture`, written with it for the reason `SurfaceTabLaunch` is
/// written with `-TallyPanelCapture`: that flag decides that the window is up at all without anybody
/// clicking a menu, and this decides what it is showing. A flag whose whole job is putting one row in
/// front of a reviewer has not done it if the window opens on a different pane and leaves them to
/// find it, which is not hypothetical - `LoginItemPreview.SettingsOpening` records the launch that
/// showed the account list and none of the row it was written for.
///
/// The pane is named by the sidebar's own word (`SettingsView.Section.rawValue`), matched without
/// regard to case, because that label is what whoever writes the capture command has in front of
/// them. A word this app has no pane for is ignored rather than refused, exactly as `-TallyTab`
/// ignores one: the flag exists to save that command a click, and failing the launch over a typo in
/// it would cost the whole instance. So does a bare `YES`, which asks for the window and says nothing
/// about the pane.
enum SettingsCaptureLaunch {
    /// The flag itself, taken from the family's own list rather than spelled again here
    /// (`CaptureLaunch.settingsCapture` says why it lives on that side).
    static let key = CaptureLaunch.settingsCapture

    /// Whether this launch is a Settings capture at all.
    ///
    /// Gated exactly like `-TallyAppearance` and `-TallyPanelCapture`: a release instance somebody is
    /// actually using must never have its window opened by an argument that reached its defaults.
    /// Presence is the switch, in whatever shape the value arrived (`CaptureLaunch.isActive`), so the
    /// pane name below and a plain `YES` both count as asking.
    static var isActive: Bool {
        (DemoUsage.isActive || BuildVariant.isDev) && CaptureLaunch.carries(key)
    }

    /// The pane such a launch opens on, or nil when this launch is not one (or named no pane, or
    /// named one this app does not have).
    static var openingSection: SettingsView.Section? {
        guard isActive, let raw = UserDefaults.standard.string(forKey: key) else { return nil }
        return SettingsView.Section(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased())
    }
}
