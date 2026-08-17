import SwiftUI

/// WHAT A SURFACE IS AND WHICH WINDOW IT IS IN: the three pages the usage surface shows, the three
/// hosts that can show them, and one host's own selection.
///
/// Split out of `PopoverRootView` because none of it is the view: the hosts name themselves with
/// `SurfaceHost` before any view exists (`SurfaceSizer`), the tab state is owned by the controllers
/// and handed in, and the pages are named by the launch flags that seed them
/// (`SurfaceTabLaunch`).

/// What a surface is showing. Not a window concept: the popover, the pinned panel and the dashboard
/// window are all this same view, and all three can be flipped to any of its pages and back.
///
/// The three answer three different questions and are deliberately not merged: how much quota is
/// left, where the tokens went, and what is running right now (`SessionBoardView`).
enum SurfaceTab: String, CaseIterable, Identifiable {
    case usage, tokens, sessions
    var id: String { rawValue }
    var label: String {
        switch self {
        case .usage: return L("Usage")
        case .tokens: return L("Tokens")
        case .sessions: return L("Sessions")
        }
    }
}

/// Which host is presenting this copy of the surface. The view itself is the same in all three, so
/// this exists only for the answers that depend on WHICH window is asking: the view-options anchor
/// has to know whose card is open, because the dashboard and the menu-bar popover can be on screen
/// at once and only the one actually presenting the card may swap its resize corner (see
/// `SettingsStore.viewOptionsHost`).
enum SurfaceHost: Sendable {
    case popover, panel, window
}

/// One surface's tab selection, one instance per host - deliberately not shared: flipping the pinned
/// panel to token history should not also flip the menu-bar popover, which is opened for one glance
/// at the quota and closed again.
///
/// It lives with the host controller rather than in the view's own `@State` because pinning is a
/// hand-off, not a copy: the panel that replaces the popover has to open on the view the user was
/// reading, and `@State` can only ever be seeded by the view that owns it. The controllers stay the
/// only writers from outside, and only at that one moment.
///
/// It also outlives a close, because each host's view is built once and reused: reopening shows what
/// the user last chose rather than silently undoing it, and the header switch says which view this is.
@MainActor
@Observable
final class SurfaceTabState {
    /// Usage on every real launch. A capture launch can open on another page instead, either by
    /// naming it (`-TallyTab`) or by naming a graph that lives on one (`-TallyTokenGraphPreview`),
    /// so the capture needs no click to get there - those flags' whole purpose. Seeded rather than
    /// switched after launch, so nothing is ever photographed mid-crossfade (`SurfaceTabLaunch`).
    var tab: SurfaceTab = SurfaceTabLaunch.initialTab
    /// Which sessions the board lists (`SessionFilter`). Here for the same reasons the tab is: one
    /// per host, so narrowing the pinned panel's board does not narrow the popover's, and never
    /// persisted - it is a question asked while looking, not a preference.
    var sessionFilter: SessionFilter = .all
}
