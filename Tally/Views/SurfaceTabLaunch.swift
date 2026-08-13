import Foundation

/// Which page a launch asks the surface to open on (`-TallyTab sessions`, demo and dev builds only,
/// argument domain so nothing persists).
///
/// It exists because the selection is deliberately not persisted (`SurfaceTabState`), so every
/// surface opens on Usage and the only other way to another page is the header switch. Clicking it
/// means synthesizing a click into the app, which takes the pointer and the frontmost app away from
/// whoever is using the machine, and a dev-only flag that puts the state on screen instead is the
/// sanctioned answer (~/.claude/docs/patterns/macos-app-verification.md).
///
/// It is the other half of `-TallyPanelCapture`, and the two are written together: that flag decides
/// that a surface is on screen at all without anybody clicking the status item, this one decides what
/// that surface is showing. Alone it shows nothing, which is why it only ever qualifies a launch that
/// already puts a window up (a capture, or a restored dashboard window).
enum SurfaceTabLaunch {
    /// What a surface opens on. Asked here rather than in each host so that the three copies of the
    /// surface (popover, pinned panel, dashboard window) cannot answer it differently.
    ///
    /// Gated exactly like `-TallyAppearance` and `-TallyPanelCapture`: a release instance somebody
    /// is actually using must open where its own state says, whatever arguments reach its defaults.
    ///
    /// The page is named by the tab's own word (`SurfaceTab.rawValue`), matched without regard to
    /// case, because the label is what whoever writes the capture command has in front of them. A
    /// word this app has no page for is ignored rather than refused: the flag exists to save that
    /// command a click, and failing the launch over a typo in one would cost the whole instance.
    ///
    /// Falling back to `-TallyTokenGraphPreview`'s implied page, and after it rather than before:
    /// that flag says which ROW to unfold and the Tokens tab follows from it, while this one is a
    /// statement about the page itself, so the more specific instruction wins when both are given.
    static var initialTab: SurfaceTab {
        guard DemoUsage.isActive || BuildVariant.isDev,
              let raw = UserDefaults.standard.string(forKey: "TallyTab"),
              let named = SurfaceTab(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased())
        else { return TokenGraphPreview.project == nil ? .usage : .tokens }
        return named
    }
}
