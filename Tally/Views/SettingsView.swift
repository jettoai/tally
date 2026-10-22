import SwiftUI

/// Preferences as a System Settings-style split: a fixed section sidebar on the left, one
/// section's grouped card on the right, window height fitting the pane in front.
///
/// Both columns are hand-built over NON-LAZY stacks - deliberately not SwiftUI's `Form`/`List`:
/// those are lazy, expose no intrinsic height, and made "open the window exactly content-fit"
/// unsolvable (a short window keeps rows unbuilt, so the measured height stays short - a
/// self-locking loop). Plain stacks lay out everything at once, so the measured height below IS
/// the true content height, reported to the window controller the way the pinned panel sizes
/// itself (`onContentSize` pattern).
struct SettingsView: View {
    @Bindable var store: UsageStore
    @Bindable var settings: SettingsStore
    /// Reports the content's full natural height so the host window can fit itself exactly.
    var onContentHeight: (CGFloat) -> Void = { _ in }
    /// Called on a pane switch, in the click's own turn, with the new pane's height: the host
    /// resizes at once so the pane and the window arrive on screen together.
    var onPaneSwitch: (_ height: CGFloat) -> Void = { _ in }

    /// THE TWO NATURAL HEIGHTS THE WINDOW HAS TO COVER, reported as their maximum. The sidebar is
    /// measured, not guessed at: a constant would go stale on a new section, and go stale silently.
    @State private var sidebarHeight: CGFloat = 0
    /// The footer a private build pins under the sidebar list (`overlaySidebarFooter`); 0 while
    /// there is none. Counted into every reported height, or a short pane would clip it.
    @State private var sidebarFooterHeight: CGFloat = 0

    /// Every pane's own natural height, measured while collapsed too, so a switch knows the height
    /// it is going to BEFORE the pane is on screen.
    @State private var paneHeights: [Section: CGFloat] = [:]
    /// The sidebar row under the pointer, for its hover wash.
    @State private var hoveredSection: Section?
    /// The pane's vertical inset inside the scroll view (top 30 + bottom 32), counted into every
    /// reported height; the horizontal 28 is `SettingsChrome.paneInsetH`.
    private static let paneInsetV = SettingsChrome.paneInsetTop + SettingsChrome.paneInsetBottom
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
            // The ScrollView is inert at the natural size; it only actually scrolls when the
            // content outgrows the screen cap applied by the controller.
            ScrollViewReader { proxy in
                ScrollView {
                    pane
                        .padding(.horizontal, SettingsChrome.paneInsetH)
                        .padding(.top, SettingsChrome.paneInsetTop)
                        .padding(.bottom, SettingsChrome.paneInsetBottom)
                }
                .onChange(of: scrollTarget) { _, target in
                    guard let target else { return }
                    proxy.scrollTo(target, anchor: .top)
                    scrollTarget = nil
                }
            }
            // A card plus the two insets (`SettingsChrome.contentWidth`): the dense account rows
            // need the room for an address beside the name, plan, both figures and two switches.
            .frame(width: SettingsChrome.contentWidth)
            .background(SettingsChrome.page.ignoresSafeArea())
        }
        // No window-wide control size (it was `.small`): switches, menus and buttons are regular, and
        // the account table, the one place that wants small switches, sets its own.
        // Key `.id` on the language so switching it rebuilds the whole tree and re-localizes every
        // label (see PopoverRootView for why a bare read isn't enough).
        .id(settings.languageOverride ?? "system")
        // This window answers hovers in the app's own chip too, which is what a `tallyTooltip` in
        // here needs to reach: without a host every target in this tree silently takes the system
        // fallback, and the accounts pane then showed a native yellow box in the middle of a panel
        // that never does (owner's report, 2026-08-24). At the root and outside the ScrollView, per
        // `tallyTooltipLayer`: a host inside the scroll would clip the callout at the pane's edge.
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
        SettingsTabBench.Shown(section: section.rawValue,
                               height: (paneHeights[section] ?? 0) + Self.paneInsetV)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            rows
                .padding(10)
                .background(heightProbe { sidebarHeight = $0 })
            Spacer(minLength: 0)   // outside the probe: it fills the window being measured for
            overlaySidebarFooter
                .background(heightProbe { sidebarFooterHeight = $0 })
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(shownSections, id: \.self) { item in
                let selected = section == item
                Button {
                    select(item)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: sidebarSymbol(item))
                            .font(.system(size: 15))
                            .frame(width: 22)
                        Text(sidebarTitle(item)).font(.system(size: 15, weight: selected ? .medium : .regular))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(selected ? 0.08 : hoveredSection == item ? 0.06 : 0))
                    )
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { hoveredSection = item } else if hoveredSection == item { hoveredSection = nil }
                }
            }
        }
    }

    /// The natural height of whatever it is put behind, taken once and then only when it changes.
    private func heightProbe(_ take: @escaping (CGFloat) -> Void) -> some View {
        GeometryReader { proxy in
            Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in
                take(height)
                onContentHeight(reportedHeight(for: section))
            }
        }
    }

    /// The height the window has to cover for `item`: its pane plus inset, or the sidebar when taller.
    private func reportedHeight(for item: Section) -> CGFloat {
        max((paneHeights[item] ?? 0) + Self.paneInsetV, sidebarHeight + sidebarFooterHeight)
    }

    /// THE ONE WAY A PANE CHANGES (sidebar click and the Launch pane's link to Integrations).
    /// The pane and the window's height change in this one turn, so neither is ever on screen
    /// without the other: no pane in a window the wrong size, and nothing animating between them.
    private func select(_ item: Section) {
        guard item != section else { return }
        section = item
        onPaneSwitch(reportedHeight(for: item))
    }

    /// ONLY THE SELECTED PANE HAS A HEIGHT, which is what lets the window follow the sidebar. All
    /// five used to lay out at full height, so every pane stood in the TALLEST one's window
    /// (Albert, 2026-08-23). The objection on record against fitting each pane was that the window
    /// jumped under the cursor mid-click; what answers it is WHERE the change happens - the top
    /// edge is held (`SettingsWindowController.fitHeight`), so only the bottom edge moves.
    ///
    /// COLLAPSED RATHER THAN REMOVED. Building only the selected pane measures just as well and
    /// destroys every pane the user leaves - and a pane here can be holding work: the launch
    /// defaults are STAGED against an explicit Apply (`StagedModelEffortRow`), so a model picked,
    /// a glance at another pane and a click back put the committed model on screen with nothing
    /// said (found by review of 5e9e03d). A waiting pane keeps its state and adds no height; the
    /// three lines above the frame keep it unseen, unhittable and unread.
    ///
    /// EACH PANE IS MEASURED WHILE COLLAPSED TOO (its natural height, before the frame folds it),
    /// so a switch knows the height it is going to in the same turn it shows the pane (`select`).
    private var pane: some View {
        ZStack(alignment: .top) {
            ForEach(Section.allCases, id: \.self) { item in
                paneContent(item)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(heightProbe { paneHeights[item] = $0 })
                    .opacity(section == item ? 1 : 0)
                    .allowsHitTesting(section == item)
                    .accessibilityHidden(section != item)
                    .frame(height: section == item ? nil : 0, alignment: .top)
                    .clipped()
            }
        }
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
        // The private build's pane: the shared header, then its own titled groups.
        case .overlay:
            SettingsPage {
                SettingsPageHeader(title: overlayPaneTitle ?? "", subtitle: overlayPaneSubtitle)
                overlayPaneRows
            }
        case .about: aboutPane
        }
    }

    /// The `.id` the Integrations pane tags its Shared harness group with (the Launch pane's link
    /// scrolls there through `scrollTarget`).
    static let sharedHarnessAnchor = "integrations.sharedHarness"
}
