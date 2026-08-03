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
        /// Input tokens of the newest turn in the largest conversation a supervisor is running on
        /// this account right now: what a resume there would reload before doing anything
        /// (SessionContext.swift). Absent when no supervised session is on the account, which is
        /// the ordinary case for an idle machine - so a script tests for the key rather than
        /// reading a 0 as an empty conversation.
        var sessionContextTokens: Int?
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

    struct Advisor: Encodable {
        var headline: String
        var verdict: String
        var demandPerWeek: Double
        var activeBurnPerHour: Double
        var starvedHoursPerWeek: Double
        var daysOfData: Double
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
/// `sessions` is the live context reading per account id (SessionContext.swift), a parameter for
/// the same reason `quarantined` is one: the report stays a pure function of what it is handed.
func statusReport(_ snapshot: Snapshot, policies: [String: LaunchPolicy],
                  advisor: [UsageAdvisor.Reading] = [], quarantined: [String: Set<String>] = [:],
                  sessions: [String: Int] = [:], now: Date = Date()) -> StatusReport {
    let advisorByProvider = Dictionary(uniqueKeysWithValues: advisor.map { reading in
        (reading.provider, StatusReport.Advisor(
            headline: UsageAdvisor.englishHeadline(reading),
            verdict: reading.verdict.rawValue,
            demandPerWeek: reading.demandPerWeek,
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
                sessionContextTokens: sessions[account.id]))
        }
    }
    return StatusReport(
        generatedAt: snapshot.generatedAt,
        stale: now.timeIntervalSince(snapshot.generatedAt) > snapshotMaxAge,
        accounts: accounts,
        fleet: snapshot.fleet,
        fleetPools: snapshot.fleetPools,
        advisor: advisorByProvider.isEmpty ? nil : advisorByProvider)
}

/// The usage advisor's per-provider readings, computed straight from the burn-rate history the app
/// records (`~/.tally/history.jsonl`) - NOT from the snapshot, which carries no advisor data.
/// Fail-open: a missing or unreadable file just yields no advisor, so `status` still renders.
func loadAdvisorReadings(now: Date = Date()) -> [UsageAdvisor.Reading] {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".tally/history.jsonl")
    guard let data = try? Data(contentsOf: url) else { return [] }
    let since = now.addingTimeInterval(-UsageAdvisor.lookbackDays * 86_400)
    return UsageAdvisor.readings(samples: UsageAdvisor.decodeSamples(data, since: since), now: now)
}

func encodeStatusReport(_ report: StatusReport) -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = (try? encoder.encode(report)) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
}
