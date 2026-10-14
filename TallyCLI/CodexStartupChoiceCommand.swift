import Darwin
import Foundation

// `tally session skip-update`: the asking half of CodexStartupChoice.swift. Writes one request
// beside the supervisor's state, waits for its receipt, then reads back that the menu is gone.

let sessionSkipUpdateUsage = """
tally session skip-update --session <pid> --screen <id>

Answer the startup screen a supervised Codex window is stuck on before its prompt: Skip on the
update menu (Tally then updates Codex in the background), "Use existing model" on the new-model
announcement (the model Tally launched with stays), or "Trust and continue" on the trust screen of
a folder opened for the first time (saved, as when chosen in the window). <id> is
`startupScreen.screenID` from `tally status --json`; a screen drawn since then is refused, never
guessed, and a screen Tally does not answer (`startupScreen.answer` absent) is refused.

Exit codes: 0 the screen was answered (the prompt, or the next screen and its id, is printed);
2 usage; 3 refused or unconfirmed (the reason is printed).
"""

func runSessionSkipUpdate(args: [String], dir: URL = supervisorStateDir) -> Int32 {
    var session: String?, screen: String?
    var rest = args[...]
    while let flag = rest.popFirst() {
        switch flag {
        case "--session": session = rest.popFirst()
        case "--screen": screen = rest.popFirst()
        default: warn(sessionSkipUpdateUsage); return 2
        }
    }
    guard let session, let screen, screen.hasPrefix("scr_") else { warn(sessionSkipUpdateUsage); return 2 }
    let pid: String
    switch namedSession(session, dir: dir) {
    case .session(let key), .monitoringOnly(let key): pid = key
    case .notRunning, .notSupervised: warn("not a supervised Codex session"); return 3
    }
    guard SessionMonitoring.read(pid: pid, dir: dir)?.provider == "codex" else {
        warn("not a supervised Codex session")
        return 3
    }
    func log(_ result: String) {
        appendSessionInputLine("\(ISO8601DateFormatter().string(from: Date())) pid=\(pid) "
            + "input=startup-skip result=\(result) screen=\(screen)\n", to: sessionInputLog)
    }
    guard let shownScreen = readSessionState(pid: pid, dir: dir)?.startupScreen, let shown = shownScreen.screenID else {
        warn("that window is not on a Codex startup screen Tally can answer")
        return 3
    }
    guard shown == screen else {
        warn("the menu changed since it was shown; reload and press again")
        return 3
    }
    guard let answer = shownScreen.answer
            ?? CodexStartupScreen.answerLabel(title: shownScreen.title, lines: shownScreen.lines) else {
        warn("Codex is showing \"\(shownScreen.title ?? "a screen")\", which Tally does not answer; answer it in the window")
        return 3
    }
    let request = StartupChoiceRequest(screenID: screen, nonce: UUID().uuidString, at: Date())
    let requestURL = dir.appendingPathComponent(pid + startupChoiceSuffix)
    let receiptURL = dir.appendingPathComponent(pid + startupChoiceReceiptSuffix)
    try? FileManager.default.removeItem(at: receiptURL)
    guard let data = try? startupChoiceEncoder().encode(request), writePrivateAtomically(data, to: requestURL) else {
        warn("could not write the request")
        return 3
    }
    log("requested")
    warn("asked the supervisor (pid \(pid)) to choose \(answer)")
    var receipt: StartupChoiceReceipt?
    for _ in 0..<50 where receipt == nil {
        usleep(100_000)
        receipt = (try? Data(contentsOf: receiptURL))
            .flatMap { try? startupChoiceDecoder().decode(StartupChoiceReceipt.self, from: $0) }
            .flatMap { $0.nonce == request.nonce ? $0 : nil }
    }
    guard let receipt else {
        try? FileManager.default.removeItem(at: requestURL)
        log("no-receipt")
        warn("the supervisor did not answer (it may predate this command)")
        return 3
    }
    try? FileManager.default.removeItem(at: receiptURL)
    log(receipt.result)
    guard receipt.result == "sent" else {
        warn("not sent: \(receipt.result)")
        return 3
    }
    warn("keys sent; waiting for Codex's prompt")
    // What follows the answered screen is only reported once it has held for 2.5s: codex can pass
    // through a blank frame or its composer between the update menu and the announcement.
    var settling: (outcome: StartupAnswerOutcome, since: Date)?
    for _ in 0..<150 {
        let state = readSessionState(pid: pid, dir: dir)
        let outcome = startupAnswerOutcome(stateFound: state != nil, screen: state?.startupScreen,
                                          answered: shownScreen.title)
        switch outcome {
        case .sessionEnded:
            log("session-ended")
            warn("keys sent but the session ended before Codex reached its prompt")
            return 3
        case .stillUp:
            settling = nil
        case .prompt, .next:
            if settling?.outcome != outcome { settling = (outcome, Date()) }
        }
        if let settling, Date().timeIntervalSince(settling.since) >= 2.5 {
            guard case .next(let next) = outcome else {
                log("reached-prompt")
                print("answered: Codex reached its prompt")
                return 0
            }
            log("next-screen")
            let id = next.screenID.map { "; answer it with: tally session skip-update --session \(pid) --screen \($0)" } ?? ""
            print("answered: Codex now shows \"\(next.title ?? "an unrecognized screen")\"\(id)")
            return 0
        }
        usleep(100_000)
    }
    log("still-up")
    warn("keys sent but the screen is still up")
    return 3
}

/// The supervisor's answer, read by the command above.
func writeStartupChoiceReceipt(_ receipt: StartupChoiceReceipt, pid: String, dir: URL = supervisorStateDir) {
    guard let data = try? startupChoiceEncoder().encode(receipt) else { return }
    _ = writePrivateAtomically(data, to: dir.appendingPathComponent(pid + startupChoiceReceiptSuffix))
}

/// Owner-only from the first byte: written beside the target under a temporary name, then renamed.
func writePrivateAtomically(_ data: Data, to url: URL) -> Bool {
    let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(getpid())")
    guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                         attributes: [.posixPermissions: 0o600]) else { return false }
    guard rename(temporary.path, url.path) == 0 else {
        try? FileManager.default.removeItem(at: temporary)
        return false
    }
    return true
}
