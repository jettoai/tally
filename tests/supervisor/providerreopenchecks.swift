import Foundation

// B-1706: a `tally session clear` (and `tally start`) open new windows with the project's declared
// default provider (TallyCLI/ProviderReopen.swift). The rule, the landing that carries it, and the
// tick's answer.

func runProviderReopenChecks() {
    let yes: (String) -> Bool = { _ in true }
    let no: (String) -> Bool = { _ in false }
    func reopen(_ current: String, _ declared: String?, installed: (String) -> Bool = { _ in true },
                launchable: (String) -> Bool = { _ in true }) -> String? {
        clearReopenProvider(current: current, declared: declared, installed: installed,
                            launchable: launchable)
    }
    check("reopen: a Claude window in a Codex project reopens as Codex", reopen("claude", "codex") == "codex")
    check("reopen: a Claude window in a Claude project keeps its own /clear", reopen("claude", "claude") == nil)
    check("reopen: nothing declared is nothing to reopen as", reopen("claude", nil) == nil && reopen("codex", nil) == nil)
    check("reopen: a Codex window reopens as a fresh Codex window", reopen("codex", "codex") == "codex")
    check("reopen: a Codex window in a Claude project reopens as Claude", reopen("codex", "claude") == "claude")
    check("reopen: a target that is not installed is not offered", reopen("claude", "codex", installed: no) == nil)
    check("reopen: a target with no account to launch on is not offered",
          reopen("claude", "codex", launchable: no) == nil && reopen("codex", "claude", launchable: no) == nil)

    var targetAsked = 0
    func oldSup(_ version: String?, _ target: String?) -> String? {
        sessionClearReopenUnsupported(supervisorVersion: version,
                                      reopenTarget: { targetAsked += 1; return target }())
    }
    let refused = oldSup("0.85.35", "codex") ?? ""
    check("old supervisor: a clear due to reopen is refused, naming the version, target and way out",
          refused.contains("runs 0.85.35") && refused.contains("as codex")
              && refused.contains("`tally reload --self`") && refused.contains("`tally session clear` again"))
    targetAsked = 0
    check("old supervisor: 0.85.36 and later are let through without reading the target",
          oldSup("0.85.36", "codex") == nil && oldSup("0.86.0", "codex") == nil && oldSup("0.85.100", "codex") == nil
              && targetAsked == 0)
    check("old supervisor: no reopen due (same provider) is let through", oldSup("0.85.35", nil) == nil)
    check("old supervisor: an unreadable version is refused, as --composer-only is",
          (oldSup(nil, "codex") != nil) == (sessionInputComposerOnlyUnsupported(supervisorVersion: nil) != nil)
              && oldSup(nil, "codex")?.contains("does not report its version") == true)

    check("start: nothing declared starts claude", startProviderID(declared: nil, installed: yes) == "claude")
    check("start: claude declared starts claude", startProviderID(declared: "claude", installed: no) == "claude")
    check("start: codex declared and installed starts codex", startProviderID(declared: "codex", installed: yes) == "codex")
    check("start: codex declared but missing starts claude", startProviderID(declared: "codex", installed: no) == "claude")

    // MARK: - The landing

    let t0 = Date(timeIntervalSince1970: 1_786_571_200)
    func request(_ offset: TimeInterval = 0, text: String = windowClearCommand,
                 intent: String? = sessionClearIntent) -> SessionInputRequest {
        SessionInputRequest(epoch: Int(t0.addingTimeInterval(offset).timeIntervalSince1970 * 1000),
                            text: text, waitSeconds: 6, intent: intent)
    }
    let account = Snapshot.Account(id: "B", provider: "claude", label: "Claude 2", launchHome: "/tmp/B",
                                   sessionRemaining: 80, weeklyRemaining: 80, modelRemaining: 80,
                                   sessionResetsAt: nil, weeklyResetsAt: nil, modelResetsAt: nil,
                                   modelWindowName: nil, resetCreditsAvailable: nil, isStale: false,
                                   error: nil)
    var typed: [String] = []
    var boundaryAsked = 0, reopenAsked = 0
    func land(_ request: SessionInputRequest, state: SupervisedState = .idle, target: String?,
              draft: SessionInputDraftGuard = .none) -> SessionInputLanding {
        typed = []; boundaryAsked = 0; reopenAsked = 0
        return landSessionInput(request, sessionKey: "9501", state: state, draft: draft,
                                agents: { _ in 2 },
                                boundary: { boundaryAsked += 1; return account },
                                reopen: { reopenAsked += 1; return target },
                                inject: { text, _ in typed.append(text); return .done })
    }
    check("landing: a reopen target closes the window without typing and without the account question",
          land(request(), target: "codex") == .reopened("codex", agents: 2) && typed.isEmpty
              && boundaryAsked == 0)
    // B-1706: a guarded clear that is due to reopen used to type /clear, leaving the window on the
    // provider the project no longer uses while the caller was told it was cleared.
    let suspected = sessionInputDraftGuard(dialog: false, suspected: true)
    check("landing: a blocked session due to reopen is held, typing nothing and moving nothing",
          land(request(), state: .blocked, target: "codex") == .reopenHeld("codex", blocked: true)
              && typed.isEmpty && boundaryAsked == 0)
    check("landing: a suspected draft due to reopen is held, typing nothing and moving nothing",
          land(request(), target: "codex", draft: suspected) == .reopenHeld("codex", blocked: false)
              && typed.isEmpty && boundaryAsked == 0)
    check("landing: a suspected draft with no reopen due still types /clear, without the account question",
          land(request(), target: nil, draft: suspected) == .typed(.done, agents: 2)
              && typed == [windowClearCommand] && boundaryAsked == 0)
    check("landing: a held reopen ended no agents", land(request(), target: "codex", draft: suspected).agents == nil)
    check("landing: a plain send of /clear never asks the reopen",
          land(request(intent: nil), target: "codex") == .typed(.done, agents: 2) && reopenAsked == 0)
    check("landing: no reopen target falls through to the account move, as before",
          land(request(), target: nil) == .moved(account, agents: 2) && reopenAsked == 1)

    // MARK: - Through the tick

    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-providerreopen-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    var input = SessionInputState(sessionKey: "9502", servedEpoch: 0, dir: dir)
    try? writeSessionInputRequest(request(), sessionKey: "9502", dir: dir)
    var tickTyped: [String] = []
    let action = applySessionInput(&input, session: .idle, quiet: .quiet, turnEnded: { false },
                                   keyboardIdle: true, relaunchPlanned: false, draftSuspected: false,
                                   waitingOnPerson: false, dir: dir,
                                   log: dir.appendingPathComponent("input.log"),
                                   now: t0.addingTimeInterval(1), agents: { _ in nil },
                                   reopen: { "codex" }) { text, _ in tickTyped.append(text); return .done }
    let receipt = readSessionInputResult(sessionKey: "9502", dir: dir)
    check("tick: a reopen types nothing, leaves the repick alone and hands the provider up",
          tickTyped.isEmpty && action.typed == nil && action.repick == .untouched
              && action.moveTo == nil && action.reopenAs == "codex")
    check("tick: the receipt says reopened-provider and reads as delivered",
          receipt?.outcome == "reopened-provider" && receipt?.delivered == true
              && receipt?.detail == "reopened as codex instead of typing")

    var heldInput = SessionInputState(sessionKey: "9503", servedEpoch: 0, dir: dir)
    try? writeSessionInputRequest(request(), sessionKey: "9503", dir: dir)
    var heldTyped: [String] = []
    let held = applySessionInput(&heldInput, session: .idle, quiet: .quiet, turnEnded: { false },
                                 keyboardIdle: true, relaunchPlanned: false, draftSuspected: true,
                                 waitingOnPerson: false, dir: dir,
                                 log: dir.appendingPathComponent("input.log"),
                                 now: t0.addingTimeInterval(1), agents: { _ in nil },
                                 reopen: { "codex" }) { text, _ in heldTyped.append(text); return .done }
    let heldReceipt = readSessionInputResult(sessionKey: "9503", dir: dir)
    check("tick: a held reopen types nothing and hands nothing up",
          heldTyped.isEmpty && held.typed == nil && held.moveTo == nil && held.reopenAs == nil)
    check("tick: a held reopen is refused, not delivered, and says why and what to run",
          heldReceipt?.outcome == "refused-reopen-held" && heldReceipt?.delivered == false
              && heldReceipt.map { sessionInputExitCode($0) } == 3
              && heldReceipt?.detail?.contains("reopen as codex") == true
              && heldReceipt?.detail?.contains("15 minutes") == true
              && heldReceipt?.detail?.contains("`tally codex --new`") == true)
    check("tick: the blocked wording names the dialog instead",
          sessionClearReopenHeldDetail(provider: "codex", blocked: true).contains("dialog"))

    // MARK: - The wiring no value can be asked about (read off the source, as the suites beside this do)

    let command = (try? String(contentsOfFile: "TallyCLI/SessionInputCommand.swift", encoding: .utf8)) ?? ""
    // Measured 2026-10-13: before this, `tally session clear` in a Codex window was refused by the
    // CLI ("monitoring only ... clear ... controls") and never reached the supervisor that reopens.
    check("wiring: a clear to a Codex session rides the send's capability check, not the control refusal",
          command.contains("if let refusal = sessionSendRefusal(pid: sessionKey, dir: supervisorStateDir) {")
              && command.contains("if requestIntent != sessionClearIntent, SessionMonitoring.isMarked("))
    let reopenSource = (try? String(contentsOfFile: "TallyCLI/ProviderReopen.swift", encoding: .utf8)) ?? ""
    // Measured 2026-10-13: without `--new` the reopened `tally codex` resumed the directory's last
    // conversation (continue-by-default) instead of opening the empty window a clear asks for.
    check("wiring: the reopen execs a NEW window", reopenSource.contains(#"["tally", providerID, "--new"]"#))
    let codexSource = (try? String(contentsOfFile: "TallyCLI/CodexSupervisor.swift", encoding: .utf8)) ?? ""
    // Measured 2026-10-13: a supervisor blocked in waitpid stopped reading the PTY and the Codex
    // child hung in exit; the reopen has to signal and keep pumping.
    check("wiring: the Codex reopen signals the child and keeps pumping rather than blocking on it",
          codexSource.contains("kill(child, SIGTERM)\n                    reopenAs = next")
              && !codexSource.contains("endChildTree(&reaper"))
}
