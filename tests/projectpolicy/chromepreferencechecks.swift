import Foundation

// `tally project set --chrome on` (B-2281), CELL BY CELL.
//
// A project that prefers the account set for Claude in Chrome lands a NEW launch on it, but only
// through the headroom pick and only when that account passes every gate the automatic pick applies
// (eligible, not quarantined, above its owner's reserve, comfortable). Anything a person named
// (`--account`, an exported home, a project pin, the app's pin) outranks it; a pin that stepped
// aside is no longer a person's choice. The oracle below is the rule as prose and calls none of the
// code under test: every cell either lands on the Chrome account, or the decision is EXACTLY the one
// the same readings give with no Chrome account at all. Every cell is listed, none sampled.

func runChromePreferenceChecks() {
    let now = Date()
    let claude = providers[0]
    let codex = providers[1]
    func home(_ p: Provider, _ name: String) -> String { "/tmp/cp-\(p.id)-\(name)" }
    func acct(_ p: Provider, _ name: String, session: Double, weekly: Double,
              refreshFailed: Bool = false) -> Snapshot.Account {
        Snapshot.Account(
            id: "\(p.id):\(name)", provider: p.id, label: name, launchHome: home(p, name),
            sessionRemaining: session, weeklyRemaining: weekly, modelRemaining: nil,
            sessionResetsAt: now.addingTimeInterval(4 * 3600),
            weeklyResetsAt: now.addingTimeInterval(100 * 3600), modelResetsAt: nil,
            modelWindowName: nil, resetCreditsAvailable: nil, isStale: false, error: nil,
            lastRefreshFailed: refreshFailed)
    }

    enum Flag: CaseIterable { case unset, off, on }
    enum Setting: CaseIterable { case none, inSnapshot, gone }
    enum State: CaseIterable { case healthy, ineligible, spent, underReserve, quarantined, thin }
    enum Named: CaseIterable { case none, accountFlag, exportedHome, projectPin, appPin, pinStepAside }

    var cells = 0, agreed = 0, landedCells = 0
    var misses: [String] = []
    for flag in Flag.allCases {
        for setting in Setting.allCases {
            for state in State.allCases {
                for named in Named.allCases {
                    for spend in [false, true] {
                        let chrome: Snapshot.Account
                        switch state {
                        case .healthy, .underReserve, .quarantined: chrome = acct(claude, "chrome", session: 60, weekly: 60)
                        case .ineligible: chrome = acct(claude, "chrome", session: 60, weekly: 60, refreshFailed: true)
                        case .spent: chrome = acct(claude, "chrome", session: 0, weekly: 0)
                        case .thin: chrome = acct(claude, "chrome", session: 3, weekly: 60)
                        }
                        let snapshot = Snapshot(version: 2, generatedAt: now, accounts: [
                            acct(claude, "work", session: 90, weekly: 90), chrome,
                            acct(claude, "dry", session: 0, weekly: 0)])
                        let reserves = state == .underReserve
                            ? AccountReserves(settings: [home(claude, "chrome"):
                                AccountRoleSetting(role: AccountRoles.personal, reserve: 70)])
                            : AccountReserves.none
                        let quarantined: Set<String> = state == .quarantined ? ["claude:chrome"] : []
                        var policy = LaunchPolicy()
                        var accountFlag: String?
                        var env: [String: String] = [:]
                        switch named {
                        case .none: break
                        case .accountFlag: accountFlag = "work"
                        case .exportedHome: env[claude.envKey] = home(claude, "work")
                        case .projectPin:
                            policy = effectivePolicy(LaunchPolicy(), project: ProjectPolicy(accountID: "claude:work"))
                        case .appPin:
                            policy = LaunchPolicy(mode: "manual", pinnedAccountID: "claude:work",
                                                  pinnedHome: home(claude, "work"))
                        case .pinStepAside:
                            policy = LaunchPolicy(mode: "manual", pinnedAccountID: "claude:dry",
                                                  pinnedHome: home(claude, "dry"))
                        }
                        let project: ProjectPolicy
                        switch flag {
                        case .unset: project = ProjectPolicy()
                        case .off: project = ProjectPolicy(chrome: false)
                        case .on: project = ProjectPolicy(chrome: true)
                        }
                        let settingValue: String?
                        switch setting {
                        case .none: settingValue = nil
                        case .inSnapshot: settingValue = "claude:chrome"
                        case .gone: settingValue = "claude:gone"
                        }
                        let intent = launchIntent(claude, args: spend ? [spendReserveFlag] : [],
                                                  accountFlag: accountFlag, stdoutIsTTY: true,
                                                  environment: env)
                        func readings(_ chromeAccount: String?) -> LaunchReadings {
                            LaunchReadings(snapshot: snapshot, policy: policy, pinnedBy: "pinned in Tally",
                                           primaryModel: nil, reserves: reserves, quarantined: quarantined,
                                           clearance: true, now: now, chromeAccount: chromeAccount)
                        }
                        let got = resolveLaunch(claude, intent: intent,
                                                readings: readings(launchChromeAccount(project, setting: settingValue)))
                        let plain = resolveLaunch(claude, intent: intent, readings: readings(nil))
                        let lands = flag == .on && setting == .inSnapshot && state == .healthy
                            && (named == .none || named == .pinStepAside)
                        var ok: Bool
                        if lands {
                            landedCells += 1
                            ok = got.route == .pick && got.account?.id == "claude:chrome"
                                && got.clearanceAccount == nil && got.refusal == nil
                                && got.supervision == .handoff
                                && got.notices.last == got.account.map(chromeLaunchNotice)
                                && plain.account?.id != "claude:chrome"
                            if named == .pinStepAside {
                                ok = ok && got.stepAside?.id == "claude:dry"
                                    && got.notices.count == 2
                                    && got.notices.first == pinStepAsideNotice(got.stepAside!, pinnedBy: "pinned in Tally")
                            }
                        } else {
                            ok = got == plain
                        }
                        cells += 1
                        if ok { agreed += 1 } else if misses.count < 5 {
                            misses.append("flag=\(flag) setting=\(setting) state=\(state) named=\(named) "
                                + "spend=\(spend): got \(got.route) \(got.account?.id ?? "nil")")
                        }
                    }
                }
            }
        }
    }
    misses.forEach { print("  MISS \($0)") }
    check("a Chrome-preferring launch lands on the Chrome account exactly where the rule says "
          + "and changes nothing elsewhere (\(agreed)/\(cells))",
          cells == 648 && agreed == cells)
    check("the table has landing cells (4 of them: on, in snapshot, healthy, two ways to be unnamed, spend or not)"
          + " so an all-unchanged table cannot pass",
          landedCells == 4)

    // Codex: the setting names a claude account, so a codex launch never finds it in its field.
    let codexSnapshot = Snapshot(version: 2, generatedAt: now, accounts: [
        acct(codex, "work", session: 90, weekly: 90), acct(codex, "chrome", session: 60, weekly: 60)])
    func codexDecision(_ chromeAccount: String?) -> LaunchDecision {
        resolveLaunch(codex, intent: launchIntent(codex, args: [], accountFlag: nil, stdoutIsTTY: true,
                                                  environment: [:]),
                      readings: LaunchReadings(snapshot: codexSnapshot, policy: LaunchPolicy(),
                                               pinnedBy: "pinned in Tally", primaryModel: nil,
                                               reserves: .none, quarantined: [], clearance: true,
                                               now: now, chromeAccount: chromeAccount))
    }
    check("a codex launch ignores the Chrome account",
          codexDecision("claude:chrome") == codexDecision(nil))

    // The flag-to-account function: only (on, a setting) yields an account, and off never reads it.
    var smallOK = true
    for chrome in [nil, false, true] as [Bool?] {
        for setting in [nil, "claude:x"] as [String?] {
            let want = chrome == true ? setting : nil
            if launchChromeAccount(ProjectPolicy(chrome: chrome), setting: setting) != want { smallOK = false }
        }
    }
    check("launchChromeAccount answers the setting only when the project turned the preference on", smallOK)
    var read = false
    _ = launchChromeAccount(ProjectPolicy(chrome: false), setting: { read = true; return "claude:x" }())
    _ = launchChromeAccount(ProjectPolicy(), setting: { read = true; return "claude:x" }())
    check("an off or unset preference never reads the setting", !read)

    // The file: additive, older documents unchanged.
    func decoded(_ json: String) -> ProjectPolicy? {
        try? JSONDecoder().decode(ProjectPolicy.self, from: Data(json.utf8))
    }
    check("a profile written before the field existed reads chrome as nil",
          decoded(#"{"model":"opus"}"#)?.chrome == nil && decoded(#"{"model":"opus"}"#)?.model == "opus")
    check("chrome true and false read back as written",
          decoded(#"{"chrome":true}"#)?.chrome == true && decoded(#"{"chrome":false}"#)?.chrome == false)
    check("a profile that sets only chrome is not empty, on or off",
          !ProjectPolicy(chrome: true).isEmpty && !ProjectPolicy(chrome: false).isEmpty
              && ProjectPolicy().isEmpty)
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("cp-\(UUID().uuidString)/project-policies.json")
    do {
        try saveProjectPolicies(ProjectPolicyFile(projects: ["/r": ["claude": ProjectPolicy(model: "opus")]]), to: tmp)
        let plainText = (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
        try saveProjectPolicies(ProjectPolicyFile(projects: ["/r": ["claude": ProjectPolicy(chrome: true)]]), to: tmp)
        check("a profile without the preference is written without the key, one with it round-trips",
              !plainText.contains("chrome") && !plainText.isEmpty
                  && loadProjectPolicies(tmp).policy("claude", for: "/r").chrome == true)
    } catch {
        check("the policy file round-trip ran (\(error.localizedDescription))", false)
    }
    try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())
    check("the summary says chrome on or off, joined to the rest",
          projectPolicySummary(ProjectPolicy(chrome: true)) == "chrome on"
              && projectPolicySummary(ProjectPolicy(chrome: false)) == "chrome off"
              && projectPolicySummary(ProjectPolicy(model: "opus", chrome: true)) == "model opus · chrome on")

    // `set`: a bad or codex-bound --chrome is refused before the file is read, like the other axes.
    let commandSource = (try? String(contentsOfFile: "TallyCLI/ProjectCommand.swift", encoding: .utf8)) ?? ""
    let set = topLevelFunction("runProjectSet", in: commandSource)
    let refuseRange = set.range(of: "--chrome takes on or off")
    let codexRange = set.range(of: "--chrome is for claude only")
    let readRange = set.range(of: "readProjectPoliciesForWrite()")
    func refusesBeforeRead(_ r: Range<String.Index>?) -> Bool {
        guard let r, let read = readRange, r.lowerBound < read.lowerBound else { return false }
        let tail = set[r.lowerBound...].prefix(200)
        return tail.contains("nothing was changed") && tail.contains("return 2")
    }
    check("--chrome refuses a bad value and a codex profile before reading the file, changing nothing",
          refusesBeforeRead(refuseRange) && refusesBeforeRead(codexRange))
}
