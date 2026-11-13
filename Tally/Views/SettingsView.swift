import SwiftUI

/// Preferences as a System Settings-style split: a fixed section sidebar on the left, one
/// section's page on the right.
///
/// THE WINDOW IS ONE SIZE ON EVERY PANE (`SettingsChrome.windowWidth` by `windowHeight`, written by
/// `SettingsWindowController.applyFixedSize`). This view reports no size to the window: every page
/// owns a fixed header and a scroll view of its own (`MainPageScroll`), so a short page sits at the
/// top with the page colour below it and a long one scrolls under its header. The window used to
/// follow the pane in front, so it grew and shrank under the click on every sidebar switch (Albert,
/// 2026-08-23, 2026-10-10, 2026-11-12).
struct SettingsView: View {
    @Bindable var store: UsageStore
    @Bindable var settings: SettingsStore

    /// A request to scroll the pane in front to the group tagged with this id (`.id(...)` on the
    /// group); consumed on arrival. Set it together with `select(_:)` to land on a group of another
    /// pane. Not private: the panes live in other files, and `@State` cannot be added by extension.
    @State var scrollTarget: String?

    enum Section: String, CaseIterable {
        /// `overlay` is a pane a private build names and fills (`overlayPaneTitle`, OverlayApp.swift);
        /// the sidebar lists it only while that title is non-nil, so the public window never offers it.
        case accounts, launch, display, integrations, overlay, about

        var title: String {
            switch self {
            case .accounts: return L("Accounts")
            case .launch: return L("Launch")
            case .display: return L("Display")
            case .integrations: return L("Integrations")
            case .overlay: return ""   // named by the overlay (`sidebarTitle`)
            case .about: return L("About")
            }
        }

        var symbol: String {
            switch self {
            case .accounts: return "person.2"
            case .launch: return "play.circle"
            case .display: return "slider.horizontal.3"
            case .integrations: return "puzzlepiece.extension"
            case .overlay: return ""   // drawn by the overlay (`sidebarSymbol`)
            case .about: return "info.circle"
            }
        }
    }

    /// The pane this window opens on. A state preview wins over a capture launch that named one,
    /// the rule `SurfaceTabLaunch` states about its own pair: the preview is the more specific
    /// instruction, since it puts a particular ROW on screen and the pane follows from it.
    @State var section: Section = LoginItemPreview.settingsOpening.onLaunchPane
        ? .launch
        : (SettingsCaptureLaunch.openingSection ?? .accounts)

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sidebar
                .frame(width: SettingsChrome.sidebarWidth, alignment: .top)
                .frame(maxHeight: .infinity, alignment: .top)
                // Up behind the transparent titlebar too, so the sidebar runs to the top edge.
                .background(SettingsChrome.sidebar.ignoresSafeArea())
            // Each page owns its header and its scroll view (`MainPageScroll`); this column only
            // stacks them and hands the one in front the column's full height.
            pane
                .frame(width: SettingsChrome.contentWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(SettingsChrome.page.ignoresSafeArea())
        }
        // The page's top is the window's top: the header's 104 and the title at 36 count from the edge.
        .ignoresSafeArea()
        .environment(\.pageSkeleton, SettingsChrome.skeleton)
        .environment(\.pageScrollTarget, $scrollTarget)
        .environment(\.pageStartsScrolled, SettingsCaptureLaunch.opensScrolled)
        // No window-wide control size (it was `.small`): switches, menus and buttons are regular, and
        // the account table, the one place that wants small switches, sets its own.
        // Key `.id` on the language so switching it rebuilds the whole tree and re-localizes every
        // label (see PopoverRootView for why a bare read isn't enough).
        .id(settings.languageOverride ?? "system")
        // This window answers hovers in the app's own chip too, which is what a `tallyTooltip` in
        // here needs to reach: without a host every target in this tree silently takes the system
        // fallback, and the accounts pane then showed a native yellow box in the middle of a panel
        // that never does (owner's report, 2026-08-24). At the root, outside every pane's own scroll
        // area, per `tallyTooltipLayer`: a host inside a scroll would clip the callout at the pane's edge.
        .tallyTooltipLayer()
        // Dev-only pane switch measurement (SettingsTabBench); inert on every other launch.
        .onReceive(NotificationCenter.default.publisher(for: SettingsTabBench.selectNotification)) {
            if let item = ($0.object as? String).flatMap(Section.init(rawValue:)) { select(item) }
        }
        .onChange(of: benchShown, initial: true) { _, shown in
            if SettingsTabBench.isActive { SettingsTabBench.shown = shown }
        }
        // The overlay pane withdrawn while in front, or a capture launch naming it in a build that
        // has none: fall back to the first pane rather than show an empty one.
        .onChange(of: overlayPaneTitle == nil, initial: true) { _, gone in
            if gone && section == .overlay { select(.accounts) }
        }
    }

    /// The sidebar's sections: the overlay pane only while a private build names it.
    private var shownSections: [Section] {
        Section.allCases.filter { $0 != .overlay || overlayPaneTitle != nil }
    }

    private func sidebarTitle(_ item: Section) -> String {
        item == .overlay ? overlayPaneTitle ?? "" : item.title
    }

    private func sidebarSymbol(_ item: Section) -> String {
        item == .overlay ? overlayPaneSymbol : item.symbol
    }

    private var benchShown: SettingsTabBench.Shown {
        SettingsTabBench.Shown(section: section.rawValue, sections: shownSections.map(\.rawValue))
    }

    /// The brand row (the wordmark only, B-4474), the tag row (version, edition, DEV) and the
    /// navigation; a private build's footer is pinned to the foot by the sidebar's spacer.
    private var sidebar: some View {
        PageSidebar(items: shownSections.map {
            PageSidebarItem(id: $0, title: sidebarTitle($0), symbol: sidebarSymbol($0))
        }, selection: section, select: select) {
            TallyWordmarkView(glyphHeight: 20)
        } tags: {
            HStack(spacing: 6) {
                if let version = BuildVariant.version { versionChip(version) }
                OverlayApp.titlebarEditionBadge
                if BuildVariant.isDev { TallyDevTagView() }
            }
        } footer: {
            overlaySidebarFooter
        }
    }

    private func versionChip(_ version: String) -> some View {
        Text(verbatim: "v\(version)")
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).frame(height: PageSkeleton.tagsHeight)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.07)))
    }

    /// THE ONE WAY A PANE CHANGES (sidebar click and the Launch pane's link to Integrations).
    /// A new pane starts at its top because the pane that stops being in front scrolls itself back
    /// up while nobody can see it (`MainPageScroll`), so nothing is asked of the arriving one. The
    /// Launch link sets `scrollTarget` right after this, for a group of the pane it lands on.
    private func select(_ item: Section) {
        guard item != section else { return }
        section = item
    }

    /// ONLY THE SELECTED PANE HAS A HEIGHT: the one in front gets the column's whole height (its
    /// header and scroll view fill it), the others none.
    ///
    /// COLLAPSED RATHER THAN REMOVED. Building only the selected pane would destroy every pane the
    /// user leaves - and a pane here can be holding work: the launch defaults are STAGED against an
    /// explicit Apply (`StagedModelEffortRow`), so a model picked, a glance at another pane and a
    /// click back put the committed model on screen with nothing said (found by review of
    /// 5e9e03d). A waiting pane keeps its state and adds no height; the three lines above the
    /// frame keep it unseen, unhittable and unread. NO `fixedSize` ON IT: a pane sized to its content
    /// would make its scroll view as tall as the page and cut a long page off at the window's foot.
    private var pane: some View {
        ZStack(alignment: .top) {
            ForEach(Section.allCases, id: \.self) { item in
                paneContent(item)
                    .environment(\.pageIsActive, section == item)
                    .environment(\.pageID, item.rawValue)
                    .opacity(section == item ? 1 : 0)
                    .allowsHitTesting(section == item)
                    .accessibilityHidden(section != item)
                    .frame(height: section == item ? nil : 0, alignment: .top)
                    .clipped()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func paneContent(_ item: Section) -> some View {
        switch item {
        // Its own cards, one per provider under a section header, rather than one shared card.
        // The page is regular; only the table inside each card is small (SettingsAccountsView).
        case .accounts: SettingsAccountsView(store: store, settings: settings)
        // The sharing row reports a state whose switch lives on another pane; it is handed the way
        // there rather than describing it, because a reader who has to be told where a control is
        // has already lost the time this saves them.
        //
        // THE GROUP TOO, NOT JUST THE PANE. Integrations is one scrolling page and the shared
        // harness row is in its first group; a link that landed at the top of a pane taller than
        // the screen could leave the row they pressed for below the fold, which is the state this
        // link exists to end.
        case .launch: SettingsLaunchView(store: store, settings: settings,
                                         visible: section == item,
                                         showIntegrations: {
                                             select(.integrations)
                                             scrollTarget = Self.sharedHarnessAnchor
                                         })
        case .display: displayPane
        case .integrations: integrationsRows
        // The private build's pane: the shared page, then its own titled groups.
        case .overlay:
            SettingsPage(title: overlayPaneTitle ?? "", subtitle: overlayPaneSubtitle) { overlayPaneRows }
        case .about: aboutPane
        }
    }

    /// The `.id` the Integrations pane tags its Shared harness group with (the Launch pane's link
    /// scrolls there through `scrollTarget`).
    static let sharedHarnessAnchor = "integrations.sharedHarness"
}
