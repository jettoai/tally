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

    /// THE TWO NATURAL HEIGHTS THE WINDOW HAS TO COVER, reported as their maximum. The sidebar is
    /// measured, not guessed at: a constant would go stale on a new section, and go stale silently.
    @State private var paneHeight: CGFloat = 0
    @State private var sidebarHeight: CGFloat = 0

    enum Section: String, CaseIterable {
        case accounts, launch, display, integrations, about

        var title: String {
            switch self {
            case .accounts: return L("Accounts")
            case .launch: return L("Launch")
            case .display: return L("Display")
            case .integrations: return L("Integrations")
            case .about: return L("About")
            }
        }

        var symbol: String {
            switch self {
            case .accounts: return "person.2"
            case .launch: return "play.circle"
            case .display: return "slider.horizontal.3"
            case .integrations: return "puzzlepiece.extension"
            case .about: return "info.circle"
            }
        }
    }

    /// The pane this window opens on. A state preview wins over a capture launch that named one,
    /// the rule `SurfaceTabLaunch` states about its own pair: the preview is the more specific
    /// instruction, since it puts a particular ROW on screen and the pane follows from it.
    @State private var section: Section = LoginItemPreview.settingsOpening.onLaunchPane
        ? .launch
        : (SettingsCaptureLaunch.openingSection ?? .accounts)

    /// Which page of the Integrations pane is in front (SettingsIntegrationsPane.swift). Held here
    /// with `section` because a `@State` is a stored property and an extension cannot add one; not
    /// private for the same reason `displayRows` is not - the pane it belongs to is another file.
    ///
    /// Deliberately NOT remembered across launches. The window opens on a pane, and a pane opening
    /// on whichever page was last read is a second remembered position nobody asked for. A capture
    /// launch that named a page is the exception, for the reason `SettingsCaptureLaunch` gives about
    /// naming a pane: a flag whose job is putting one row on screen has not done it if the row is on
    /// a page the launch left behind.
    @State var integrationsGroup: IntegrationsGroup =
        SettingsCaptureLaunch.openingIntegrationsGroup ?? .commandLine

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sidebar
                .frame(width: 150, alignment: .top)
            Divider()
            // The ScrollView is inert at the natural size; it only actually scrolls when the
            // content outgrows the screen cap applied by the controller.
            ScrollView {
                pane
                    .padding(16)
                    .background(heightProbe { paneHeight = $0 })
            }
            .frame(width: 500)
        }
        .controlSize(.small)
        // Key `.id` on the language so switching it rebuilds the whole tree and re-localizes every
        // label (see PopoverRootView for why a bare read isn't enough).
        .id(settings.languageOverride ?? "system")
        // This window answers hovers in the app's own chip too, which is what a `tallyTooltip` in
        // here needs to reach: without a host every target in this tree silently takes the system
        // fallback, and the accounts pane then showed a native yellow box in the middle of a panel
        // that never does (owner's report, 2026-08-24). At the root and outside the ScrollView, per
        // `tallyTooltipLayer`: a host inside the scroll would clip the callout at the pane's edge.
        .tallyTooltipLayer()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            rows
                .padding(10)
                .background(heightProbe { sidebarHeight = $0 })
            Spacer(minLength: 0)   // outside the probe: it fills the window being measured for
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Section.allCases, id: \.self) { item in
                Button {
                    section = item
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: item.symbol)
                            .font(.callout)
                            .frame(width: 18)
                        Text(item.title).font(.subheadline)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(section == item ? Color.accentColor.opacity(0.18) : .clear)
                    )
                    .foregroundStyle(section == item ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The natural height of whatever it is put behind, taken once and then only when it changes.
    private func heightProbe(_ take: @escaping (CGFloat) -> Void) -> some View {
        GeometryReader { proxy in
            Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in
                take(height)
                onContentHeight(max(paneHeight, sidebarHeight))
            }
        }
    }

    /// ONLY THE SELECTED PANE HAS A HEIGHT, which is what lets the window follow the sidebar. All
    /// five used to lay out at full height, so every pane stood in the TALLEST one's window
    /// (Albert, 2026-08-23). The objection on record against fitting each pane was that the window
    /// jumped under the cursor mid-click; what answers it is WHERE the change happens - the top
    /// edge is held (`SettingsWindowController.fitHeight`), and the change is animated.
    ///
    /// COLLAPSED RATHER THAN REMOVED. Building only the selected pane measures just as well and
    /// destroys every pane the user leaves - and a pane here can be holding work: the launch
    /// defaults are STAGED against an explicit Apply (`StagedModelEffortRow`), so a model picked,
    /// a glance at another pane and a click back put the committed model on screen with nothing
    /// said (found by review of 5e9e03d). A waiting pane keeps its state and adds no height; the
    /// three lines above the frame keep it unseen, unhittable and unread.
    private var pane: some View {
        ZStack(alignment: .top) {
            ForEach(Section.allCases, id: \.self) { item in
                paneContent(item)
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
        case .accounts: sectionCard { SettingsAccountsView(store: store, settings: settings) }
        // The sharing row reports a state whose switch lives on another pane; it is handed the way
        // there rather than describing it, because a reader who has to be told where a control is
        // has already lost the time this saves them.
        //
        // THE PAGE TOO, NOT JUST THE PANE. Integrations has held three pages since it was split,
        // and the shared harness row is on the first of them; a link that lands on whichever page
        // was last read has delivered somebody to a pane where the row they pressed for is not on
        // screen, which is the state this link exists to end.
        case .launch: sectionCard { SettingsLaunchView(store: store, settings: settings,
                                                       visible: section == item,
                                                       showIntegrations: {
                                                           section = .integrations
                                                           integrationsGroup = .commandLine
                                                       }) }
        case .display: sectionCard { displayRows }
        case .integrations: sectionCard { integrationsRows }
        case .about: sectionCard { aboutRows }
        }
    }

    // MARK: Section chrome

    private func sectionCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(0.5)))
    }

    /// The row chrome every pane shares. Not private: the Display pane lives in its own file
    /// (SettingsDisplayPane.swift) and `private` in Swift is file-scoped - copying these per file
    /// is how two panes end up with rows that no longer line up.
    var rowDivider: some View {
        Divider().padding(.leading, 14)
    }


    func toggleRow(_ title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: isOn) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: About - brand + version (brand names stay unlocalized).

    @ViewBuilder
    private var aboutRows: some View {
        HStack(spacing: 6) {
            TallyWordmarkView(glyphHeight: 11)
            Text("by").font(.subheadline)
            ProviderIconShape(pathData: ProviderMarks.jettoWordmark, inset: 0)
                .fill(Color.primary, style: FillStyle(eoFill: true))
                .frame(width: 53, height: 12)
            Spacer()
            // Which of the look-alike builds is this? DEV for the Debug flavour, "Local build"
            // for a source-built release (dormant updater, stuck on its version forever); the
            // installed stable shows nothing extra, its update rows below are the tell.
            if BuildVariant.isDev {
                Text(verbatim: "DEV")
                    .font(.caption2)
                    .foregroundStyle(TallyColor.warning)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(TallyColor.warning.opacity(0.15)))
                    .help(L("Development build - runs beside the installed app and never self-updates"))
            } else if !UpdateAvailability.shared.updaterActive {
                Text(L("Local build"))
                    .font(.caption2)
                    .foregroundStyle(TallyColor.warning)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(TallyColor.warning.opacity(0.15)))
                    .help(L("Built from source without an update feed - it cannot update itself"))
            }
            Text("v\(BuildVariant.version ?? "—")")
                .font(.caption).foregroundStyle(.secondary)
            Link("jetto.ai", destination: URL(string: "https://jetto.ai")!)
                .font(.caption)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)

        rowDivider

        // The Sparkle rows live in their own file (SettingsUpdateRows): the two switches carry a
        // hidden Sparkle-side dependency that needs truthful local state, not computed bindings.
        SettingsUpdateRows()
    }

}
