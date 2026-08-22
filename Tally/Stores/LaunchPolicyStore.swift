import Foundation
import Observation

/// Which account new CLI sessions launch on, per provider - the USER-INTENT half of the app↔CLI
/// contract, published to `~/.tally/state.json`. The facts half is `UsageSnapshot` (usage numbers,
/// app → CLI, read-only); this file carries choices (UI writes, the `tally` CLI reads on every
/// launch). Separate files so the two writers never race over one document.
///
/// Modes, per provider:
/// - `off`     - observe only: Tally never steers a launch (a dashboard, nothing more), and never
///               moves a RUNNING session between accounts either - no cap handoff, no rebalance,
///               no repick when a window closes, no move at a `tally session clear`. The supervisor
///               still runs everything that is not an account decision (the status line, the board,
///               `tally session send`, the model follow, self-update). Asking `tally claude` for a
///               launch is still an explicit ask and still picks; what off forbids is the choices
///               nobody asked for. The CLI end is TallyCLI/AutoSteering.swift, which lists every
///               mover this reaches.
/// - `manual`  - the user pinned one account (clicking a card in the panel); every launch uses it.
/// - `auto`    - every launch picks the account with the most proven headroom at that moment.
@MainActor
@Observable
final class LaunchPolicyStore {
    enum Mode: String, Codable, CaseIterable { case off, manual, auto }

    /// Claude Code permission mode injected at launch ("default" injects nothing). User-typed
    /// permission flags always win over this setting.
    enum PermissionMode: String, Codable, CaseIterable {
        case standard = "default", plan, acceptEdits, bypass
    }

    struct ProviderPolicy: Codable, Equatable {
        var mode: Mode = .auto
        /// The pinned account (manual mode): id for the UI, launch home denormalized alongside so
        /// the CLI can still launch it even when the account drops out of the snapshot briefly.
        var pinnedAccountID: String?
        var pinnedHome: String?
        var permissionMode: PermissionMode?
        /// "continue" = bare launches resume the directory's latest conversation (escape hatch:
        /// `tally claude --new`). nil = start fresh, the CLI's own default.
        var startMode: String?
        /// Launch defaults appended by the tally launcher; nil = inject nothing. Free text for
        /// model names (they drift too fast for a hard-coded picker).
        var model: String?
        var fallbackModel: String?
        var effort: String?
        /// Fallback pairing, applied by the supervisor ONLY after the session's actual model
        /// has degraded to the fallback: a weaker model can deserve a different depth and flags.
        var fallbackEffort: String?
        var fallbackArgs: String?
    }

    static let shared = LaunchPolicyStore()
    static let fileURL = UsageSnapshot.directory.appendingPathComponent("state.json")

    private struct StateFile: Codable {
        var version = 1
        var launch: [String: ProviderPolicy]
        /// The account artifacts are published from. TOP LEVEL rather than inside a provider's
        /// policy, because it is not a launch decision: it says which Claude account the person at
        /// this machine is signed into in their BROWSER, which is the one fact a session cannot see
        /// and the one the Artifact guard compares against (Tally/Core/ArtifactHookContract.swift).
        ///
        /// Optional, and the schema only ever GAINS keys: `version` does not move, a supervisor
        /// from an older build decodes this document exactly as it did before, and a state file
        /// written before this key existed simply has no answer here.
        var artifactAccount: String?
        /// Per-account settings, keyed by config home: which account the person browses on, and how
        /// much of its quota Tally's own choices must leave them (Tally/Core/AccountReserve.swift).
        ///
        /// TOP LEVEL and keyed by HOME for the same two reasons the field above is: it is not a
        /// launch decision, and the thing it names is a directory rather than an account id. Added
        /// under the same only-ever-gains-keys rule, and omitted entirely while it holds nothing, so
        /// a machine that never marked an account writes the document it always wrote.
        var accounts: [String: AccountRoleSetting]?
    }

    private(set) var policies: [String: ProviderPolicy]

    /// The Claude config home artifacts are published from.
    ///
    /// THREE STATES IN ONE OPTIONAL, and the third is the one this used to lose:
    ///
    ///   - nil        - NOBODY HAS ANSWERED. The CLI abstains (the guard is a convenience rather
    ///                  than a gate, so a machine that has never named an account is never told it
    ///                  may not publish), and an install may seed it (`artifactAccountSeed`).
    ///   - ""         - ANSWERED, AND THE ANSWER IS "NOT CHOSEN". The CLI abstains on it
    ///                  (`artifactAccountHome("")` names no home), and an install no longer
    ///                  re-guesses over it. Picking "Not chosen" in the row used to store nil, which
    ///                  is why the next install, auto-follow pass or repair silently chose an
    ///                  account again. NOT the same reading as the absent key any more: absent falls
    ///                  back to the account marked personal, and this answer is one that fallback
    ///                  may not overrule (TallyCLI/HookArtifact.swift, `artifactAccountSetting`).
    ///   - a home     - the account the user named.
    private(set) var artifactAccount: String?

    /// Per-account settings, keyed by config home (Tally/Core/AccountReserve.swift): which account
    /// the user browses claude.ai on, and the slice of its quota Tally's own choices must leave
    /// standing. Empty on a machine where nobody has marked one, which is most of them.
    private(set) var accountSettings: [String: AccountRoleSetting]

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let file = try? JSONDecoder().decode(StateFile.self, from: data) {
            policies = file.launch
            artifactAccount = file.artifactAccount
            accountSettings = file.accounts ?? [:]
        } else {
            policies = [:]
            accountSettings = [:]
        }
    }

    /// Factory defaults for a provider the user has never configured (Albert's call, 2026-07-20):
    /// the target user runs several paid accounts hard, so bare launches continue the last
    /// conversation without permission prompts, on the flagship tier with a deep-reasoning
    /// fallback pairing. "fable" / "opus" are stable aliases (tier 1 / tier 2); "ultracode" is
    /// accepted by `claude --effort` even though its help enum omits it (parse-verified on
    /// 2.1.215). The first user edit persists an entry and wins forever after.
    static func factoryDefault(_ providerID: String) -> ProviderPolicy {
        var policy = ProviderPolicy()
        policy.permissionMode = .bypass
        policy.startMode = "continue"
        if providerID == "claude" {
            policy.model = "fable"
            policy.effort = "high"
            policy.fallbackModel = "opus"
            policy.fallbackEffort = "ultracode"
        } else {
            policy.model = "gpt-5.6-sol"   // tier 1, same rationale as fable above
            policy.effort = "xhigh"
        }
        return policy
    }

    func policy(_ providerID: String) -> ProviderPolicy {
        policies[providerID] ?? Self.factoryDefault(providerID)
    }

    func mode(_ providerID: String) -> Mode { policy(providerID).mode }

    func setMode(_ providerID: String, _ mode: Mode) {
        var updated = policy(providerID)
        updated.mode = mode
        policies[providerID] = updated
        persist()
    }

    func setPermissionMode(_ providerID: String, _ mode: PermissionMode) {
        var updated = policy(providerID)
        updated.permissionMode = mode == .standard ? nil : mode
        policies[providerID] = updated
        persist()
    }

    /// Generic launch-default setter: empty/whitespace collapses to nil (= inject nothing).
    func setLaunchDefault(_ providerID: String, _ keyPath: WritableKeyPath<ProviderPolicy, String?>,
                          _ value: String?) {
        var updated = policy(providerID)
        let trimmed = value?.trimmingCharacters(in: .whitespaces)
        updated[keyPath: keyPath] = (trimmed?.isEmpty == false) ? trimmed : nil
        policies[providerID] = updated
        persist()
    }

    /// Write the model+effort pair in ONE persist, so a running session's follow sees a single
    /// atomic change rather than two writes seconds apart (model, then effort) that the supervisor
    /// had to debounce. The Settings row stages both and calls this once on Apply. Empty/whitespace
    /// collapses to nil, same rule as `setLaunchDefault`.
    func setLaunchPair(_ providerID: String, model: String?, effort: String?) {
        func clean(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespaces)
            return (trimmed?.isEmpty == false) ? trimmed : nil
        }
        var updated = policy(providerID)
        updated.model = clean(model)
        updated.effort = clean(effort)
        policies[providerID] = updated
        persist()
    }

    /// Name the account artifacts are published from - or say, in as many words, that none is
    /// chosen.
    ///
    /// EMPTY IS STORED RATHER THAN COLLAPSED TO NIL, which is the opposite of `setLaunchDefault`'s
    /// rule and deliberately so. Every caller of this is somebody ANSWERING: the row's picker, and
    /// the install seeding a first answer. "Not chosen" is one of the answers that picker offers -
    /// it is how a person turns the checking off without removing the hook - and stored as nil it
    /// was indistinguishable from never having been asked, so the next install seeded an account
    /// over it and the guard started refusing publishes the user had just switched off.
    func setArtifactAccount(_ home: String?) {
        artifactAccount = home?.trimmingCharacters(in: .whitespaces) ?? ""
        persist()
    }

    // MARK: The personal account and its reserve

    /// The config home the user browses claude.ai on, or nil while nobody has marked one.
    var personalAccountHome: String? { AccountRoles.personalHome(accountSettings) }

    func isPersonalAccount(home: String?) -> Bool {
        AccountRoles.isPersonal(accountSettings, home: home)
    }

    /// The slice of that account's quota Tally's own choices must leave standing, 0 by default.
    func reserve(home: String?) -> Int { AccountRoles.reserve(accountSettings, home: home) }

    /// Mark one account as the personal one (single select), or nil to unmark whichever holds it.
    ///
    /// AND THE ARTIFACT SETTING FOLLOWS IT, in that direction only. The two questions have one
    /// answer - which account is this machine's browser signed into - so marking it here is also
    /// answering the Integrations row, and leaving that row alone would mean marking an account as
    /// personal and having artifacts keep publishing from another one.
    ///
    /// UNMARKING DOES NOT CLEAR IT, which is the asymmetry `removeArtifactHook` states about its own
    /// press: the publishing account is a setting the user gave, the row that shows it is still
    /// there, and a reserve going away is no reason to start refusing to say where artifacts come
    /// from. Nor does choosing another account in that row move this marking: this one steers
    /// launches, and quietly restyling somebody's launch policy from an Integrations picker would be
    /// a surprise in the direction that costs quota.
    func setPersonalAccount(_ home: String?) {
        accountSettings = AccountRoles.settingPersonal(accountSettings, home: home)
        if let chosen = AccountRoles.personalHome(accountSettings) { artifactAccount = chosen }
        persist()
    }

    /// Set that account's reserve (0-100, clamped). A no-op for an account that is not the marked
    /// one - the rule and its reason live with the reserve itself (AccountReserve.swift).
    func setReserve(_ home: String?, _ percent: Int) {
        accountSettings = AccountRoles.settingReserve(accountSettings, home: home, percent: percent)
        persist()
    }

    /// Pin one account (and switch the provider to manual - pinning IS choosing manual).
    /// Mutates in place so unrelated settings (e.g. permission mode) survive the click.
    func pin(_ providerID: String, accountID: String, home: String?) {
        var updated = policy(providerID)
        updated.mode = .manual
        updated.pinnedAccountID = accountID
        updated.pinnedHome = home
        policies[providerID] = updated
        persist()
    }

    /// Let go of the denormalized launch home of any pin whose account has gone DORMANT (signed out
    /// with its config home still on disk).
    ///
    /// The home is the half the CLI can act on without asking anything: `pinnedHome` is published so
    /// a pin survives its account briefly dropping out of the snapshot, so a stale one kept `tally`
    /// exec'ing a signed-out config dir long after the panel stopped offering the pin (2026-08-03).
    /// The launcher ignores it too (`pinnedLaunchHome`, TallyCLI/AccountPick.swift) - both halves,
    /// because either alone still leaves a version of the pair that launches a dormant home.
    ///
    /// The pinned ID deliberately STAYS: the pin is the user's choice, and renewing the login makes
    /// it steer launches again with no second click. And this is driven by a POSITIVE fact (this
    /// account exists and is dormant), never by absence - a discovery hiccup must not silently
    /// rewrite what the user chose.
    func releasePinnedHome(dormant: Set<String>) {
        guard !dormant.isEmpty else { return }
        var changed = false
        for (providerID, policy) in policies where policy.pinnedHome != nil {
            guard let pinnedID = policy.pinnedAccountID, dormant.contains(pinnedID) else { continue }
            var updated = policy
            updated.pinnedHome = nil
            policies[providerID] = updated
            changed = true
        }
        if changed { persist() }
    }

    /// Drop a pin whose account has been REMOVED (its config home is in the Trash).
    ///
    /// Both halves go, unlike `releasePinnedHome` above: that one keeps the id because a signed-out
    /// account can be renewed and should steer launches again with no second click, while this one
    /// is about an account that no longer exists. Manual mode goes back to Smart with it - manual
    /// with nothing pinned is a provider whose launches are steered by an id that resolves to
    /// nothing.
    func forget(accountID: String, home: String) {
        // THE ARTIFACT ACCOUNT IS STORED AS A HOME, so the id above cannot reach it: it is the one
        // setting here that names a directory rather than an account, and a removal that left it
        // standing pointed the guard at a config home in the Trash. What that costs is not a stale
        // string - it is every publish on the machine refused, with an instruction to move to a
        // folder that is gone, and a later `~/.claude3` silently inheriting the choice (codex review
        // of 7113edc). The CLI carries its own defence for the versions that do not do this
        // (`artifactAccountStanding`); this is the one that keeps the file honest.
        artifactAccount = Self.artifactAccountAfterRemoving(artifactAccount, home: home)
        // …and its neighbour, keyed by that same directory and reachable no other way: the personal
        // marking and the reserve under it. Left standing, they name a folder in the Trash as the
        // account this machine browses on, hold quota back on nothing, and hand the role plus a
        // number nobody chose to the next `~/.claudeN` created in that slot.
        accountSettings = AccountRoles.removingHome(accountSettings, home: home)
        for (providerID, policy) in policies where policy.pinnedAccountID == accountID {
            var updated = policy
            updated.pinnedAccountID = nil
            updated.pinnedHome = nil
            if updated.mode == .manual { updated.mode = .auto }
            policies[providerID] = updated
        }
        // Written whether or not a PIN moved: the account being removed is frequently not the pinned
        // one, and a clearing that only reached the disk when something else also changed is a
        // clearing that survives in memory and nowhere else.
        persist()
    }

    /// The Artifact publishing account after a config home has been removed: nil when that home IS
    /// the chosen one, and the choice untouched otherwise.
    ///
    /// Compared through `artifactAccountHome`, the same normalization the CLI compares with, so a
    /// choice stored with a trailing slash or through a symlink is still recognised as the home
    /// being removed. Text rather than a filesystem identity read because by the time this is asked
    /// the directory has already gone to the Trash (`artifactAccountHome` states it in full).
    ///
    /// Pure, so the rule is assertable without a state file to write into.
    static func artifactAccountAfterRemoving(_ current: String?, home: String) -> String? {
        guard let current, let removed = artifactAccountHome(home),
              artifactAccountHome(current) == removed else { return current }
        return nil
    }

    func isPinned(_ accountID: String, providerID: String) -> Bool {
        let p = policy(providerID)
        return p.mode == .manual && p.pinnedAccountID == accountID
    }

    private func persist() {
        // A build nobody installed edits its policies in memory only (the UI stays testable) but
        // never publishes: ~/.tally/state.json is what the CLI steers real launches by, and that
        // contract belongs to the installed release app alone. The dev variant is one such build; a
        // locally built Release is the other, and it would pin the user's real launches to whichever
        // account a test window happened to select (`isUnshipped`).
        guard !BuildVariant.isUnshipped else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // The per-account block is omitted while it holds nothing rather than written as an empty
        // object: a machine where nobody has marked an account publishes exactly the document every
        // previous build published.
        guard let data = try? encoder.encode(
            StateFile(launch: policies, artifactAccount: artifactAccount,
                      accounts: accountSettings.isEmpty ? nil : accountSettings))
        else { return }
        try? FileManager.default.createDirectory(at: UsageSnapshot.directory,
                                                 withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    // MARK: Auto-pick preview

    /// The account auto mode would launch right now - the same rule as the CLI's `launchPick()`
    /// (burn-rate scoring; capped/stale/errored/quarantined accounts are out), so the panel's
    /// badge always predicts what `tally` will actually do.
    /// Mirror of the CLI's `smartPickMargin` / `smartPickMinGain` - keep in lockstep.
    /// Two gates: the ratio alone lies at the low end (2% vs 3% remaining reads as +50%), so a
    /// challenger must also win by an absolute rate gain or nearly-drained siblings ping-pong.
    private static let smartPickMargin = 1.15
    private static let smartPickMinGain = 0.05   // %/h

    /// How long a quarantine read is reused. `autoPickID` runs inside a SwiftUI body (once per
    /// account card, on every redraw) and the records are files, so reading them straight would
    /// put a directory scan plus a read per record on the render path. Missing a cap for a few
    /// seconds costs nothing: the badge is a prediction that redraws continuously, and the
    /// launcher itself never uses this cache - it reads the records fresh on every launch.
    private static let quarantineCacheTTL: TimeInterval = 5

    /// Kept out of the observation graph on purpose: a body that mutated observed state would
    /// invalidate the view it is drawing.
    @ObservationIgnored
    private var quarantineCache: (model: String?, readAt: Date, accounts: Set<String>)?

    private func quarantinedNow(primaryModel: String?, now: Date) -> Set<String> {
        if let cache = quarantineCache, cache.model == primaryModel,
           now.timeIntervalSince(cache.readAt) < Self.quarantineCacheTTL, cache.readAt <= now {
            return cache.accounts
        }
        let live = quarantinedAccounts(forPrimary: primaryModel, now: now)
        quarantineCache = (primaryModel, now, live)
        return live
    }

    /// The badge the panel shows. Two steps, exactly as the launcher picks (`launchPick` on the
    /// CLI side): the cap quarantine is applied first, and when it empties the field the
    /// unfiltered pick is shown rather than no badge at all, because that is the account a launch
    /// would still land on. The app had no notion of quarantine until 2026-07-26; on 2026-07-25
    /// the badge sat on a quarantined account and its reader concluded the picker was broken.
    ///
    /// `reserves` is percentage points held back per ACCOUNT ID, which is the shape this side of the
    /// contract holds: the CLI joins the state file's homes onto the snapshot's accounts, and the
    /// panel already knows which card is which (`PersonalAccount.reserves`). Empty is the ordinary
    /// answer and computes exactly what this function computed before the feature existed. A launch
    /// this badge predicts is Tally's OWN choice, so it always weighs them - the paths a person names
    /// an account on (a pin, `tally claude --account X`) do not come through here at all.
    func autoPickID(providerID: String, accounts: [AccountUsage], launchable: Set<String>,
                    reserves: [String: Double] = [:], now: Date = Date()) -> String? {
        let excluded = quarantinedNow(primaryModel: policy(providerID).model, now: now)
        return autoPickID(providerID: providerID, accounts: accounts, launchable: launchable,
                          reserves: reserves, excluding: excluded, now: now)
            ?? autoPickID(providerID: providerID, accounts: accounts, launchable: launchable,
                          reserves: reserves, excluding: [], now: now)
    }

    private func autoPickID(providerID: String, accounts: [AccountUsage], launchable: Set<String>,
                            reserves: [String: Double], excluding: Set<String>,
                            now: Date) -> String? {
        let primary = policy(providerID).model
        // The CLI's nearly-dry gate, from the file both targets compile (AccountComfort.swift):
        // the badge has to predict the launch, so the same accounts leave before the ordering.
        //
        // `lastRefreshFailed` is in that predicate for the reason `accountIsSpent` gives about its
        // own (TallyCLI/AccountPick.swift): `isStale` waits for a SECOND consecutive failure so the
        // "Outdated" badge cannot flicker on a token rotation, which leaves a whole poll interval in
        // which held-over numbers are published looking freshly fetched. Deciding eligibility on
        // those is deciding it on a reading nobody confirmed - and the badge that results is not the
        // account `tally` would launch, which is the one promise this function makes. Mirror of the
        // CLI's `eligible`; keep both sides in lockstep.
        let eligibleAccounts = accounts.filter {
            $0.providerID == providerID && $0.error == nil && !$0.isStale
                && !$0.lastRefreshFailed
                && launchable.contains($0.id) && !excluding.contains($0.id)
                && (Self.headroom($0, primaryModel: primary) ?? -1) > 0
        }
        // WHEN NOBODY IS ABOVE THEIR OWN LINE THE RESERVES GO, exactly as `best` drops them for that
        // one pick (TallyCLI/AccountPick.swift): a launch has nowhere else to go, so it spends into
        // a reserve and says so on stderr - and a badge that showed no pick, or a different one,
        // would be predicting a launch that is not the one about to happen. Unreachable on a fleet
        // where nobody marked an account: an eligible account has every window above zero, so it is
        // above a reserve of zero by definition.
        let reserves = eligibleAccounts.contains {
            Self.aboveReserve($0, primaryModel: primary, reserve: reserves[$0.id] ?? 0, now: now)
        } ? reserves : [:]
        let candidates = preferringComfortable(eligibleAccounts, now: now) {
            Self.comfortWindows($0, primaryModel: primary, reserve: reserves[$0.id] ?? 0, now: now)
        }
        guard var leader = candidates.first else { return nil }
        var leaderScore = Self.smartScore(leader, primaryModel: primary,
                                          reserve: reserves[leader.id] ?? 0, now: now)
        for candidate in candidates.dropFirst() {
            let score = Self.smartScore(candidate, primaryModel: primary,
                                        reserve: reserves[candidate.id] ?? 0, now: now)
            if score > leaderScore * Self.smartPickMargin,
               score > leaderScore + Self.smartPickMinGain {
                leader = candidate
                leaderScore = score
            } else if score >= leaderScore,
                      (candidate.resetCreditsAvailable ?? 0) > (leader.resetCreditsAvailable ?? 0) {
                // Mirror of the CLI's near-tie tie-breaker: a wall with banked resets behind
                // it is softer. Reads the count only; never spends.
                leader = candidate
                leaderScore = score
            }
        }
        return leader.id
    }
}
