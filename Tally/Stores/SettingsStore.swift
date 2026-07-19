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

    var isPanelTranslucent: Bool {
        didSet { UserDefaults.standard.set(isPanelTranslucent, forKey: "isPanelTranslucent") }
    }

    /// Reset instants as countdown vs exact time - toggled by clicking any reset label.
    var resetDisplay: ResetDisplay {
        didSet { UserDefaults.standard.set(resetDisplay.rawValue, forKey: "resetDisplay") }
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
        refreshIntervalMinutes = [1, 2, 5, 15].contains(interval) ? interval : 5
        languageOverride = AppLocale.override
        isUsagePanelPinned = defaults.bool(forKey: "isUsagePanelPinned")
        showFleetGauge = defaults.object(forKey: "showFleetGauge") as? Bool ?? true
        isPanelTranslucent = defaults.object(forKey: "isPanelTranslucent") as? Bool ?? true
        resetDisplay = ResetDisplay(rawValue: defaults.string(forKey: "resetDisplay") ?? "") ?? .relative
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

    /// The effective display label for an account (override or the provider default).
    func displayLabel(accountID: String, fallback: String) -> String {
        let override = accountLabels[accountID]?.trimmingCharacters(in: .whitespaces)
        return (override?.isEmpty == false) ? override! : fallback
    }
}
