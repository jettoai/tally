import Foundation

// Two config homes signed into ONE Claude account (jettoai/tally#6): which homes are duplicates and
// which one keeps the account (Tally/Core/SharedLogin.swift), plus the app wiring around it, read as
// text because the store is a main-actor singleton that runs provider CLIs.

var failures = 0
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failures += 1 }
}

typealias Home = SharedLogin.Home
func home(_ id: String, _ identity: String?, remembered: String? = nil,
          current: String? = nil) -> Home {
    Home(id: id, identity: identity, rememberedEmail: remembered, currentEmail: current)
}

let am = "claude:.claude-am", gm = "claude:.claude-gm"

// S: identity grouping, with no memory (the id-order fallback).
check("S1 same uuid: exactly one duplicate, pointing at the lower id",
      SharedLogin.duplicates([home(am, "u1"), home(gm, "u1")]) == [gm: am])
check("S3 different uuids: no duplicates",
      SharedLogin.duplicates([home(am, "u1"), home(gm, "u2")]).isEmpty)
check("S4 a missing uuid matches nothing",
      SharedLogin.duplicates([home(am, nil), home(gm, "u1")]).isEmpty)
check("S4b an empty uuid matches nothing (two empties are not one login)",
      SharedLogin.duplicates([home(am, ""), home(gm, "")]).isEmpty)
check("S5 no uuid anywhere: no duplicates",
      SharedLogin.duplicates([home(am, nil), home(gm, nil)]).isEmpty)
let a = "claude:.claude-a", b = "claude:.claude-b", c = "claude:.claude-c", d = "claude:.claude-d"
let three = SharedLogin.duplicates([home(a, "u"), home(b, "u"), home(c, "u")])
check("S6 three homes on one login: both duplicates point at the first", three == [b: a, c: a])
check("S6 …and the group names the kept one first", SharedLogin.group(keptID: a, duplicates: three) == [a, b, c])
check("S7 A=B, C different: only B", SharedLogin.duplicates([home(a, "u"), home(b, "u"), home(c, "v")]) == [b: a])
check("S8 two groups resolve on their own",
      SharedLogin.duplicates([home(a, "u"), home(b, "u"), home(c, "v"), home(d, "v")]) == [b: a, d: c])
check("S9 input order does not change the answer",
      SharedLogin.duplicates([home(c, "u"), home(a, "u"), home(b, "u")]) == three)
check("S10 the default home `.claude` is kept over `.claude-x`",
      SharedLogin.duplicates([home("claude:.claude-x", "u"), home("claude:.claude", "u")])
          == ["claude:.claude-x": "claude:.claude"])

// R1: the home whose identity did not change keeps the account.
let issue = [home(am, "u1", remembered: "am@example.com", current: "gm@example.com"),
             home(gm, "u1", remembered: "gm@example.com", current: "gm@example.com")]
check("R1a issue sample: GM (unchanged) is kept, AM (re-signed) is the duplicate, though AM sorts first",
      SharedLogin.duplicates(issue) == [am: gm])
check("R1a …in either input order", SharedLogin.duplicates(issue.reversed()) == [am: gm])
// The duplicate's email is never written back (LoginStatusStore.sharedLoginDuplicates), so the
// next round reads the same memory and answers the same.
check("R1b second round, AM's memory still am@: same answer", SharedLogin.duplicates(issue) == [am: gm])
check("R1c no memory on either (fresh install): id order",
      SharedLogin.duplicates([home(am, "u1", current: "gm@example.com"),
                              home(gm, "u1", current: "gm@example.com")]) == [gm: am])
check("R1d both remembered as the current email: id order",
      SharedLogin.duplicates([home(am, "u1", remembered: "gm@example.com", current: "gm@example.com"),
                              home(gm, "u1", remembered: "gm@example.com", current: "gm@example.com")])
          == [gm: am])
check("R1e the fallback is stable too: round 1 kept AM by order, AM's memory got gm@, GM's did not",
      SharedLogin.duplicates([home(am, "u1", remembered: "gm@example.com", current: "gm@example.com"),
                              home(gm, "u1", current: "gm@example.com")]) == [gm: am])
check("R1f an empty remembered email is no memory",
      SharedLogin.duplicates([home(am, "u1", remembered: "", current: ""),
                              home(gm, "u1", current: "gm@example.com")]) == [gm: am])
check("isSeat: only a row with no sameAccountAs", SharedLogin.isSeat(nil) && !SharedLogin.isSeat(gm))

// Wiring, read as text (the store cannot be compiled in here).
func source(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
let store = source("Tally/Stores/UsageStore.swift")
let rows = source("Tally/Stores/UsageStore+UnpolledRows.swift")
let login = source("Tally/Stores/LoginStatusStore.swift")
let advisor = source("Tally/Stores/UsageStoreAdvisor.swift")
check("W1 the duplicates leave `active` before the poll (Claude only)",
      store.contains("if provider.id == ClaudeAccounts.providerID { (active, shared) = await splitSharedLogins(active) }")
          && store.range(of: "splitSharedLogins(active)")!.lowerBound
              < store.range(of: "launchHomes[account.id] = home")!.lowerBound)
check("W2 duplicate rows join after the last-good fold, never inside it",
      store.contains(".map(applyLastGood)\n            + sharedLoginRows(shared, enabledProviders: enabledNow)"))
check("W3 the duplicates are what LoginStatusStore skips when it remembers",
      rows.contains("identities.sharedLoginDuplicates = Set(kept.keys)")
          && login.contains("for entry in named where !sharedLoginDuplicates.contains(entry.accountID)"))
check("W4 memory is read before anything this round writes",
      rows.contains("rememberedEmail: identities.rememberedEmail(account.id)"))
check("W5 the duplicate row carries the kept id", rows.contains("row.sameAccountAs = keptID"))
check("W6 the app advisor counts no duplicate as a seat",
      advisor.contains("let live = Set(accounts.filter { SharedLogin.isSeat($0.sameAccountAs) }.map(\\.id))"))

if failures > 0 {
    print("\(failures) FAILED")
    exit(1)
}
print("all sharedlogin checks passed")
