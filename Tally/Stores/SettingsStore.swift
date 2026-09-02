import Foundation
import Observation

/// User preferences, persisted to UserDefaults. Shared singleton so the popover, settings window, and
/// status item all read the same state.
@MainActor
@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    /// Provider ids the user has enabled (default: all shipped providers).
    var enabledProviders: Set<String> {
        didSet { UserDefaults.standard.set(Array(enabledProviders), forKey: "enabledProviders") }
    }

    /// Per-account display-name overrides, keyed by account id.
    var accountLabels: [String: String] {
        didSet { UserDefaults.standard.set(accountLabels, forKey: "accountLabels") }
    }

    /// The user's custom card order (account ids). Empty = discovery order. Applied everywhere (popover,
    /// dashboard, menu bar) so drag-reordering the cards reorders the whole app consistently.
    var accountOrder: [String] {
        didSet {
            UserDefaults.standard.set(accountOrder, forKey: "accountOrder")
            UsageStore.shared.onChange?()   // keep the AppKit menu-bar order in sync
        }
    }

    /// The user's own order for the SESSION board, by project directory (`SessionBoardOrder` says
    /// why it is not by session). Empty = the board sits in the seats it took, which is where it
    /// sits until a card is dragged.
    ///
    /// KEPT WHEN THE STATE SORT TAKES OVER, never erased by it: the switch below is a changeover
    /// between two orders, and an arrangement thrown away by flipping a switch would be one the
    /// hand has to build again to get back to.
    ///
    /// Persisted, unlike the board's filter one file over: the filter is a question asked while
    /// looking ("what is actually connected to me?"), this is an arrangement somebody made and
    /// expects to find again after a restart, and after the sessions that were in it have ended.
    var sessionBoardOrder: [String] {
        didSet { SessionBoardOrder.save(sessionBoardOrder, to: .standard) }
    }

    /// WHICH OF THE BOARD'S TWO ORDERS IS GOVERNING IT: the state sort, asked afresh whenever the
    /// board is opened, or the user's own hand. On, an opening surface seats the board by what the
    /// sessions are doing at that moment (what needs somebody first) and it then holds those seats
    /// for as long as it is up (`SessionRosterStore.seatingOnOpen`); off, the board holds the seats
    /// it has and the arrangement that was dragged into them.
    ///
    /// A MODE RATHER THAN AN ACTION (2026-08-15). It was a button that sorted once, which is a
    /// control whose whole effect is over the instant it is pressed: a session that started waiting
    /// a minute later sat wherever it happened to sit, and the only way to see the board as it stood
    /// was to press again. A switch that is ON has to keep being true of every board handed over,
    /// so the sort is asked again at each opening rather than only at the one press.
    ///
    /// AND THE HAND TAKES IT BACK BY USING IT: dragging a card while this is on turns it off
    /// (`sessionsReorderGesture`), because a board that re-sorted itself out from under a drag would
    /// be answering two owners at once. Owner's ruling, and the reason the arrangement above is
    /// remembered rather than erased: the switch is how you change your mind, in either direction.
    var sessionBoardSortsByState: Bool {
        didSet {
            UserDefaults.standard.set(sessionBoardSortsByState, forKey: "sessionBoardSortsByState")
        }
    }

    /// Accounts hidden from the menu-bar strip (empty = all shown). Stored as a hidden-set so new
    /// accounts default to visible.
    var menuBarHiddenAccounts: Set<String> {
        didSet { UserDefaults.standard.set(Array(menuBarHiddenAccounts), forKey: "menuBarHiddenAccounts") }
    }

    /// Accounts the user switched off entirely: not polled, no card, no menu-bar segment, skipped
    /// by the `tally` CLI (excluded from the snapshot). Stored as a disabled-set so new accounts
    /// default to on.
    var disabledAccounts: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(disabledAccounts), forKey: "disabledAccounts")
            UsageStore.shared.onChange?()
        }
    }

    /// Show meters as used vs remaining.
    var displayMode: DisplayMode {
        didSet {
            UserDefaults.standard.set(displayMode.rawValue, forKey: "displayMode")
            // The menu-bar strip is AppKit - it only repaints on `onChange`, not via SwiftUI
            // observation, so toggling used/remaining must nudge it or it keeps the old direction.
            UsageStore.shared.onChange?()
            // The status line reads the mode from the snapshot; republish (no refetch).
            UsageStore.shared.republishSnapshot()
        }
    }

    /// One menu-bar segment per account, or one per provider summing its accounts (see
    /// `MenuBarLayout`).
    var menuBarLayout: MenuBarLayout {
        didSet {
            UserDefaults.standard.set(menuBarLayout.rawValue, forKey: "menuBarLayout")
            // The strip is AppKit - it repaints on `onChange`, not through SwiftUI observation.
            UsageStore.shared.onChange?()
        }
    }

    /// Show every model-scoped window, or just the highest-tier headline (default).
    var showAllModels: Bool {
        didSet { UserDefaults.standard.set(showAllModels, forKey: "showAllModels") }
    }

    /// Minutes between background refreshes.
    var refreshIntervalMinutes: Int {
        didSet {
            UserDefaults.standard.set(refreshIntervalMinutes, forKey: "refreshIntervalMinutes")
            UsageStore.shared.rescheduleRefresh()
        }
    }

    /// UI language override; nil follows the system locale.
    var languageOverride: String? {
        didSet { AppLocale.override = languageOverride }
    }

    /// Whether the usage panel is pinned as an always-on-top floating window (vs the transient popover).
    /// The window's position is persisted separately by AppKit's frame autosave.
    var isUsagePanelPinned: Bool {
        didSet { UserDefaults.standard.set(isUsagePanelPinned, forKey: "isUsagePanelPinned") }
    }

    /// The pinned panel draws a behind-window glass (desktop vibrancy) base instead of a solid one.
    /// The fleet gauge (cross-account weekly pool + pace forecast) above the cards.
    var showFleetGauge: Bool {
        didSet { UserDefaults.standard.set(showFleetGauge, forKey: "showFleetGauge") }
    }

    /// The usage advisor strip (the "do I need another account?" verdict line under the fleet
    /// gauge). Its own switch, independent of the fleet gauge, so either can show alone.
    var showAdvisor: Bool {
        didSet { UserDefaults.standard.set(showAdvisor, forKey: "showAdvisor") }
    }

    /// How many days of history the advisor strip's demand figure is measured over: one of
    /// `UsageAdvisor.displayWindows`, cycled by clicking the figure itself.
    ///
    /// A VIEW SETTING AND ONLY THAT. The verdict, the pips and the trigger stay fixed to the full
    /// 28-day lookback whatever this says: a recommendation that changed with the reader's zoom
    /// level would be a different piece of advice per click. What this moves is the number, which
    /// is the question "is this month's average still what I am doing THIS week".
    ///
    /// Remembered because it is an opinion about how the reader reads, not about this session: a
    /// fleet whose habits just changed wants the short lens every time the panel opens.
    var advisorWindowDays: Double {
        didSet { UserDefaults.standard.set(advisorWindowDays, forKey: "advisorWindowDays") }
    }

    /// Providers whose account cards are folded away behind their fleet gauge (clicking the gauge
    /// row toggles it). A view gesture, not a Settings item: the collapse only takes effect while
    /// that provider's gauge is actually on screen, so cards can never become unreachable.
    var collapsedProviders: Set<String> {
        didSet { UserDefaults.standard.set(collapsedProviders.sorted(), forKey: "collapsedProviders") }
    }

    /// Both entry points call this one - the chevron on the provider's gauge row and the section
    /// heading down in the cards - and the rule itself is pure (`PanelSections.toggling`), so the
    /// two surfaces read one state rather than keeping two.
    func toggleCollapsed(_ providerID: String) {
        collapsedProviders = PanelSections.toggling(providerID, in: collapsedProviders)
    }

    /// Status line renders the full quota line (bars + resets) even when wrapping a custom
    /// status line - for people who drop their own quota rendering and rely on Tally's.
    /// Off = the minimal signal, which never disturbs a layout someone else designed.
    var statuslineFullQuota: Bool {
        didSet {
            UserDefaults.standard.set(statuslineFullQuota, forKey: "statuslineFullQuota")
            // The CLI learns this from the snapshot; republish (no refetch) so it's immediate.
            UsageStore.shared.republishSnapshot()
        }
    }

    /// Panel card columns: 0 = auto (1 column single-account, 2 once any provider has siblings),
    /// or an explicit 2 / 3 / 4 for people with many accounts and the screen to spread them.
    var panelColumns: Int {
        didSet { UserDefaults.standard.set(panelColumns, forKey: "panelColumns") }
    }

    /// Cards or the compact one-row-per-account list (see `PanelDensity`). Cards by default: the
    /// list only pays for itself once a fleet outgrows the screen, and it is the denser read that
    /// hides detail, not the one to meet the app with.
    var panelDensity: PanelDensity {
        didSet { UserDefaults.standard.set(panelDensity.rawValue, forKey: "panelDensity") }
    }

    /// The compact list's own column count, same vocabulary as `panelColumns` (0 = auto, 1...4 an
    /// explicit width). Its OWN setting rather than a shared one, because a comfortable number of
    /// 263pt cards is not a comfortable number of rows nearly twice that wide: sharing it would have
    /// each density silently rewrite the other's layout every time the user switched.
    var listColumns: Int {
        didSet { UserDefaults.standard.set(listColumns, forKey: "listColumns") }
    }

    /// The highest explicit column count the compact list offers. Three, where the cards offer four:
    /// a row is nearly twice a card's width (Albert's call, 2026-08-04).
    static let maxListColumns = 3

    /// The session board's own column count, in the same vocabulary again (0 = auto, 1...
    /// `maxSessionsColumns` an explicit width). A THIRD remembered number, and the reason is the one
    /// the list already gave for being the second: the Sessions page is a different page, read for a
    /// different question, and a count chosen for a fleet of account cards is not a count anybody
    /// asked the board for. Sharing one meant the board laid itself out to whatever the density
    /// picker was last edited to, so a board read one card at a time could not be said at all while
    /// the accounts were in two columns (Albert, 2026-08-17).
    ///
    /// It is spent on the CARDS, not on the window: the board lays out at most this many columns
    /// inside the surface the account pages sized, because a width that followed the page resized
    /// the surface on every tab switch (`PopoverRootView.popoverWidth`). A count the surface cannot
    /// seat steps down to the one it can.
    var sessionsColumns: Int {
        didSet { UserDefaults.standard.set(sessionsColumns, forKey: "sessionsColumns") }
    }

    /// The highest explicit count the session board offers, which is the account cards' four.
    ///
    /// It was two, on the reasoning that a third column of session cards would need a panel wider
    /// than that page has anything to say in - true only while a session card was frozen at the
    /// account ladder's width and the board could not use the room it was given. The cards divide
    /// up the surface now, so a 1108pt panel reads four session columns as comfortably as it reads
    /// four account ones, and auto was already using every column that fits while an explicit choice
    /// stopped at two: a ceiling the page itself did not have (Albert, 2026-08-18).
    ///
    /// Nothing stored has to move: 0, 1 and 2 mean what they always meant, and the range only opens
    /// upward (`PanelGeometry.storedColumns`).
    static let maxSessionsColumns = 4

    /// The highest count the picker offers for the density on screen, so the two surfaces that show
    /// that picker cannot disagree about where the tiles stop.
    var densityMaxColumns: Int { panelDensity == .list ? Self.maxListColumns : 4 }

    /// The column count the panel's picker edits: whichever density is on screen owns it. One
    /// control on both surfaces, two remembered numbers behind it.
    var densityColumns: Int {
        get { panelDensity == .list ? listColumns : panelColumns }
        set {
            if panelDensity == .list { listColumns = newValue } else { panelColumns = newValue }
        }
    }

    var isPanelTranslucent: Bool {
        didSet { UserDefaults.standard.set(isPanelTranslucent, forKey: "isPanelTranslucent") }
    }

    /// Cards in one continuous grid (default) or split into a section per provider. Off by default:
    /// with a single provider the sections are pure overhead, and the flat grid is the denser read.
    var groupByProvider: Bool {
        didSet { UserDefaults.standard.set(groupByProvider, forKey: "groupByProvider") }
    }

    /// Reset instants as countdown vs exact time - toggled by clicking any reset label.
    var resetDisplay: ResetDisplay {
        didSet { UserDefaults.standard.set(resetDisplay.rawValue, forKey: "resetDisplay") }
    }

    /// Which window the fleet gauge and the menu-bar numbers lead with (see GaugeFocus).
    var gaugeFocus: GaugeFocus {
        didSet {
            UserDefaults.standard.set(gaugeFocus.rawValue, forKey: "gaugeFocus")
            UsageStore.shared.onChange?()          // the AppKit strip repaints only on a nudge
            UsageStore.shared.republishSnapshot()  // the CLI's fleet line follows the same focus
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        enabledProviders = defaults.stringArray(forKey: "enabledProviders").map(Set.init)
            ?? Set(ProviderCatalog.descriptors.map(\.id))
        accountLabels = (defaults.dictionary(forKey: "accountLabels") as? [String: String]) ?? [:]
        accountOrder = defaults.stringArray(forKey: "accountOrder") ?? []
        // Held in a local as well because the switch below is read off it, and a property cannot be
        // read back until every one of them has a value.
        let arrangement = SessionBoardOrder.load(from: defaults)
        sessionBoardOrder = arrangement
        // NEVER CHOSEN IS READ OFF THE BOARD ITSELF. A machine that already has an arrangement was
        // dragged by hand while the state sort was a button, so it starts with the switch off and
        // finds that arrangement exactly where it left it; one that has none starts with it on,
        // which is what its board did at every launch before the switch existed. Either way the
        // first draw after an update is the order the user last saw, which is the only reading that
        // does not move a board behind somebody's back.
        sessionBoardSortsByState = defaults.object(forKey: "sessionBoardSortsByState") as? Bool
            ?? arrangement.isEmpty
        menuBarHiddenAccounts = Set(defaults.stringArray(forKey: "menuBarHiddenAccounts") ?? [])
        disabledAccounts = Set(defaults.stringArray(forKey: "disabledAccounts") ?? [])
        displayMode = DisplayMode(rawValue: defaults.string(forKey: "displayMode") ?? "") ?? .remaining
        // POOLED IS THE DEFAULT (owner ruling, 2026-08-12): the bar is asked "how much is left",
        // and one figure per provider answers it at a glance where N marks ask the reader to add
        // up. `nil` here is "never chosen", not "chose accounts" - this key is written only by the
        // Display pane's picker (property observers do not run during init), so flipping the
        // fallback moves everyone who never expressed a preference and nobody who did.
        menuBarLayout = MenuBarLayout(rawValue: defaults.string(forKey: "menuBarLayout") ?? "")
            ?? .pooled
        showAllModels = defaults.object(forKey: "showAllModels") as? Bool ?? false
        // Default 5 minutes: a public-friendly default - each poll spawns the provider CLIs, so
        // faster ticks trade background CPU for freshness. Users can go down to 1 min (reads run
        // under the CLIs' own first-party identity, which gets the generous rate-limit bucket).
        let interval = defaults.integer(forKey: "refreshIntervalMinutes")
        // Clamp to the picker's options so a legacy 30/60 value can't leave the picker blank.
        // Default to the fastest poll: the target user runs several paid accounts hard, where a
        // 5-hour window moves percentage points per minute and stale numbers mislead smart pick
        // (Albert's call, 2026-07-20). Overlap is guarded by isRefreshing, and users can still
        // slow it down to 2/5/15.
        refreshIntervalMinutes = [1, 2, 5, 15].contains(interval) ? interval : 1
        languageOverride = AppLocale.override
        isUsagePanelPinned = defaults.bool(forKey: "isUsagePanelPinned")
        showFleetGauge = defaults.object(forKey: "showFleetGauge") as? Bool ?? true
        showAdvisor = defaults.object(forKey: "showAdvisor") as? Bool ?? true
        // Anything that is not one of the offered windows reads as the default (the full lookback),
        // which covers a missing key, a build that offered a window this one no longer does, and a
        // hand-edited plist - the same rule the remembered column counts follow below.
        let storedWindow = defaults.object(forKey: "advisorWindowDays") as? Double ?? 0
        advisorWindowDays = UsageAdvisor.displayWindows.contains(storedWindow)
            ? storedWindow : UsageAdvisor.lookbackDays
        collapsedProviders = Set(defaults.stringArray(forKey: "collapsedProviders") ?? [])
        statuslineFullQuota = defaults.bool(forKey: "statuslineFullQuota")
        // ALL THREE REMEMBERED COUNTS COME BACK THROUGH THE ONE RULE
        // (`PanelGeometry.storedColumns`): clamped into the range the picker still offers, and
        // anything that is not a count at all read as auto. A stored number past the highest tile
        // has to come back to that tile rather than to a count nothing can select - the compact
        // list used to go up to four - and the cards' own count was the last one still spelling
        // that rule by hand, which made a four-column machine that had once seen a wider ladder
        // land on auto where its neighbours landed on the widest tile.
        panelColumns = PanelGeometry.storedColumns(defaults.integer(forKey: "panelColumns"), max: 4)
        panelDensity = PanelDensity(rawValue: defaults.string(forKey: "panelDensity") ?? "") ?? .cards
        listColumns = PanelGeometry.storedColumns(defaults.integer(forKey: "listColumns"),
                                                  max: SettingsStore.maxListColumns)
        sessionsColumns = PanelGeometry.storedColumns(defaults.integer(forKey: "sessionsColumns"),
                                                      max: SettingsStore.maxSessionsColumns)
        isPanelTranslucent = defaults.object(forKey: "isPanelTranslucent") as? Bool ?? true
        groupByProvider = defaults.bool(forKey: "groupByProvider")
        resetDisplay = ResetDisplay(rawValue: defaults.string(forKey: "resetDisplay") ?? "") ?? .relative
        gaugeFocus = GaugeFocus(rawValue: defaults.string(forKey: "gaugeFocus") ?? "") ?? .all
    }

    func isEnabled(_ providerID: String) -> Bool { enabledProviders.contains(providerID) }

    func setEnabled(_ providerID: String, _ on: Bool) {
        if on { enabledProviders.insert(providerID) } else { enabledProviders.remove(providerID) }
    }

    func isAccountEnabled(_ accountID: String) -> Bool { !disabledAccounts.contains(accountID) }

    func setAccountEnabled(_ accountID: String, _ on: Bool) {
        if on { disabledAccounts.remove(accountID) } else { disabledAccounts.insert(accountID) }
    }

    /// Reorder ONE provider's accounts: the provider's slots in the global order keep their
    /// positions, only which account occupies which slot changes - so reordering Claude 1/2 never
    /// shuffles them relative to Codex.
    func applyProviderOrder(orderedProviderIDs: [String], allIDs: [String]) {
        var iterator = orderedProviderIDs.makeIterator()
        let providerSet = Set(orderedProviderIDs)
        accountOrder = orderedAccountIDs(allIDs).map {
            providerSet.contains($0) ? (iterator.next() ?? $0) : $0
        }
    }

    func isShownInMenuBar(_ accountID: String) -> Bool { !menuBarHiddenAccounts.contains(accountID) }

    func setShownInMenuBar(_ accountID: String, _ shown: Bool) {
        if shown { menuBarHiddenAccounts.remove(accountID) } else { menuBarHiddenAccounts.insert(accountID) }
    }

    /// Sort account ids by the saved custom order; ids not in the order keep their input order at the end.
    func orderedAccountIDs(_ ids: [String]) -> [String] {
        let rank = Dictionary(accountOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.enumerated().sorted { lhs, rhs in
            let lr = rank[lhs.element] ?? Int.max
            let rr = rank[rhs.element] ?? Int.max
            return lr == rr ? lhs.offset < rhs.offset : lr < rr
        }.map(\.element)
    }

    /// Drag-reorder: move `dragged` past `target` - after it when moving forward, before it when
    /// moving backward (always inserting AT the target's index made a forward drag onto the adjacent
    /// card a no-op). Returns whether the order actually changed, so the caller can gate haptics.
    @discardableResult
    func moveAccount(_ dragged: String, onto target: String, allIDs: [String]) -> Bool {
        let current = orderedAccountIDs(allIDs)
        guard dragged != target,
              let from = current.firstIndex(of: dragged),
              let to = current.firstIndex(of: target) else { return false }
        var order = current
        order.remove(at: from)
        guard let adjusted = order.firstIndex(of: target) else { return false }
        order.insert(dragged, at: min(from < to ? adjusted + 1 : adjusted, order.count))
        guard order != current else { return false }
        accountOrder = order
        return true
    }

    /// Drag-reorder INSIDE one provider's section (the grouped layout). Same reading as
    /// `moveAccount` - past the target when moving forward, before it when moving backward - but the
    /// result is written back through `applyProviderOrder`: the provider's slots in the global order
    /// keep their positions and only which sibling sits in which slot changes.
    ///
    /// A global move is wrong here twice over. It shifts the other providers' entries, and because
    /// the sections are ordered by each provider's FIRST appearance in the global order, a move past
    /// a foreign entry can swap two whole sections: `[Claude1, Codex1, Claude2, Codex2]` with
    /// Claude1 dropped on Claude2 became `[Codex1, Claude2, Claude1, Codex2]`, which put Codex's
    /// section above Claude's and silently rewrote the flat order the user would see again the
    /// moment grouping went back off (Codex review, 2026-08-02).
    ///
    /// A target from another provider returns false: sections own their cards, so a foreign card is
    /// no seat. That rule lives here rather than at the gesture, so it cannot be forgotten by a
    /// second caller.
    @discardableResult
    func moveAccountWithinProvider(_ dragged: String, onto target: String,
                                   siblingIDs: [String], allIDs: [String]) -> Bool {
        let siblings = Set(siblingIDs)
        guard siblings.contains(dragged), siblings.contains(target) else { return false }
        let current = orderedAccountIDs(allIDs).filter(siblings.contains)
        guard let from = current.firstIndex(of: dragged),
              let to = current.firstIndex(of: target) else { return false }
        var members = current
        members.remove(at: from)
        guard let adjusted = members.firstIndex(of: target) else { return false }
        members.insert(dragged, at: min(from < to ? adjusted + 1 : adjusted, members.count))
        guard members != current else { return false }
        applyProviderOrder(orderedProviderIDs: members, allIDs: allIDs)
        return true
    }

    /// Forget everything this store remembers about ONE account - the user removed it (its config
    /// home went to the Trash, see RemoveAccountAction).
    ///
    /// All four collections in one pass, through the value that names them together
    /// (`AccountSettingsTraces`), because an account id is derived from its config home's name: a
    /// later `~/.claude3` IS `claude:.claude3` again, and would inherit whatever this forgot.
    func forgetAccount(_ accountID: String) {
        let next = AccountSettingsTraces(labels: accountLabels, order: accountOrder,
                                         menuBarHidden: menuBarHiddenAccounts,
                                         disabled: disabledAccounts).forgetting(accountID)
        accountLabels = next.labels
        accountOrder = next.order
        menuBarHiddenAccounts = next.menuBarHidden
        disabledAccounts = next.disabled
    }

    /// The effective display label for an account (override or the provider default).
    func displayLabel(accountID: String, fallback: String) -> String {
        let override = accountLabels[accountID]?.trimmingCharacters(in: .whitespaces)
        return (override?.isEmpty == false) ? override! : fallback
    }
}
