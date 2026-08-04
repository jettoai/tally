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

    /// Providers whose account cards are folded away behind their fleet gauge (clicking the gauge
    /// row toggles it). A view gesture, not a Settings item: the collapse only takes effect while
    /// that provider's gauge is actually on screen, so cards can never become unreachable.
    var collapsedProviders: Set<String> {
        didSet { UserDefaults.standard.set(collapsedProviders.sorted(), forKey: "collapsedProviders") }
    }

    func toggleCollapsed(_ providerID: String) {
        if collapsedProviders.contains(providerID) {
            collapsedProviders.remove(providerID)
        } else {
            collapsedProviders.insert(providerID)
        }
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

    /// WHICH surface has its "View options" card open right now, nil when none has. Deliberately
    /// NOT persisted (no `didSet`, no key): it describes what is on screen this second, and a
    /// remembered copy would outlive the card it describes.
    ///
    /// It lives here rather than in the view because the thing that reads it is a window controller:
    /// every control in that card resizes the surface, and while it is open the surface holds its
    /// BOTTOM-RIGHT corner still so the control stays under the pointer between clicks (see
    /// `ResizeAnchor`).
    ///
    /// It names the host rather than answering yes/no, because two surfaces can be up at once: the
    /// menu-bar popover does not close the dashboard, so a card opened in the popover had the
    /// dashboard swapping corners too and jumping away under a layout change nobody made there.
    /// Only one card can be open, so one slot is still enough - it just has to say whose.
    private(set) var viewOptionsHost: SurfaceHost?

    /// Open or close the card for one surface. A close only clears the flag when THIS surface is the
    /// one holding it: a host going away (the popover closing behind the card) must not cancel the
    /// anchor another surface is still relying on.
    func setViewOptionsOpen(_ open: Bool, host: SurfaceHost) {
        if open { viewOptionsHost = host }
        else if viewOptionsHost == host { viewOptionsHost = nil }
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
            UsageStore.shared.republishSnapshot()  // the status line's fleet follows the same focus
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        enabledProviders = defaults.stringArray(forKey: "enabledProviders").map(Set.init)
            ?? Set(ProviderCatalog.descriptors.map(\.id))
        accountLabels = (defaults.dictionary(forKey: "accountLabels") as? [String: String]) ?? [:]
        accountOrder = defaults.stringArray(forKey: "accountOrder") ?? []
        menuBarHiddenAccounts = Set(defaults.stringArray(forKey: "menuBarHiddenAccounts") ?? [])
        disabledAccounts = Set(defaults.stringArray(forKey: "disabledAccounts") ?? [])
        displayMode = DisplayMode(rawValue: defaults.string(forKey: "displayMode") ?? "") ?? .remaining
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
        collapsedProviders = Set(defaults.stringArray(forKey: "collapsedProviders") ?? [])
        statuslineFullQuota = defaults.bool(forKey: "statuslineFullQuota")
        panelColumns = (1 ... 4).contains(defaults.integer(forKey: "panelColumns"))
            ? defaults.integer(forKey: "panelColumns") : 0
        panelDensity = PanelDensity(rawValue: defaults.string(forKey: "panelDensity") ?? "") ?? .cards
        // Clamped into the range the picker still offers: the list used to go up to four, and a
        // machine that stored one has to come back to the highest count that still exists rather
        // than to a number no tile can select. Anything else reads as auto.
        let storedListColumns = defaults.integer(forKey: "listColumns")
        listColumns = storedListColumns > 0
            ? min(storedListColumns, SettingsStore.maxListColumns) : 0
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
