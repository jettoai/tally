import Foundation

// THE ONE LAUNCH DECISION, CELL BY CELL (#424, B-1706 / B-1736).
//
// `resolveLaunch` (LaunchDecision.swift) replaced three hand-kept copies of the launch decision
// (`runLaunch`, the shim's `steeredLaunch` / `steeredRefusal`), so this table is what proves the
// merge changed nothing. The oracle `expected` below is written from the rules as prose, in the
// order the launcher takes them, and calls none of the code under test: an exported home (unless
// `--account`), then `--account`, then the manual pin (row, then the denormalized home), then no
// snapshot, then the headroom pick, a reserve refusing every named or automatic launch unless
// `--spend-reserve`, and supervision by route (Codex's monitor on every route, B-1736). Every cell
// is listed, none sampled.
//
// Fixture per provider: three accounts (work1, work2, solo) whose windows are set by the snapshot
// dimension (under a reserve, work1 carries the one reserve and the others are spent); a signed-out
// row `out` joins when the pin names it. The row pin names work1, so it can be refused. The
// harness (`check`) is shared from main.swift.

func runResolveLaunchChecks() {
    // The launcher hands the model it scores on to the decision (main.swift's own checks), and the
    // decision hands that same value, never the configured default, to the pick and the quarantine.
    let decisionSource = (try? String(contentsOfFile: "TallyCLI/LaunchDecision.swift",
                                      encoding: .utf8)) ?? ""
    check("the decision scores the pick on the model the launcher handed it",
          decisionSource.contains("let model = r.primaryModel")
              && decisionSource.contains("primaryModel: model, quarantined: r.quarantined")
              && !decisionSource.contains("policy.model"))
    let now = Date()
    let providerPair = [providers[0], providers[1]]
    enum Shot: CaseIterable { case none, healthy, underReserve, noneEligible }
    enum Pin: CaseIterable { case none, row, notInSnapshot, signedOut }
    enum Export: CaseIterable { case none, knownRow, unknown, leaked }
    let accountFlags: [String?] = [nil, "work1", "zzz", "work"]

    func home(_ p: Provider, _ name: String) -> String { "/tmp/rl-\(p.id)-\(name)" }
    func acct(_ p: Provider, _ name: String, _ shot: Shot, signedOut: Bool = false) -> Snapshot.Account {
        // The reserve is single select (AccountRoles.reserve): under a reserve, work1 alone carries
        // one and sits under it, and the other rows are spent, so the field is the reserve's.
        let reserved = shot == .underReserve && name == "work1"
        let spent = shot == .noneEligible || (shot == .underReserve && !reserved)
        return Snapshot.Account(
            id: "\(p.id):\(name)", provider: p.id, label: name,
            launchHome: signedOut ? nil : home(p, name),
            sessionRemaining: spent ? 0 : 90, weeklyRemaining: spent ? 0 : reserved ? 50 : 90,
            modelRemaining: nil, sessionResetsAt: now.addingTimeInterval(4 * 3600),
            weeklyResetsAt: now.addingTimeInterval(100 * 3600), modelResetsAt: nil,
            modelWindowName: nil, resetCreditsAvailable: nil, isStale: false, error: nil,
            lastRefreshFailed: false)
    }

    struct Expect: Equatable {
        var route: LaunchDecision.Route
        var supervision: LaunchDecision.Supervision
        /// "noMatch", "ambiguous", "named", "hold" or nil.
        var refusal: String?
        /// The home launched in; "*" is any account of the fixture (an automatic pick).
        var home: String?
        var childEnv: LaunchDecision.ChildEnv?
        var envToUnset: [String]
    }

    func kind(_ refusal: LaunchDecision.Refusal?) -> String? {
        switch refusal {
        case nil: return nil
        case .noMatch?: return "noMatch"
        case .ambiguous?: return "ambiguous"
        case .named?: return "named"
        case .hold?: return "hold"
        }
    }

    /// The rules as prose (plan #424 §3a), for one cell.
    func expected(_ p: Provider, shot: Shot, pin: Pin, export: Export, flag: String?, spend: Bool,
                  optedOut: Bool) -> Expect {
        let claude = p.id == "claude"
        let leak = claude && export == .leaked
        let marker = export == .leaked
        let unset = leak ? [p.envKey, childSessionMarker] : []
        let exported: String? = leak || export == .none ? nil
            : export == .unknown ? home(p, "elsewhere") : home(p, "work1")
        let realChild = marker && !leak
        func supervised(_ route: LaunchDecision.Route) -> LaunchDecision.Supervision {
            if optedOut { return .none(.optedOut) }
            switch route {
            case .pin, .pick: return claude ? .handoff : .monitor
            case .accountFlag, .exportedHome: return claude ? .none(.handPinned) : .monitor
            case .pinHome, .bare: return claude ? .none(.noAccountRow) : .monitor
            }
        }
        func launched(_ route: LaunchDecision.Route, _ at: String, _ env: LaunchDecision.ChildEnv) -> Expect {
            Expect(route: route, supervision: supervised(route), refusal: nil, home: at,
                   childEnv: env, envToUnset: unset)
        }
        func refused(_ route: LaunchDecision.Route, _ why: String) -> Expect {
            Expect(route: route, supervision: supervised(route), refusal: why, home: nil,
                   childEnv: nil, envToUnset: unset)
        }
        let under = shot == .underReserve
        // An exported home, unless `--account` names one.
        if flag == nil, let exported {
            // Only a home the snapshot lists has a reading; a real child is never refused.
            if under && exported == home(p, "work1") && !spend && !realChild {
                return refused(.exportedHome, "named")
            }
            return launched(.exportedHome, exported, .inherit)
        }
        // `--account`: label or directory, unique or refused.
        if let flag {
            guard shot != .none else { return refused(.accountFlag, "noMatch") }
            switch flag {
            case "work1":
                return under && !spend ? refused(.accountFlag, "named")
                    : launched(.accountFlag, home(p, "work1"), .forHome)
            case "work": return refused(.accountFlag, "ambiguous")
            default: return refused(.accountFlag, "noMatch")
            }
        }
        // The manual pin. With no snapshot every pin is its denormalized home. A pin out of quota
        // never steps aside here: when it is (noneEligible), nothing else can take the launch.
        if pin != .none {
            if shot == .none {
                return launched(.pinHome, home(p, pin == .row ? "work1" : pin == .signedOut ? "out" : "gone"),
                                .forHome)
            }
            switch pin {
            case .row:
                return under && !spend ? refused(.pin, "named")
                    : launched(.pin, home(p, "work1"), .forHome)
            case .notInSnapshot: return launched(.pinHome, home(p, "gone"), .forHome)
            default: break   // signed out: picked by headroom
            }
        }
        if shot == .none { return launched(.bare, defaultHome(p), .inherit) }
        switch shot {
        case .healthy: return launched(.pick, "*", .forHome)
        case .underReserve: return spend ? launched(.pick, "*", .forHome) : refused(.pick, "hold")
        default: return launched(.bare, defaultHome(p), .inherit)
        }
    }

    var cells = 0, agreed = 0
    var firstMisses: [String] = []
    for p in providerPair {
        let names = ["work1", "work2", "solo"]
        for shot in Shot.allCases {
            for pin in Pin.allCases {
                var rows = names.map { acct(p, $0, shot) }
                if pin == .signedOut { rows.append(acct(p, "out", shot, signedOut: true)) }
                let snapshot = shot == .none ? nil : Snapshot(version: 2, generatedAt: now, accounts: rows)
                let reserves = shot == .underReserve
                    ? AccountReserves(settings: [home(p, "work1"):
                        AccountRoleSetting(role: AccountRoles.personal, reserve: 60)])
                    : AccountReserves.none
                let policy: LaunchPolicy
                switch pin {
                case .none: policy = LaunchPolicy()
                case .row: policy = LaunchPolicy(mode: "manual", pinnedAccountID: "\(p.id):work1",
                                                 pinnedHome: home(p, "work1"))
                case .notInSnapshot: policy = LaunchPolicy(mode: "manual", pinnedAccountID: "\(p.id):gone",
                                                           pinnedHome: home(p, "gone"))
                case .signedOut: policy = LaunchPolicy(mode: "manual", pinnedAccountID: "\(p.id):out",
                                                       pinnedHome: home(p, "out"))
                }
                for export in Export.allCases {
                    for flag in accountFlags {
                        for spend in [false, true] {
                            for optedOut in [false, true] {
                                var env: [String: String] = [:]
                                switch export {
                                case .none: break
                                case .knownRow: env[p.envKey] = home(p, "work1")
                                case .unknown: env[p.envKey] = home(p, "elsewhere")
                                case .leaked:
                                    env[p.envKey] = home(p, "work1"); env[childSessionMarker] = "1"
                                }
                                if optedOut { env["TALLY_AUTO_HANDOFF"] = "0" }
                                let intent = launchIntent(p, args: spend ? [spendReserveFlag] : [],
                                                          accountFlag: flag, stdoutIsTTY: true,
                                                          environment: env)
                                let d = resolveLaunch(p, intent: intent, readings: LaunchReadings(
                                    snapshot: snapshot, policy: policy, pinnedBy: "pinned in Tally",
                                    primaryModel: nil, reserves: reserves, quarantined: [],
                                    clearance: true, now: now))
                                let want = expected(p, shot: shot, pin: pin, export: export,
                                                    flag: flag, spend: spend, optedOut: optedOut)
                                let landed = d.account?.launchHome
                                let homeOK = want.home == "*"
                                    ? names.map { home(p, $0) }.contains(landed ?? "")
                                    : landed == want.home
                                let got = Expect(route: d.route, supervision: d.supervision,
                                                 refusal: kind(d.refusal), home: want.home,
                                                 childEnv: d.refusal == nil ? d.childEnv : nil,
                                                 envToUnset: d.envToUnset)
                                cells += 1
                                if got == want && homeOK { agreed += 1 } else if firstMisses.count < 5 {
                                    firstMisses.append("\(p.id) \(shot) \(pin) \(export) \(flag ?? "-") "
                                        + "spend=\(spend) optOut=\(optedOut): got \(got) home=\(landed ?? "nil"), "
                                        + "want \(want)")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    firstMisses.forEach { print("  MISS \($0)") }
    check("resolveLaunch agrees with the rules on every one of the 2048 cells (\(agreed)/\(cells))",
          cells == 2048 && agreed == cells)

    // THE SECOND TABLE: what else decides supervision - the terminal, a print flag, `--no-handoff`,
    // and Codex's first positional (`exec` is a one-shot subcommand, `resume` a session) - on the
    // two routes that supervise at all. Also whether the launcher owes the "stdout is not a
    // terminal" sentence (`pipedOnly`).
    let healthy = Snapshot(version: 2, generatedAt: now, accounts: ["work1", "work2"].flatMap {
        name in providerPair.map { acct($0, name, .healthy) } })
    var small = 0, smallAgreed = 0
    for p in providerPair {
        for tty in [true, false] {
            for print in [false, true] {
                for noHandoff in [false, true] {
                    for positional in [nil, "resume", "exec"] as [String?] {
                        for pinned in [false, true] {
                            let args = (positional.map { [$0] } ?? []) + (print ? ["-p"] : [])
                                + (noHandoff ? ["--no-handoff"] : [])
                            let intent = launchIntent(p, args: args, accountFlag: nil, stdoutIsTTY: tty,
                                                      environment: [:])
                            let policy = pinned
                                ? LaunchPolicy(mode: "manual", pinnedAccountID: "\(p.id):work2")
                                : LaunchPolicy()
                            let d = resolveLaunch(p, intent: intent, readings: LaunchReadings(
                                snapshot: healthy, policy: policy, pinnedBy: "pinned", primaryModel: nil,
                                reserves: .none, quarantined: [], clearance: false, now: now))
                            let claude = p.id == "claude"
                            let oneShot = !tty || (claude ? print : (!noHandoff && positional == "exec"))
                            let want: LaunchDecision.Supervision = oneShot ? .none(.oneShot)
                                : noHandoff ? .none(.optedOut) : claude ? .handoff : .monitor
                            let wantPiped = !tty && !noHandoff && !print
                            small += 1
                            let route: LaunchDecision.Route = pinned ? .pin : .pick
                            if d.supervision == want && intent.pipedOnly == wantPiped && d.route == route {
                                smallAgreed += 1
                            } else {
                                Swift.print("  MISS \(p.id) tty=\(tty) print=\(print) noHandoff=\(noHandoff) "
                                    + "\(positional ?? "-") pinned=\(pinned): got \(d.supervision) "
                                    + "piped=\(intent.pipedOnly), want \(want) piped=\(wantPiped)")
                            }
                        }
                    }
                }
            }
        }
    }
    check("supervision follows the terminal, print, --no-handoff and Codex's subcommand on all 96 "
          + "cells (\(smallAgreed)/\(small))", small == 96 && smallAgreed == small)
}
