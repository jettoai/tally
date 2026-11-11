import Foundation

/// The bookkeeping behind ClaudeResetInventoryStore: which reading each account holds, when it was
/// last asked, and which answer still counts. Foundation only, so the inventory suite runs it.
///
/// A READING BELONGS TO A LOGIN, NOT TO A FOLDER. Accounts are keyed by config home, and one home
/// can be signed out of A and into B. So a reading is dropped, and its cadence reset, when the home
/// changes hands: a login landing or renewing there (`invalidate`), or the home's
/// `oauthAccount.accountUuid` naming someone else than the reading was taken under. Every request
/// carries the generation it left under; one that comes back after the home changed hands asked
/// with the old login's token and is thrown away.
///
/// The login's identity is kept in memory only, to compare. Never logged, printed or published.
struct ClaudeResetInventoryLedger {
    struct Entry: Equatable {
        var inventory: ClaudeResetInventory
        /// When this inventory was read, which stays put while later attempts fail.
        var checkedAt: Date
        /// The latest attempt failed, so this is the last good reading held over.
        var isStale: Bool
        /// The `oauthAccount.accountUuid` the home named when this was read; nil when it named nobody.
        fileprivate(set) var identity: String?
    }

    private(set) var entries: [String: Entry] = [:]
    private var attemptedAt: [String: Date] = [:]
    /// Account -> generation of the request out for it.
    private var inFlight: [String: Int] = [:]
    private var generations: [String: Int] = [:]
    private var known: Set<String> = []

    /// Forgets every account no longer in `known`; a request out for one is ignored when it lands.
    mutating func prune(known: Set<String>) {
        self.known = known
        if entries.keys.contains(where: { !known.contains($0) }) {
            entries = entries.filter { known.contains($0.key) }
        }
        attemptedAt = attemptedAt.filter { known.contains($0.key) }
    }

    /// The generation to send a request under, or nil when one is already out or the last one left
    /// less than `wait` ago.
    mutating func begin(_ id: String, now: Date, wait: TimeInterval) -> Int? {
        guard inFlight[id] == nil else { return nil }
        if let last = attemptedAt[id], now.timeIntervalSince(last) < wait { return nil }
        attemptedAt[id] = now
        let generation = generations[id, default: 0]
        inFlight[id] = generation
        return generation
    }

    /// The home changed hands: its reading goes, the next round asks at once, and a request already
    /// out is disowned. True when a reading was dropped.
    @discardableResult
    mutating func invalidate(_ id: String) -> Bool {
        generations[id, default: 0] += 1
        inFlight[id] = nil
        attemptedAt[id] = nil
        return entries.removeValue(forKey: id) != nil
    }

    /// What the home's config names now. Only two different names count as a change: a config
    /// read that found nobody (a login half written, a file mid-rewrite) says nothing either way.
    @discardableResult
    mutating func note(_ id: String, identity: String?) -> Bool {
        guard let held = entries[id]?.identity, let identity, held != identity else { return false }
        return invalidate(id)
    }

    /// Takes an answer in. False when it is not this generation's (the home changed hands while it
    /// was out) or the account is gone, and then nothing changed.
    mutating func land(_ id: String, generation: Int, outcome: ClaudeResetInventoryFetch.Outcome,
                       identity: String?, now: Date) -> Bool {
        guard generations[id, default: 0] == generation else { return false }
        inFlight[id] = nil
        guard known.contains(id) else { return false }
        switch outcome {
        case .read(let inventory):
            entries[id] = Entry(inventory: inventory, checkedAt: now, isStale: false, identity: identity)
        case .noCredential, .failed:
            // A failed read under another login does not keep the last one's reading on show.
            if let held = entries[id]?.identity, let identity, held != identity {
                entries[id] = nil
            } else {
                entries[id]?.isStale = true
            }
        }
        return true
    }
}
