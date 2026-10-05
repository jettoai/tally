import SwiftUI

// What a private build adds to the app. The public build adds nothing.
#if !TALLY_OVERLAY
enum OverlayApp {
    @MainActor static func didFinishLaunching() {}
    @MainActor static func panelAppeared() {}
    @MainActor static func panelDisappeared() {}
    /// A line a private build adds to the menu-bar item's hover; non-nil also puts a small mark
    /// beside the strip.
    @MainActor static var statusItemNote: String? { nil }
    /// Set by the status item; a private build calls it when its note changes.
    @MainActor static var statusItemChanged: (() -> Void)?
}

extension PopoverRootView {
    /// A strip a private build shows under the advisor row.
    @ViewBuilder var overlayStrip: some View { EmptyView() }
    /// A mark a private build shows beside the header's version.
    @ViewBuilder var overlayHeaderBadge: some View { EmptyView() }
}

extension SessionCardView {
    /// A mark a private build shows at the trailing end of a session card's headline.
    @ViewBuilder var overlaySessionBadge: some View { EmptyView() }
}

extension SettingsView {
    /// Rows a private build adds to the About pane, under the brand row. Each row brings its own
    /// trailing divider, so the public pane is unchanged.
    @ViewBuilder var overlayAboutRows: some View { EmptyView() }
}
#endif
