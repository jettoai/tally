import Foundation

// THE PERSONAL ACCOUNT'S RESERVE, at the layer every automatic pick is built on: the state file it
// is read from, the one subtraction it becomes, and the two things it must never do (stop a person,
// or leave the machine with no way to launch).
//
// Compiled against the real source with a FIXED `now`, like every other check in this suite. The
// harness (`check`, `failures`, `now`, `inHours`) is shared from main.swift; the account fixture is
// local because these scenarios need a reserve-bearing home, which the shared one has no argument
// for.

func runReserveChecks() {
    // MARK: - R1. The fixtures

    /// An account whose WEEKLY window is the interesting one, with its config home named so a
    /// reserve can be keyed on it. Session at 90% with a reset four hours out never binds.
    func acct(_ id: String, weekly: Double, weeklyResetHours: Double = 100,
              session: Double = 90, model: Double? = nil,
              home: String? = nil, stale: Bool = false, error: String? = nil,
              refreshFailed: Bool? = false) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: "claude", label: id,
                         launchHome: home ?? "/tmp/reserve-\(id)",
                         sessionRemaining: session, weeklyRemaining: weekly, modelRemaining: model,
                         sessionResetsAt: inHours(4),
                         weeklyResetsAt: inHours(weeklyResetHours),
                         modelResetsAt: model == nil ? nil : inHours(weeklyResetHours),
                         modelWindowName: model == nil ? nil : "fable",
                         resetCreditsAvailable: nil,
                         isStale: stale, error: error, lastRefreshFailed: refreshFailed)
    }

    /// The reserves a state file with this block would produce, without writing one. The entries
    /// are the SHARED type (Tally/Core/AccountReserve.swift, compiled into both targets), so a
    /// fixture cannot describe a document the app could not have written.
    func reserves(_ entries: [String: (role: String?, reserve: Int)]) -> AccountReserves {
        AccountReserves(settings: entries.mapValues {
            AccountRoleSetting(role: $0.role, reserve: $0.reserve)
        })
    }

    /// 30 points held back on account A and nothing anywhere else - the shape of the whole feature.
    let personalA = reserves(["/tmp/reserve-A": (AccountRoles.personal, 30)])

    func snapshot(_ accounts: [Snapshot.Account]) -> Snapshot {
        Snapshot(version: 2, generatedAt: now, accounts: accounts)
    }

    // MARK: - R2. The state file, and every way of not having one

    /// One `~/.tally/state.json` on disk, so the reader is asserted against bytes rather than
    /// against a value this file built.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-reserve-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    func stateFile(_ json: String) -> URL {
        let url = dir.appendingPathComponent("state-\(UUID().uuidString).json")
        try! Data(json.utf8).write(to: url)
        return url
    }

    let readBack = accountReserves(stateFile("""
    {"version":1,"launch":{"claude":{"mode":"auto"}},
     "accounts":{"/tmp/reserve-A":{"role":"personal","reserve":30},
                 "/tmp/reserve-B":{"reserve":0}}}
    """))
    check("the reserve block is read back off the state file",
          readBack.reserve(for: acct("A", weekly: 50)) == 30)
    check("…and an entry carrying no role is read as reserving nothing",
          readBack.settings["/tmp/reserve-B"]?.reserve == 0
              && readBack.reserve(for: acct("B", weekly: 50)) == 0)
    check("…and the personal account is the one that says so",
          readBack.personalHome == "/tmp/reserve-A")
    // TWO MARKED HOMES RESOLVE THE SAME WAY ON EVERY READ. Only a hand edit or two builds writing
    // the file can produce that (the setter clears the role wherever it was), and the cost of
    // getting it wrong is not a wrong answer but an UNSTABLE one: the Artifact guard would name a
    // different account on different runs of the same binary against the same file, which is the
    // failure mode nobody can reproduce. The shared rule sorts for exactly this.
    //
    // THIRTY DISTINCT PAIRS RATHER THAN ONE ASSERTION THIRTY TIMES, because repetition would prove
    // nothing: a dictionary's iteration order is fixed for a given key set within a process, so the
    // same pair answers the same thing however often it is asked. Each pair hashes differently, so
    // an implementation handing back "whichever came first" agrees with the sorted answer on about
    // half of them and the run is decided by 2^-30 rather than by a coin toss.
    let tieBreaks = (0 ..< 30).map { index -> Bool in
        let lower = "/tmp/reserve-tie-a\(index)"
        let upper = "/tmp/reserve-tie-z\(index)"
        let both = AccountReserves(settings: [
            upper: AccountRoleSetting(role: AccountRoles.personal, reserve: 30),
            lower: AccountRoleSetting(role: AccountRoles.personal, reserve: 10),
        ])
        return both.personalHome == lower
    }
    check("a document carrying two marked homes answers the same one every time",
          tieBreaks.allSatisfy { $0 })
    check("an account the block never names reserves nothing",
          readBack.reserve(for: acct("Z", weekly: 50)) == 0)
    // A `launch` block this binary understands sitting beside a key it does not is the ordinary
    // shape of this file; the reverse is what a NEWER app writes, and neither may cost the other.
    check("a file with no accounts block at all reserves nothing",
          accountReserves(stateFile(#"{"version":1,"launch":{"claude":{"mode":"manual"}}}"#))
              == .none)
    check("…and neither does one nobody can parse", accountReserves(stateFile("{")) == .none)
    check("…and neither does a file that is not there",
          accountReserves(dir.appendingPathComponent("absent.json")) == .none)
    // THE KEY IS A DIRECTORY, NOT A STRING. The app writes what the user's machine calls the home;
    // the account carries what the snapshot calls it, and the two are spelled differently on a
    // machine whose home has a trailing slash or a `~` in it.
    let sloppy = accountReserves(stateFile(
        #"{"accounts":{"/tmp/reserve-A/":{"role":"personal","reserve":25}}}"#))
    check("a home written with a trailing slash still answers for that directory",
          sloppy.reserve(for: acct("A", weekly: 50)) == 25)
    check("a reserve nobody could have meant is clamped rather than believed",
          reserves(["/tmp/reserve-A": (AccountRoles.personal, -40)])
              .reserve(for: acct("A", weekly: 50)) == 0
              && reserves(["/tmp/reserve-A": (AccountRoles.personal, 400)])
              .reserve(for: acct("A", weekly: 50)) == 100)
    // A NUMBER ON AN UNMARKED ACCOUNT IS A LEFTOVER, not a reserve. The stepper only exists on the
    // marked row, so this can only come from a hand edit or an older build - and the app reads it as
    // zero (`AccountRoles.reserve`). Two processes reading one document have to agree about that.
    check("a reserve on an account holding no role is read as none at all",
          reserves(["/tmp/reserve-A": (nil, 30)]).reserve(for: acct("A", weekly: 50)) == 0)

    // MARK: - R3. The subtraction itself, and what it deliberately does not touch

    let held = acct("A", weekly: 50)
    check("the gate reads the reserve off the window it weighs",
          effectiveRemaining(comfortWindow(bindingWindow(held, primaryModel: nil,
                                                         reserves: personalA, now: now)!),
                             now: now) == 20)
    check("…and reads the provider's own number without one",
          effectiveRemaining(comfortWindow(bindingWindow(held, primaryModel: nil, now: now)!),
                             now: now) == 50)
    // ELIGIBILITY IS RESERVE-BLIND ON PURPOSE: a reserve says "spend elsewhere if you can", never
    // "this account does not exist", and that difference is what keeps `tally claude` working when
    // the whole fleet is under water (R7).
    check("a reserve never makes an account ineligible",
          eligible(acct("A", weekly: 20)) && headroom(acct("A", weekly: 20)) == 20)
    // AND NOTHING A PERSON READS IS ADJUSTED. "weekly 50%" has to mean the same thing here, in the
    // panel and on claude.ai; the reserve is Tally's arithmetic, not news about the account.
    check("the human reason quotes the provider's percentage, not the reserved one",
          pickReason(held, primaryModel: nil, now: now).hasPrefix("weekly 50%"))
    check("…and so does the window sentence the knock quotes",
          windowReason(bindingWindow(held, primaryModel: nil, reserves: personalA, now: now)!,
                       now: now).hasPrefix("weekly 50%"))
    // A WINDOW ABOUT TO REFILL OFFERS A FULL ONE MINUS THE RESERVE, which is the order the two
    // readings are applied in: a reserve does not survive the refill it is measured against.
    let refilling = acct("A", weekly: 1, weeklyResetHours: 0.05)
    let refillingWeekly = ratedWindows(refilling, primaryModel: nil, reserves: personalA, now: now)
        .first { $0.name == "weekly" }
    check("the weekly window of the refilling fixture was found (guard the premise)",
          refillingWeekly != nil)
    check("an imminent reset counts as a full window, less the reserve",
          effectiveRemaining(comfortWindow(refillingWeekly!), now: now) == 70)

    // MARK: - R3b. THREE WINDOWS CARRY IT: THE WEEKLY ALL-MODELS ONE, THE 5H SESSION ONE, AND THE
    // FLAGSHIP MODEL'S

    // Albert's ruling, 2026-09-05 (AccountReserve.swift states it, superseding the two-window ruling
    // of 2026-09-02 and the weekly-only one of 2026-08-21): claude.ai and the CLI draw on ONE 5h
    // session window and on ONE flagship pool, so an automatic launch that empties either locks the
    // person out of their own browser until it refills. The argument that had kept the flagship
    // window out - it is a sub-allowance of the same week, so reserving it too would hold the same
    // points back twice - holds only while the reserve is the WHOLE of the spending rule; under a
    // partial one, half a week held back says nothing about how the other half is spent. Asserted at
    // the window, and then at everything that reads it.
    let mixed = acct("A", weekly: 90, session: 20, model: 25)
    func rated(_ account: Snapshot.Account, _ reserves: AccountReserves,
               primaryModel: String? = nil) -> [String: RatedWindow] {
        var out: [String: RatedWindow] = [:]
        for window in ratedWindows(account, primaryModel: primaryModel, reserves: reserves,
                                   now: now) {
            out[window.name] = window
        }
        return out
    }
    let held5h = rated(mixed, personalA)
    check("all three windows of the fixture were rated (guard the premise)",
          held5h["session"] != nil && held5h["weekly"] != nil && held5h["fable"] != nil)
    check("the weekly window carries the reserve", held5h["weekly"]?.reserve == 30)
    check("…so does the 5h session window", held5h["session"]?.reserve == 30)
    check("…and so does the flagship one, named by the provider rather than by us",
          held5h["fable"]?.reserve == 30)
    let bare = rated(mixed, .none)
    check("…so all three are rated on what Tally may spend, not on what the account holds",
          held5h["weekly"]?.rate != bare["weekly"]?.rate
              && held5h["session"]?.rate != bare["session"]?.rate
              && held5h["fable"]?.rate != bare["fable"]?.rate)
    check("…and the gate reads every one of them less the reserve",
          effectiveRemaining(comfortWindow(held5h["session"]!), now: now) == -10
              && effectiveRemaining(comfortWindow(held5h["weekly"]!), now: now) == 60
              && effectiveRemaining(comfortWindow(held5h["fable"]!), now: now) == -5)
    // AND NOTHING IS HELD BACK ON AN ACCOUNT NOBODY MARKED, on any of the three: the scope widened,
    // the marking did not.
    let unmarked = rated(acct("B", weekly: 90, session: 20, model: 25), personalA)
    check("an account nobody reserved anything on holds nothing back on any of the three",
          unmarked["weekly"]?.reserve == 0 && unmarked["session"]?.reserve == 0
              && unmarked["fable"]?.reserve == 0)

    // THE CASE THE WIDENING WAS FOR, at the size a person actually sets it: half the week held back
    // leaves the WEEK comfortably above its line (80 - 50) while the flagship pool this account's
    // owner browses on is 20 points under it (30 - 50). Under the old scope that account read as
    // healthy and Tally went on spending the one window they would have noticed.
    let halfHeld = reserves(["/tmp/reserve-A": (AccountRoles.personal, 50)])
    let flagshipDrained = acct("A", weekly: 80, session: 90, model: 30)
    let halfRated = rated(flagshipDrained, halfHeld)
    check("half held back leaves the week above its line and the flagship pool under it",
          effectiveRemaining(comfortWindow(halfRated["weekly"]!), now: now) == 30
              && effectiveRemaining(comfortWindow(halfRated["fable"]!), now: now) == -20)
    check("…so the flagship rate is negative, which is what makes a pick step off the account",
          (halfRated["fable"]?.rate ?? 0) < 0)
    check("…and the account reads as under its water line on that window alone",
          !aboveReserve(flagshipDrained, primaryModel: nil, reserves: halfHeld, now: now))
    check("…and the launch onto it names the flagship window rather than the week",
          reserveDipNotice(flagshipDrained, primaryModel: nil, reserves: halfHeld, now: now)
              == "dipping into A's fable reserve (50% kept for web use)")
    check("…while the same account with nothing reserved on it is above its line (the premise)",
          aboveReserve(flagshipDrained, primaryModel: nil, reserves: .none, now: now))
    // AND EVERY GATE FOLLOWS THAT LINE, which is what widening the scope buys: an account under it
    // is not somewhere an automatic launch or move may land.
    check("an account under its flagship line is not comfortable, and reads as spent",
          !accountIsComfortable(flagshipDrained, primaryModel: nil, reserves: halfHeld, now: now)
              && accountIsSpent(flagshipDrained, primaryModel: nil, reserves: halfHeld, now: now))
    check("…while the same account is comfortable and unspent with no reserve (the premise)",
          accountIsComfortable(flagshipDrained, primaryModel: nil, now: now)
              && !accountIsSpent(flagshipDrained, primaryModel: nil, now: now))

    // A PROJECT ON ANOTHER TIER RATES NO FLAGSHIP WINDOW, AND SO CARRIES NO LINE ON ONE. The window
    // is weighed only when the declared primary model IS that tier, and a sonnet primary does not
    // spend the fable pool - so there is nothing there for a line to hold back, and the account is
    // judged on the two windows that project really does draw on.
    let sonnetRated = rated(flagshipDrained, halfHeld, primaryModel: "sonnet")
    check("a project on another tier does not rate the flagship window at all",
          sonnetRated["fable"] == nil && sonnetRated["weekly"] != nil
              && sonnetRated["session"] != nil)
    check("…so the same account is above its water line to that project",
          aboveReserve(flagshipDrained, primaryModel: "sonnet", reserves: halfHeld, now: now))
    check("…and a launch onto it announces no dip",
          reserveDipNotice(flagshipDrained, primaryModel: "sonnet", reserves: halfHeld,
                           now: now) == nil)
    check("…while a project on THAT tier is told about the line (the premise)",
          !aboveReserve(flagshipDrained, primaryModel: "fable", reserves: halfHeld, now: now))

    // EITHER SHARED WINDOW UNDER THE LINE IS A CROSSED LINE, AND THE SENTENCE NAMES WHICH ONE. The
    // two mean different things to the reader - a week that will not refill for days, or a 5h window
    // their browser shares and that comes back this afternoon - so a fixed "weekly" would have named
    // the wrong one half the time.
    let thinWeek = acct("A", weekly: 25, session: 100, model: 100)
    check("an account thin in the week alone is under its water line",
          !aboveReserve(thinWeek, primaryModel: nil, reserves: personalA, now: now))
    check("…and the launch onto it says which reserve it is spending",
          reserveDipNotice(thinWeek, primaryModel: nil, reserves: personalA, now: now)
              == "dipping into A's weekly reserve (30% kept for web use)")
    // THE HALF THE 2026-09-02 RULING ADDED, and the half an `aboveReserve` reading only the FIRST
    // reserved window it finds gets wrong: the session window is built first, so a first-match
    // reading answers on the 5h window and never looks at the week - which on `thinWeek` above calls
    // an account whose week is spent healthy, on the strength of an untouched 5h window.
    let thinSession = acct("A", weekly: 100, session: 25, model: 100)
    check("an account thin in its 5h window alone is under its water line too",
          !aboveReserve(thinSession, primaryModel: nil, reserves: personalA, now: now))
    check("…and the launch onto it names the 5h window rather than the week",
          reserveDipNotice(thinSession, primaryModel: nil, reserves: personalA, now: now)
              == "dipping into A's session reserve (30% kept for web use)")
    let thinBoth = acct("A", weekly: 25, session: 25, model: 100)
    check("an account under both of its lines is under its water line",
          !aboveReserve(thinBoth, primaryModel: nil, reserves: personalA, now: now))
    check("…and the launch onto it names both, in the order the windows are rated",
          reserveDipNotice(thinBoth, primaryModel: nil, reserves: personalA, now: now)
              == "dipping into A's session and weekly reserve (30% kept for web use)")
    // AND EVERY GATE FOLLOWS THE 5H LINE, which is the whole of what widening the scope buys: an
    // account under it is not somewhere an automatic launch or move may land.
    check("an account under its 5h line is not comfortable",
          !accountIsComfortable(thinSession, primaryModel: nil, reserves: personalA, now: now))
    check("…and reads as spent, on the same scale as one under its weekly line",
          accountIsSpent(thinSession, primaryModel: nil, reserves: personalA, now: now))
    check("…while the same account is comfortable and unspent with no reserve (the premise)",
          accountIsComfortable(thinSession, primaryModel: nil, now: now)
              && !accountIsSpent(thinSession, primaryModel: nil, now: now))

    // MARK: - R4. Consumer 1, the launch pick

    // A CANNOT WIN ON A NUMBER IT IS NOT ALLOWED TO SPEND. Raw, A is the healthier account (50%
    // against 40%); through the reserve it is the thinner one (20% against 40%), and the pick has
    // to follow the second reading or "spend somewhere else if you can" means nothing until the
    // account is already at the line.
    let launchField = snapshot([acct("A", weekly: 50), acct("B", weekly: 40)])
    check("the launch pick spends the sibling rather than the reserved account",
          best(providerID: "claude", in: launchField, reserves: personalA, now: now)?.id == "B")
    check("…and takes the reserved one when nobody reserved anything (guard the premise)",
          best(providerID: "claude", in: launchField, now: now)?.id == "A")
    // THE EXPLICIT PATHS PASS `.none`, which is the whole of their exemption. `--account`, a panel
    // pin and `tally account` resolve a NAME and then launch it; nothing in that chain asks a
    // reserve anything, and these are the two functions the chain is made of.
    let named = acct("A", weekly: 20)
    check("a named account resolves whatever its reserve says",
          accountMatching("A", provider: "claude", in: snapshot([named])) == .one(named))
    check("…and a pin launches its home with no reserve consulted",
          pinnedLaunchHome(snapshot([named]),
                           policy: LaunchPolicy(mode: "manual", pinnedAccountID: "A"))
              == "/tmp/reserve-A")

    // MARK: - R5. Consumers 2-5, every automatic MOVE, through the one target-chooser they share

    // The cap handoff, the idle rebalance, the turn-boundary move and the `/clear` repick all
    // choose through `capHandoffTarget`, so this is where "a move never lands under somebody's
    // line" is asserted once for the four of them. Their own gates are asserted in the supervisor
    // suite; what is asserted here is the choice itself.
    let underWater = acct("A", weekly: 25)
    check("an automatic move refuses an account under its reserve",
          capHandoffTarget([underWater], primaryModel: nil, reserves: personalA, now: now) == nil)
    check("…and takes it when the account was named by hand instead",
          capHandoffTarget([underWater], primaryModel: nil, now: now)?.id == "A")
    check("…and still prefers a sibling that is genuinely healthier",
          capHandoffTarget([acct("A", weekly: 50), acct("B", weekly: 40)], primaryModel: nil,
                           reserves: personalA, now: now)?.id == "B")
    // A MOVE WAITS RATHER THAN CROSSING THE LINE: the empty answer is "stay where you are", which
    // is what every mover already does when no sibling has room.
    check("nothing but a reserved account means wait, not move",
          capHandoffTarget([underWater, acct("A2", weekly: 3)], primaryModel: nil,
                           reserves: personalA, now: now) == nil)
    // The model re-pick and the follow adoption reach the same rule through the seeded pick, where
    // the CHALLENGERS are gated and the incumbent deliberately is not.
    check("a challenger under its reserve never takes a session off the incumbent",
          incumbentSeededBest(providerID: "claude",
                              in: snapshot([acct("B", weekly: 40), acct("A", weekly: 50)]),
                              incumbentID: "B", primaryModel: nil, reserves: personalA,
                              now: now)?.id == "B")
    check("…while the same challenger takes it with no reserve in the way (guard the premise)",
          incumbentSeededBest(providerID: "claude",
                              in: snapshot([acct("B", weekly: 40), acct("A", weekly: 50)]),
                              incumbentID: "B", primaryModel: nil, now: now)?.id == "A")

    // MARK: - R6. The ruling: under its own line, an account is SPENT as far as Tally is concerned

    check("an account at its reserve is not comfortable",
          !accountIsComfortable(acct("A", weekly: 33), primaryModel: nil, reserves: personalA,
                                now: now))
    check("…and one comfortably above it still is",
          accountIsComfortable(acct("A", weekly: 60), primaryModel: nil, reserves: personalA,
                               now: now))
    check("an account that has dipped under its reserve reads as spent",
          accountIsSpent(acct("A", weekly: 25), primaryModel: nil, reserves: personalA, now: now))
    check("…exactly at the line, where there is nothing left to spend",
          accountIsSpent(acct("A", weekly: 30), primaryModel: nil, reserves: personalA, now: now))
    check("…and one point above it is not spent",
          !accountIsSpent(acct("A", weekly: 31), primaryModel: nil, reserves: personalA, now: now))
    check("…nor is the same account to a path that named it by hand",
          !accountIsSpent(acct("A", weekly: 25), primaryModel: nil, now: now))
    // THE THREE TRUST GUARDS COME FIRST WHATEVER THE RESERVE SAYS. A reserve is a preference read
    // off a file; it is not evidence about quota, and it must not be what makes a held-over zero
    // actionable. Every one of these rows is under the line and none of them is spent.
    check("a failed poll is not made actionable by a reserve",
          !accountIsSpent(acct("A", weekly: 25, refreshFailed: true), primaryModel: nil,
                          reserves: personalA, now: now))
    check("…nor is a stale row", !accountIsSpent(acct("A", weekly: 25, stale: true),
                                                 primaryModel: nil, reserves: personalA, now: now))
    check("…nor is an errored one", !accountIsSpent(acct("A", weekly: 25, error: "boom"),
                                                    primaryModel: nil, reserves: personalA,
                                                    now: now))
    // AND THE CLAIM EXEMPTION IS WHAT BEING SPENT BUYS, which is the point of the ruling: the idle
    // sessions on a reserved account are released without waiting for the one move per drought.
    // (The movers' own gate tables are asserted in the supervisor suite; this is the reading they
    // ask for.) `aboveReserve` is the same scale seen from the candidate side.
    check("an account under its line is not above it",
          !aboveReserve(acct("A", weekly: 25), primaryModel: nil, reserves: personalA, now: now))
    check("…and an account nobody reserved anything on always is",
          aboveReserve(acct("B", weekly: 1), primaryModel: nil, reserves: personalA, now: now))
    check("an account reporting no windows at all is not judged by a reserve it cannot spend",
          aboveReserve(Snapshot.Account(id: "A", provider: "claude", label: "A",
                                        launchHome: "/tmp/reserve-A", isStale: false, error: nil),
                       primaryModel: nil, reserves: personalA, now: now))

    // MARK: - R7. The whole fleet under water still launches, and says so

    // A launch has nowhere else to go, so the reserves are dropped for that one pick - and the
    // launcher prints the one line that keeps the preference honest.
    //
    // THE FIXTURE IS THE REAL SHAPE OF THIS SITUATION, which is worth stating because it is not the
    // one it first looks like: an account with NO reserve is under its own line only when it is
    // empty, and an empty account is not eligible at all. So the fallback is reached exactly when
    // every account still launchable carries a reserve - here, the fleet of one that the owner also
    // browses on, beside a sibling that is genuinely spent.
    let drought = snapshot([acct("A", weekly: 25), acct("B", weekly: 0)])
    let dipped = best(providerID: "claude", in: drought, reserves: personalA, now: now)
    check("a fleet under its own water lines still launches", dipped != nil)
    check("…on the account the pick would have chosen without any reserve at all",
          dipped?.id == best(providerID: "claude", in: drought, now: now)?.id)
    check("…and the launch says whose reserve it is spending, and which window it is",
          reserveDipNotice(dipped!, primaryModel: nil, reserves: personalA, now: now)
              == "dipping into A's weekly reserve (30% kept for web use)")
    check("a launch that stayed above the line says nothing",
          reserveDipNotice(acct("A", weekly: 60), primaryModel: nil, reserves: personalA,
                           now: now) == nil)
    check("…and neither does one onto an account nobody reserved anything on",
          reserveDipNotice(acct("B", weekly: 1), primaryModel: nil, reserves: personalA,
                           now: now) == nil)
    // A MOVE GETS NO SUCH FALLBACK, which is the asymmetry the whole design turns on: a launch has
    // no session yet, a move already has one somewhere.
    check("the same drought moves nobody",
          capHandoffTarget(drought.accounts, primaryModel: nil, reserves: personalA, now: now)
              == nil)

    // MARK: - R8. A fleet with no reserves set is untouched, end to end

    // The substitution in `best` cannot fire on such a fleet (an eligible account has every window
    // above zero, so it is above a reserve of zero by definition), and every reading above is the
    // one this repo had before the feature existed.
    let plain = snapshot([acct("A", weekly: 50), acct("B", weekly: 40)])
    check("no reserves anywhere leaves the pick exactly where it was",
          best(providerID: "claude", in: plain, reserves: .none, now: now)?.id
              == best(providerID: "claude", in: plain, now: now)?.id)
    check("…and the gate too",
          accountIsComfortable(acct("A", weekly: 6), primaryModel: nil, reserves: .none, now: now)
              == accountIsComfortable(acct("A", weekly: 6), primaryModel: nil, now: now))

    try? FileManager.default.removeItem(at: dir)
}
