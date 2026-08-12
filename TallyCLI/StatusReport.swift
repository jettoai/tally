import Foundation

// MARK: - Machine-readable status (`tally status --json`)

/// The public contract behind `tally status --json`: the surface users script against from
/// hooks, status lines, and agent skills, so its shape is versioned and additive-only (fields
/// may appear in later versions, never vanish or change meaning). Account fields mirror the
/// snapshot's names on purpose; `best` and `pinned` add the one thing only the CLI knows:
/// which account a launch would actually land on right now.
struct StatusReport: Encodable {
    struct Account: Encodable {
        var id: String
        var provider: String
        var label: String
        var launchHome: String?
        /// The account `tally claude` / `tally codex` would launch right now (pin honoured);
        /// the JSON twin of the human output's arrow marker. At most one per provider, and
        /// none when no account is eligible.
        var best: Bool
        /// Manually pinned in the app (Settings, Launch account).
        var pinned: Bool
        var isStale: Bool
        var error: String?
        var sessionRemaining: Double?
        var sessionResetsAt: Date?
        var weeklyRemaining: Double?
        var weeklyResetsAt: Date?
        var modelWindowName: String?
        var modelRemaining: Double?
        var modelResetsAt: Date?
        var resetCreditsAvailable: Int?
        /// The size of the largest conversation a supervisor is running on this account right now,
        /// measured at its newest turn and including that turn's own answer: what a resume there
        /// would reload before doing anything at all (SessionContext.swift). Absent when no
        /// supervised session is on the account, which is
        /// the ordinary case for an idle machine - so a script tests for the key rather than
        /// reading a 0 as an empty conversation.
        var sessionContextTokens: Int?
        /// What that same session was told to RUN, when a `tally model` pinned it (SessionModel.swift).
        /// Absent when it follows this project's profile and the fleet default, which is where every
        /// session starts - so, like the reading above, a script tests for the key. The two describe
        /// ONE session (the largest conversation on the account), never a mixture of several.
        var sessionModel: String?
        var sessionEffort: String?
    }

    /// Version of THIS output contract, independent of the snapshot file's internal version.
    var version = 1
    var generatedAt: Date
    /// True when the snapshot is older than the CLI trusts (the app is probably not running).
    var stale: Bool
    var accounts: [Account]
    /// The pooled cross-account view, passed through from the snapshot as-is: `fleet` is the
    /// headline pool per provider, `fleetPools` the panel's ordered pool list (leading pool
    /// first, e.g. a Fable pool ahead of the weekly pool). Present only while the app's fleet
    /// gauge is on and the provider has 2+ accounts. Units: one account's full weekly = 100.
    var fleet: [String: Snapshot.Fleet]?
    var fleetPools: [String: [Snapshot.Fleet]]?
    /// The usage advisor's per-provider verdict, computed from the burn-rate history the app
    /// records (never from the snapshot). Present only when there is any history; absent below
    /// the collecting threshold is impossible - a young reading is emitted with `verdict:
    /// "collecting"`. English headline; the numbers behind it let scripts phrase their own.
    var advisor: [String: Advisor]?
    /// Every supervised session running on this machine, across every account, oldest first.
    ///
    /// THE ACCOUNT BLOCK ANSWERS A DIFFERENT QUESTION and keeps a different number of sessions.
    /// `sessionContextTokens` and the pair beside it describe ONE session per account (the largest
    /// conversation on it), because what they are asked is "what would a resume here cost". This
    /// list is asked "which sessions are running, and where do I reach that one", so it drops
    /// nothing: ten sessions on two accounts are ten entries here and two readings up there.
    ///
    /// ALWAYS PUBLISHED, empty list and all, unlike the optional blocks around it. Absence has to
    /// keep meaning "this Tally is too old to answer", because a reader that cannot tell that from
    /// "nothing is running" falls back to its slower channel for the wrong reason and never learns
    /// it was asking the wrong version.
    var sessions: [Session]
    /// The per-project launch profile in force for the directory this command ran in
    /// (`tally project`, ProjectPolicy.swift), absent when that directory declares none. Present
    /// here because it changes what the rest of this report MEANS: an account marked `best` under a
    /// project that declares opus was scored on opus, and a reader that quotes the arrow without
    /// knowing that cannot explain why the Fable-drained account won.
    var projectPolicy: ProjectProfile?

    struct ProjectProfile: Encodable {
        struct Overrides: Encodable {
            var model: String?
            var effort: String?
            var accountID: String?
        }

        /// The project the profile is keyed by: the main repo's working tree, so every worktree of
        /// it reports the same path here.
        var path: String
        /// Provider id → the axes that project overrides. Only providers with a profile appear.
        var providers: [String: Overrides]
    }

    /// One account's live session as this report describes it. A value type rather than three
    /// parallel dictionaries because the fields are one session's: a caller that assembled them
    /// separately could publish one session's token count beside another's pinned model.
    struct SessionSummary: Equatable {
        var contextTokens: Int
        /// Optional, so the synthesised memberwise initialiser defaults them: a caller with only a
        /// token count writes `.init(contextTokens:)`, which is every session that pinned nothing.
        var model: String?
        var effort: String?
    }

    /// One running session: which account it is on, which project it is in, and how to reach it.
    ///
    /// WHAT THIS BLOCK IS FOR. Claude Code partitions the roster sessions publish about each other
    /// by config home (`$CLAUDE_CONFIG_DIR/sessions/`), so two sessions on two accounts are
    /// invisible to one another, while the sockets they listen on all sit in one machine-wide
    /// directory (MessagingSocket.swift). Tally supervises every account, so it can answer what
    /// neither session can ask: which conversations are open, where, and at which address. A caller
    /// looks its project up here and talks to the pid it finds.
    struct Session: Encodable {
        /// The account this session is running on right now, rewritten by a handoff. The join back
        /// to the `accounts` block above, which is where its quota lives. Absent only from a
        /// supervisor too old to have published one at its spawn AND whose conversation has not had
        /// a turn yet: an entry with no account is still a session that is running, and dropping it
        /// would be the roster losing the sessions that just started (SwitchRequest.swift).
        var accountID: String?
        /// The Claude Code process itself, not the Tally supervising it. Absent when it cannot be
        /// proved: the pid is published at spawn and read back only while that process is alive and
        /// still a child of that supervisor, so what is here is a running Claude Code rather than a
        /// number that was one (SwitchRequest.swift).
        var pid: Int?
        /// The directory the session was launched in, fully resolved: the exact checkout, so two
        /// parallel lines of one repository are told apart (a worktree keeps its own inbox, and a
        /// message meant for the line is not a message for the trunk). Absent from a supervisor too
        /// old to have published one.
        var directory: String?
        /// The same session at repository grain: the MAIN repo's working tree, which every parallel
        /// line of it reports identically. In the currency `projectPolicy.path` is written in
        /// (ProjectPolicy.swift), on purpose, so the two blocks can be matched without a second
        /// notion of what a project is. Equal to `directory` when this checkout IS the main one, and
        /// for a directory that is not a repository at all.
        var project: String?
        /// The parallel line's own name (`tally worktree` lands them as `<repo>-<branch>`, and this
        /// is what is left after the repository's name is taken off), or absent when the session is
        /// on the trunk. Named by the one rule the pick panel names them by (`pickProject`).
        var worktree: String?
        /// The unix socket that Claude Code is listening on, published ONLY while a socket is really
        /// there (MessagingSocket.swift). Absent means "not addressable this way": the reader falls
        /// back to whatever file-level channel it has rather than dialling an address nothing is
        /// behind, which is what keeps this field honest across a Claude Code that changes where it
        /// listens.
        var messagingSocket: String?
        /// What this session is doing right now: `working`, `blocked` (Claude Code has asked for
        /// something and nobody has answered), `idle`, or `unknown` (running, with nothing to say
        /// about it yet). Decided by the supervisor, which is the only process that can
        /// (SessionState.swift).
        ///
        /// ABSENT IS NOT `unknown`. The word means "this session cannot say", where absence means
        /// "this TALLY cannot say" - a supervisor from a build before the board shipped publishes
        /// nothing here while running perfectly well, and a reader that collapsed the two would
        /// report a whole class of live sessions as blank rather than as unanswered.
        var state: String?
        /// When it entered that state, so a reader can age the wait rather than the poll. Absent on
        /// the same terms as the word beside it, and always present when that word is.
        var stateSince: Date?
    }

    struct Advisor: Encodable {
        var headline: String
        var verdict: String
        var demandPerWeek: Double
        /// `demandPerWeek` split by the plan each account is on, largest first, and always summing
        /// back to it. A snapshot that names no plan (an older app) yields ONE tier carrying the
        /// whole figure with its `plan` key absent rather than an empty list, so a reader can
        /// always sum this array; a single tier naming no plan is the signal that there is nothing
        /// to split by. Empty only when there are no weekly samples at all.
        var tierDemands: [Tier]
        var activeBurnPerHour: Double
        var starvedHoursPerWeek: Double
        var daysOfData: Double

        struct Tier: Encodable {
            /// nil for the accounts whose plan the snapshot does not name, which the synthesized
            /// encoding writes as no key at all rather than as a null (the house rule the whole
            /// report follows, pinned by "nil fields are omitted, not null" in tests/statusjson).
            var plan: String?
            var demandPerWeek: Double
            var accountCount: Int
        }
    }
}

/// The two markers a status row can carry, for one provider's accounts: `best` is the account a
/// launch would land on right now (the human output's `→`, the JSON's `best`), `pinned` the manual
/// pin that is still honoured (the `(pinned)` suffix, the JSON's `pinned`). Either can be nil.
///
/// ONE resolver for both output shapes, because they are the same claim in two typefaces and a
/// disagreement between them is a bug the reader has no way to adjudicate. `tally status` printed
/// `→ … (pinned)` on a signed-out account long after `runLaunch` had stopped honouring that pin,
/// because the text path compared `pinnedAccountID` on its own while the JSON asked the shared
/// resolver (2026-08-03). Mirrors runLaunch's chain exactly: pinned account id (the launch target
/// even when capped, "launching anyway") → the denormalized home (a pin whose account transiently
/// vanished from the snapshot still launches by home; when a listed account owns that home it IS
/// the target, otherwise the launch lands outside this list and nobody gets the marker) → the
/// headroom pick. A provider this CLI cannot launch gets no pick at all: `best` means "would
/// launch".
func launchMarkers(providerID: String, in snapshot: Snapshot, policy: LaunchPolicy,
                   quarantined: Set<String>, now: Date = Date()) -> (best: String?, pinned: String?) {
    guard providers.contains(where: { $0.id == providerID }) else { return (nil, nil) }
    func headroomPick() -> String? {
        launchPick(providerID: providerID, in: snapshot, primaryModel: policy.model,
                   quarantined: quarantined, now: now)?.id
    }
    guard policy.mode == "manual" else { return (headroomPick(), nil) }
    let mine = snapshot.accounts.filter { $0.provider == providerID }
    // Asked through the launcher's own resolver, so a pin it has stopped honouring (the account
    // signed out) falls through to the headroom pick here exactly as it does there.
    let pinnedHome = pinnedLaunchHome(snapshot, policy: policy)
    let pinnedID = (mine.first { $0.id == policy.pinnedAccountID && $0.launchHome != nil }
        ?? pinnedHome.flatMap { home in mine.first { $0.launchHome == home } })?.id
    if let pinnedID { return (pinnedID, pinnedID) }
    // A pin that launches a home outside this list: nobody here gets the marker.
    if pinnedHome != nil { return (nil, nil) }
    return (headroomPick(), nil)
}

/// `quarantined` is the live cap quarantine per provider (Quarantine.swift). It is a parameter
/// rather than a file read so the report stays a pure function, but callers must pass it: `best`
/// promises "would launch", and a report that named an account the launcher is currently skipping
/// would be a lie scripts act on.
/// `accountSessions` is the live reading per account id (SessionContext.swift), a parameter for the
/// same reason `quarantined` is one: the report stays a pure function of what it is handed, and this
/// file never learns where a supervisor publishes anything. `sessions` is the machine's whole
/// inventory on the same terms, and the two are separate arguments because they are separate
/// answers: one session per account against every session there is (`sessionReadings` hands the
/// caller both out of a single scan, so they cannot describe different moments).
/// `projectPolicy` likewise: the caller resolved which project this is, this only publishes it.
func statusReport(_ snapshot: Snapshot, policies: [String: LaunchPolicy],
                  advisor: [UsageAdvisor.Reading] = [], quarantined: [String: Set<String>] = [:],
                  accountSessions: [String: StatusReport.SessionSummary] = [:],
                  sessions: [StatusReport.Session] = [],
                  projectPolicy: StatusReport.ProjectProfile? = nil,
                  now: Date = Date()) -> StatusReport {
    let advisorByProvider = Dictionary(uniqueKeysWithValues: advisor.map { reading in
        (reading.provider, StatusReport.Advisor(
            headline: UsageAdvisor.englishHeadline(reading),
            verdict: reading.verdict.rawValue,
            demandPerWeek: reading.demandPerWeek,
            tierDemands: reading.tierDemands.map {
                StatusReport.Advisor.Tier(plan: $0.plan, demandPerWeek: $0.demandPerWeek,
                                          accountCount: $0.accountCount)
            },
            activeBurnPerHour: reading.activeBurnPerHour,
            starvedHoursPerWeek: reading.starvedHoursPerWeek,
            daysOfData: reading.daysOfData))
    })
    // Known providers first (with a launch pick), then any provider this CLI doesn't know yet:
    // the JSON mirrors the snapshot, it never silently drops an account.
    var order = providers.map(\.id)
    for account in snapshot.accounts where !order.contains(account.provider) {
        order.append(account.provider)
    }
    var accounts: [StatusReport.Account] = []
    for providerID in order {
        let mine = snapshot.accounts.filter { $0.provider == providerID }
        let policy = policies[providerID] ?? LaunchPolicy()
        let (bestID, pinnedID) = launchMarkers(providerID: providerID, in: snapshot, policy: policy,
                                               quarantined: quarantined[providerID] ?? [], now: now)
        for account in mine {
            accounts.append(.init(
                id: account.id, provider: account.provider, label: account.label,
                launchHome: account.launchHome,
                best: account.id == bestID, pinned: account.id == pinnedID,
                isStale: account.isStale, error: account.error,
                sessionRemaining: account.sessionRemaining,
                sessionResetsAt: account.sessionResetsAt,
                weeklyRemaining: account.weeklyRemaining,
                weeklyResetsAt: account.weeklyResetsAt,
                modelWindowName: account.modelWindowName,
                modelRemaining: account.modelRemaining,
                modelResetsAt: account.modelResetsAt,
                resetCreditsAvailable: account.resetCreditsAvailable,
                sessionContextTokens: accountSessions[account.id]?.contextTokens,
                sessionModel: accountSessions[account.id]?.model,
                sessionEffort: accountSessions[account.id]?.effort))
        }
    }
    return StatusReport(
        generatedAt: snapshot.generatedAt,
        stale: now.timeIntervalSince(snapshot.generatedAt) > snapshotMaxAge,
        accounts: accounts,
        fleet: snapshot.fleet,
        fleetPools: snapshot.fleetPools,
        advisor: advisorByProvider.isEmpty ? nil : advisorByProvider,
        sessions: sessions,
        projectPolicy: projectPolicy)
}

/// The usage advisor's per-provider readings, computed straight from the burn-rate history the app
/// records (`~/.tally/history.jsonl`) - NOT from the snapshot, which carries no advisor data.
/// Fail-open: a missing or unreadable file just yields no advisor, so `status` still renders.
///
/// `plans` maps account id to plan name, joined from the snapshot because the history holds no
/// plan of its own (see `UsageAdvisor.readings`). Empty just leaves the tier split unnamed.
func loadAdvisorReadings(plans: [String: String] = [:], now: Date = Date()) -> [UsageAdvisor.Reading] {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".tally/history.jsonl")
    guard let data = try? Data(contentsOf: url) else { return [] }
    let since = now.addingTimeInterval(-UsageAdvisor.lookbackDays * 86_400)
    return UsageAdvisor.readings(samples: UsageAdvisor.decodeSamples(data, since: since),
                                 now: now) { plans[$0] }
}

/// Account id to plan name, for the join above. Accounts the snapshot leaves plan-less are simply
/// absent, which is what the advisor reads as an unnamed tier.
func accountPlans(_ snapshot: Snapshot) -> [String: String] {
    Dictionary(snapshot.accounts.compactMap { account in account.plan.map { (account.id, $0) } },
               uniquingKeysWith: { first, _ in first })
}

func encodeStatusReport(_ report: StatusReport) -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = (try? encoder.encode(report)) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
}
