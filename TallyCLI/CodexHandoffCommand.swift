import Foundation

// The asking half of moving a Codex window to another Codex account (B-2096): `tally account <name>
// [--session <pid>]` lands here when the session it addresses is a Codex supervisor. The rules and
// the supervisor side are CodexHandoff.swift; the Claude path (SwitchCommand.swift) is untouched.

/// What `tally account` addressed: a Codex window, something this command does not move with a
/// reason, or nothing Codex (the Claude path carries on exactly as before).
enum CodexAddress: Equatable {
    case notCodex
    case codex(String)
    case refused(String)
}

/// `--session <pid>` names a window outright; without it the marker and the directory address it
/// the way every other session command does. Only a Codex window answers `.codex`.
func codexSessionAddressed(sessionPID: String?, cwd: String, marker: SessionMarkerTrust,
                           dir: URL = supervisorStateDir) -> CodexAddress {
    func isCodex(_ key: String) -> Bool { SessionMonitoring.read(pid: key, dir: dir)?.provider == "codex" }
    if let sessionPID {
        switch namedSession(sessionPID, dir: dir) {
        case .session(let key), .monitoringOnly(let key):
            return isCodex(key) ? .codex(key)
                : .refused("--session moves Codex windows only; run `tally account <name>` inside that Claude session instead")
        case .notRunning, .notSupervised:
            return .refused("that pid is not a session this machine supervises")
        }
    }
    if case .session(let key) = marker.resolve(here: supervisorsInDirectory(cwd, dir: dir)), isCodex(key) {
        return .codex(key)
    }
    return .notCodex
}

/// Ask the supervisor of Codex window `pid` to continue its conversation on another Codex account.
/// Everything is decided here while the person can still act, and again by the supervisor at the
/// turn boundary; nothing is written unless this side can say the move is possible.
func attemptCodexHandoff(_ intent: SwitchIntent, pid: String, snapshot: Snapshot?, notes: [String],
                         cwd: String, reserveGate: Bool, dir: URL = supervisorStateDir,
                         receiptPolls: Int = 50) -> SwitchAttempt {
    var notes = notes
    let target: Snapshot.Account
    switch intent {
    case .auto:
        return .refusal("--auto does not apply to a Codex window: it has no account pin to release",
                        notes: notes)
    case .pin(let name):
        switch accountMatching(name, provider: "codex", in: snapshot) {
        case .one(let match): target = match
        case .none: return .refusal("no codex account matches \"\(name)\" - try `tally status`", notes: notes)
        case .several(let candidates):
            return .refusal(accountMatchAmbiguity(name, provider: "codex", candidates: candidates), notes: notes)
        }
    case .pinAccount(let id):
        guard let match = snapshot?.accounts.first(where: {
            $0.id == id && $0.provider == "codex" && $0.launchHome != nil
        }) else {
            return .refusal("the account that row named (\(id)) is not in the fleet snapshot any more - "
                            + "try `tally status`", notes: notes)
        }
        target = match
    }
    guard let home = target.launchHome else {
        return .refusal("\(target.label) has no usable login to move this conversation to", notes: notes)
    }
    // The exec'd launch finds the account by its config-dir name: it must reach this one and no other.
    guard case .one(let reached) = accountMatching(URL(fileURLWithPath: home).lastPathComponent,
                                                   provider: "codex", in: snapshot), reached.id == target.id else {
        return .refusal("\(target.label) shares a name with another codex account, so a hand-off cannot "
                        + "name it unambiguously", notes: notes)
    }
    if readSupervisorAccount(pid: pid, dir: dir) == target.id {
        return SwitchAttempt(result: .alreadyThere, message: "already on \(target.label)", notes: notes)
    }
    if reserveGate, let refusal = namedReserveRefusal(target,
        primaryModel: effectivePolicy(launchPolicy("codex"), project: projectPolicy("codex", cwd: cwd)).model,
        reserves: accountReserves()) {
        return .refusal(refusal, notes: notes)
    }
    let thread: String
    switch codexHandoffSource(pid: pid, targetHome: home,
                              fallbackDirectory: readSupervisorCwd(pid: pid, dir: dir), dir: dir) {
    case .refused(let why): return .refusal(why, notes: notes)
    case .ready(let id, _): thread = id
    }
    if let other = codexHandoffOtherWriter(thread: thread, pid: pid, dir: dir) {
        return .refusal(other, notes: notes)
    }
    if headroom(target) <= 0 {
        notes.append("\(target.label) is out of quota - moving anyway (you asked)")
    }
    let request = CodexHandoffRequest(nonce: UUID().uuidString, accountID: target.id, threadID: thread,
                                      spendReserve: !reserveGate, at: Date())
    let requestURL = dir.appendingPathComponent(pid + codexHandoffSuffix)
    let receiptURL = dir.appendingPathComponent(pid + codexHandoffReceiptSuffix)
    try? FileManager.default.removeItem(at: receiptURL)
    guard let data = try? startupChoiceEncoder().encode(request), writePrivateAtomically(data, to: requestURL) else {
        return .refusal("cannot write \(requestURL.path)", notes: notes)
    }
    var receipt: CodexHandoffReceipt?
    for _ in 0..<receiptPolls where receipt == nil {
        usleep(100_000)
        receipt = (try? Data(contentsOf: receiptURL))
            .flatMap { try? startupChoiceDecoder().decode(CodexHandoffReceipt.self, from: $0) }
            .flatMap { $0.nonce == request.nonce ? $0 : nil }
    }
    guard let receipt else {
        try? FileManager.default.removeItem(at: requestURL)
        return .refusal("the supervisor did not answer (it may predate this command)", notes: notes)
    }
    try? FileManager.default.removeItem(at: receiptURL)
    guard receipt.result == codexHandoffQueued else { return .refusal(receipt.result, notes: notes) }
    return SwitchAttempt(
        result: .queued,
        message: "hands this Codex conversation to \(target.label) when the current turn ends; Codex "
            + "resumes it there and spends one short turn on that account to initialise",
        notes: notes)
}
