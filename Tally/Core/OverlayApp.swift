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
    /// Small text a private build adds after the menu-bar strip's DEV tag (drawn as the same outlined
    /// tag); nil in the public build.
    @MainActor static var menuBarEditionText: String? { nil }
    /// What a private build says in place of the public GitHub download pointer when the build has
    /// no update feed; non-nil also drops the link beside the version. Nil keeps the public wording.
    @MainActor static var noUpdateNote: String? { nil }
    /// The edition badge in the Settings window's title bar; the public build shows none.
    @MainActor @ViewBuilder static var titlebarEditionBadge: some View { EmptyView() }
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
    /// trailing divider, so the public pane is unchanged. (The pane no longer draws it; retired
    /// together with the private build's check that names it.)
    @ViewBuilder var overlayAboutRows: some View { EmptyView() }
    /// A mark a private build shows beside the wordmark on the About pane's identity card.
    @ViewBuilder var overlayEditionMark: some View { EmptyView() }
    /// A layer a private build paints behind the identity card's content, inside its rounded shape.
    @ViewBuilder var overlayIdentityBackdrop: some View { EmptyView() }
    /// A block a private build pins to the bottom of the sidebar, under the pane list.
    @ViewBuilder var overlaySidebarFooter: some View { EmptyView() }
    /// A strip a private build adds at the bottom of the identity card; the public card has none.
    @ViewBuilder var editionFooter: some View { EmptyView() }
    /// The name of a sidebar pane a private build adds; nil leaves the pane out.
    var overlayPaneTitle: String? { nil }
    /// That pane's sidebar symbol (an SF Symbol name).
    var overlayPaneSymbol: String { "" }
    /// The line under that pane's page title; nil leaves the header with a title only.
    var overlayPaneSubtitle: String? { nil }
    /// That pane's groups: `SettingsSection`s, which the page lays out under the header.
    @ViewBuilder var overlayPaneRows: some View { EmptyView() }
}
#endif
