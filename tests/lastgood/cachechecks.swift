import Foundation

// B-2027: the last-good cache that lets a relaunch open on the account list it closed with
// (Tally/Core/LastGoodCache.swift, wired in Tally/Stores/UsageStore+LastGoodCache.swift).

private func metric(_ kind: MetricKind, used: Double, model: String? = nil, resets: Date? = nil) -> UsageMetric {
    UsageMetric(id: "\(kind.rawValue):\(model ?? "")", kind: kind, label: "Weekly", modelName: model,
                usedPercent: used, severity: .normal, resetsAt: resets, isActive: kind == .weeklyModel)
}

private func usage(_ id: String, provider: String = "claude", label: String? = nil,
                   refreshed: Date, email: String? = nil, detail: String? = nil) -> AccountUsage {
    var u = AccountUsage(id: id, providerID: provider, accountLabel: label ?? id, planName: "Max 20x",
                         accountEmail: email,
                         metrics: [metric(.weeklyAll, used: 41.25, resets: refreshed.addingTimeInterval(3_600.123)),
                                   metric(.weeklyModel, used: 7, model: "Fable 5"),
                                   metric(.session, used: 100)],
                         refreshedAt: refreshed, error: nil)
    u.errorDetail = detail
    return u
}

func runCacheChecks() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let fresh = now.addingTimeInterval(-600.789)
    let a = usage("claude:a", label: "A", refreshed: fresh, email: "x@y.z", detail: "SECRET-DETAIL")
    let b = usage("claude:b", label: "B", refreshed: fresh)
    let c = usage("codex:c", provider: "codex", label: "C", refreshed: fresh)
    let last = ["claude:a": a, "claude:b": b, "codex:c": c]
    let homes = ["claude:a": "/h/a", "claude:b": "/h/b", "codex:c": "/h/c"]
    let rows = LastGoodCache.rows(last, homes: homes)
    let data = LastGoodCache.encode(rows: rows, savedAt: now)
    let decoded = LastGoodCache.decode(data)

    func seed(_ cache: LastGoodCache?, at: Date = now, exists: @escaping (String) -> Bool = { _ in true },
              shown: @escaping (String, String) -> Bool = { _, _ in true }) -> LastGoodCache.Seed {
        LastGoodCache.seed(cache, now: at, homeExists: exists, isShown: shown)
    }

    // (a1) round trip, sub-second dates included
    check("cache round-trips to the same rows", decoded?.rows == rows && decoded?.savedAt == now)
    let restored = seed(decoded).lastGood["claude:a"]
    check("restored reading equals what was cached",
          restored.map { $0.metrics == a.metrics && $0.refreshedAt == a.refreshedAt && $0.planName == a.planName
              && $0.accountLabel == "A" && $0.providerID == "claude" } == true)
    check("restored reading is a clean last-good: no error, not stale, no email",
          restored.map { $0.error == nil && !$0.isStale && !$0.lastRefreshFailed && $0.accountEmail == nil } == true)

    // (a2) unreadable or foreign data is the empty start of today
    check("nil data reads as no cache", LastGoodCache.decode(nil) == nil)
    check("damaged data reads as no cache", LastGoodCache.decode(Data("{".utf8)) == nil)
    var future = decoded!
    future.version = 2
    check("another schema version reads as no cache",
          LastGoodCache.decode(try? JSONEncoder().encode(future)) == nil)
    check("no cache seeds nothing", seed(nil).rows.isEmpty && seed(nil).lastGood.isEmpty)

    // (a3) a removed account leaves no ghost row
    let ghost = seed(decoded, exists: { $0 != "/h/b" })
    check("a missing home is neither shown nor remembered",
          ghost.rows.map(\.id) == ["claude:a", "codex:c"] && ghost.lastGood["claude:b"] == nil
              && ghost.homes["claude:b"] == nil)

    // (a4) over a day old is not current
    let aged = LastGoodCache.rows(["claude:a": usage("claude:a", refreshed: now.addingTimeInterval(-25 * 3_600)),
                                   "claude:b": usage("claude:b", refreshed: now.addingTimeInterval(-23 * 3_600))],
                                  homes: homes)
    let agedSeed = seed(LastGoodCache.decode(LastGoodCache.encode(rows: aged, savedAt: now)))
    check("a 25 hour old reading is dropped, a 23 hour old one kept",
          agedSeed.rows.map(\.id) == ["claude:b"] && agedSeed.lastGood["claude:a"] == nil)

    // (a5) a disabled account is remembered but not shown
    let hidden = seed(decoded, shown: { $1 != "claude:a" })
    check("a disabled account stays in last-good but not on the first frame",
          hidden.rows.map(\.id) == ["claude:b", "codex:c"] && hidden.lastGood["claude:a"] != nil)

    // (a6) the order a refresh commit gives: (providerID, accountLabel)
    let mixed = LastGoodCache.rows(["z": usage("z", label: "B", refreshed: fresh),
                                    "y": usage("y", provider: "codex", label: "A", refreshed: fresh),
                                    "x": usage("x", label: "A", refreshed: fresh)],
                                   homes: ["x": "/x", "y": "/y", "z": "/z"])
    check("first frame rows are ordered like a commit orders them",
          seed(LastGoodCache.decode(LastGoodCache.encode(rows: mixed, savedAt: now))).rows.map(\.id) == ["x", "z", "y"])
    check("an account with no known home is not cached",
          LastGoodCache.rows(last, homes: ["claude:a": "/h/a"]).map(\.id) == ["claude:a"])
    check("identical state encodes to identical rows regardless of dictionary order",
          LastGoodCache.rows(last, homes: homes) == LastGoodCache.rows(Dictionary(uniqueKeysWithValues: last.reversed()), homes: homes))

    // (d) the written keys are a whitelist; no email, no error text, nothing credential-shaped
    let allowed: Set<String> = ["version", "savedAt", "rows", "id", "providerID", "accountLabel", "planName",
                                "home", "refreshedAt", "metrics", "kind", "label", "modelName", "usedPercent",
                                "severity", "resetsAt", "isActive"]
    func keys(_ any: Any) -> Set<String> {
        if let dict = any as? [String: Any] { return Set(dict.keys).union(dict.values.flatMap { keys($0) }) }
        if let list = any as? [Any] { return Set(list.flatMap { keys($0) }) }
        return []
    }
    let written = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) }).map(keys) ?? ["unparsed"]
    check("cache keys are inside the whitelist", written.isSubset(of: allowed))
    let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    check("cache holds neither the email nor the error detail",
          !text.isEmpty && !text.contains("x@y.z") && !text.contains("SECRET-DETAIL"))

    // (b) the store is really wired to it
    let store = (try? String(contentsOfFile: "Tally/Stores/UsageStore.swift", encoding: .utf8)) ?? ""
    let ext = (try? String(contentsOfFile: "Tally/Stores/UsageStore+LastGoodCache.swift", encoding: .utf8)) ?? ""
    check("the store starts from the cache and persists at commit and on removal",
          store.contains("private init() { (accounts, lastGood) = Self.cachedLastGood() }")
              && store.contains("persistLastGood(lastGood, known: known)")
              && store.contains("persistLastGood(lastGood, known: nil)"))
    check("the cache never loads in demo mode and logs how many rows it seeded",
          ext.contains("guard !DemoUsage.isActive else { return ([], [:]) }") && ext.contains("seeded rows="))
    check("only a build that owns its defaults domain writes the cache",
          ext.contains("!BuildVariant.isUnshipped || BuildVariant.isDev"))
    let redeem = (try? String(contentsOfFile: "Tally/Stores/RedeemRequestStore.swift", encoding: .utf8)) ?? ""
    check("a redeem request waits for discovery now that rows exist before it",
          redeem.contains("guard store.hasDiscovered, !store.accounts.isEmpty else"))
}
