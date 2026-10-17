import Foundation

// Moving a live Codex window to another Codex account (B-2096), the supervisor-side half and the
// pure rules. `tally account <name> --session <pid>` writes one request beside the supervisor's
// state; the supervisor reads it each tick, waits for a turn boundary, ends its child, and execs
// `tally codex --account <target> resume <thread id>` in the conversation's own directory, the same
// shape as a `tally session clear` reopen (ProviderReopen.swift). The asking half is
// CodexHandoffCommand.swift.
//
// Which account the window runs on is read from the home the NEW supervisor launches the child with,
// never from the rollout: its first line keeps naming the account that opened the conversation,
// and no code here or anywhere reads that field (a suite locks it).

/// The request and its receipt (listed by literal in `supervisorStateSuffixes`, as `.codex-binding`
/// is, because PendingNotice.swift compiles into suites that do not carry this file).
let codexHandoffSuffix = ".codex-handoff"
let codexHandoffReceiptSuffix = ".codex-handoff-receipt"
let codexHandoffLife: TimeInterval = 15
let codexHandoffQueued = "queued"

struct CodexHandoffRequest: Codable, Equatable {
    var nonce: String
    var accountID: String
    var threadID: String
    /// The asker's own `--spend-reserve`: the supervisor was launched without it, and the exec'd
    /// launch would refuse a target under its reserve after the old child is already gone.
    var spendReserve: Bool
    var at: Date
}

struct CodexHandoffReceipt: Codable, Equatable {
    var nonce: String
    /// `codexHandoffQueued`, or the sentence saying why nothing was queued.
    var result: String
}

/// What an accepted request needs to carry out the move, all of it re-read by the supervisor.
struct CodexHandoffPlan: Equatable {
    var threadID: String
    var directory: String
    var targetHome: String
    var spendReserve: Bool
}

/// The conversation a hand-off would carry, or why it cannot.
enum CodexHandoffSource: Equatable {
    case ready(threadID: String, directory: String)
    case refused(String)
}

/// `tui.resume_cwd` is Codex's own spelling (codex-cli 0.163.0 errors on an unknown value and
/// ignores a top-level `resume_cwd`, measured 2026-10-17): without it a resume from a different
/// directory stops at the "Working directory · resume" chooser.
let codexHandoffResumeCwdOverride = "tui.resume_cwd=\"session\""

/// What the supervisor execs. The config-dir name goes through `accountMatching`'s exact stage, the
/// same one `tally codex --account` uses. `resume <id>` is the first positional, so
/// `applyCodexStartMode` leaves it alone.
func codexHandoffArgv(targetHome: String, threadID: String, spendReserve: Bool) -> [String] {
    ["tally", "codex", "--account", URL(fileURLWithPath: targetHome).lastPathComponent]
        + (spendReserve ? ["--spend-reserve"] : [])   // `spendReserveFlag`, which this file's suite does not compile
        + ["resume", threadID, "-c", codexHandoffResumeCwdOverride]
}

/// The conversation this supervisor's window holds, as its own session hook reported it, or why a
/// hand-off cannot carry it. Nothing is guessed from a file name or a "latest session" scan.
func codexHandoffSource(pid: String, targetHome: String, fallbackDirectory: String?,
                        dir: URL = supervisorStateDir) -> CodexHandoffSource {
    guard let identity = SessionMonitoring.read(pid: pid, dir: dir), identity.provider == "codex",
          let bytes = try? Data(contentsOf: dir.appendingPathComponent(pid + ".codex-binding")),
          let binding = try? JSONDecoder().decode(CodexSessionBinding.self, from: bytes),
          binding.nonce == identity.nonce, UUID(uuidString: binding.sessionID) != nil else {
        return .refused("this Codex window has not reported its conversation yet; send one prompt first")
    }
    let sourceHome = identity.home
    guard let transcript = codexTranscriptURL(path: binding.transcriptPath, home: sourceHome),
          transcript.lastPathComponent.lowercased().hasSuffix("-" + binding.sessionID.lowercased() + ".jsonl") else {
        return .refused("this window's conversation file is not where Codex keeps its sessions")
    }
    func resolved(_ home: String, _ sub: String) -> String {
        URL(fileURLWithPath: home).appendingPathComponent(sub).resolvingSymlinksInPath().standardizedFileURL.path
    }
    guard resolved(targetHome, "sessions") == resolved(sourceHome, "sessions") else {
        return .refused("the target account does not share this conversation's history")
    }
    guard !transcript.path.hasPrefix(resolved(sourceHome, "archived_sessions") + "/") else {
        return .refused("this conversation is archived, and resuming an archived one is not supported")
    }
    var isDirectory: ObjCBool = false
    guard let directory = binding.directory ?? fallbackDirectory,
          FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
        return .refused("the directory this conversation runs in cannot be found")
    }
    return .ready(threadID: binding.sessionID, directory: directory)
}

/// Every thread a live Codex supervisor of this machine holds, with the pid that holds it (the
/// same proof as the automatic-resume guard: a binding whose nonce is the supervisor's own).
func liveCodexConversationOwners(dir: URL = supervisorStateDir) -> [(thread: String, pid: String)] {
    var owners: [(thread: String, pid: String)] = []
    for pid in SessionMonitoring.markedPids(dir: dir) {
        let key = String(pid)
        guard let identity = SessionMonitoring.read(pid: key, dir: dir), identity.provider == "codex",
              let bytes = try? Data(contentsOf: dir.appendingPathComponent(key + ".codex-binding")),
              let binding = try? JSONDecoder().decode(CodexSessionBinding.self, from: bytes),
              binding.nonce == identity.nonce else { continue }
        owners.append((binding.sessionID, key))
    }
    return owners
}

/// Another live head on the same conversation would be a second writer to one rollout.
func codexHandoffOtherWriter(thread: String, pid: String, dir: URL = supervisorStateDir) -> String? {
    liveCodexConversationOwners(dir: dir).contains { $0.thread == thread && $0.pid != pid }
        ? "another Codex window holds this conversation, so moving it would start a second writer" : nil
}

/// The turn boundary, as the reason the move still waits, nil when it may go: the answer is
/// complete, nothing is pending on a person, the composer holds no unsent text, nobody is typing,
/// and nothing is mid-flight into the terminal.
func codexHandoffGate(turnEnded: Bool, permissionPending: Bool, questionPending: Bool,
                      draftSuspected: Bool, keyboardIdle: Bool, inputPending: Bool,
                      inputQueued: Bool) -> String? {
    if !turnEnded { return "a turn is still running" }
    if permissionPending { return "Codex is waiting on a permission" }
    if questionPending { return "Codex is waiting on an answer" }
    if draftSuspected { return "the composer may hold unsent text" }
    if !keyboardIdle { return "someone is typing" }
    if inputPending { return "terminal input is in flight" }
    if inputQueued { return "a `tally session send` is queued" }
    return nil
}

func writeCodexHandoffReceipt(_ receipt: CodexHandoffReceipt, pid: String, dir: URL = supervisorStateDir) {
    // A sentence and a nonce, nothing private: atomic is enough (the request side is written 0600).
    guard let data = try? startupChoiceEncoder().encode(receipt) else { return }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? data.write(to: dir.appendingPathComponent(pid + codexHandoffReceiptSuffix), options: .atomic)
}

/// Serves one pending request: read and removed, decided against the state of this tick, receipted
/// either way. `busy` names a reason this window cannot take it now (a clear is reopening it, one
/// hand-off is already queued); `targetHome` answers an account id with its launch home, nil when
/// the fleet no longer has it. Returns the plan only for a request that was queued.
@discardableResult
func serveCodexHandoff(pid: String, busy: String?, targetHome: (String) -> String?,
                       fallbackDirectory: @autoclosure () -> String?, dir: URL = supervisorStateDir,
                       now: Date = Date()) -> CodexHandoffPlan? {
    let url = dir.appendingPathComponent(pid + codexHandoffSuffix)
    guard let data = try? Data(contentsOf: url) else { return nil }
    try? FileManager.default.removeItem(at: url)
    guard let request = try? startupChoiceDecoder().decode(CodexHandoffRequest.self, from: data) else { return nil }
    func answer(_ result: String) { writeCodexHandoffReceipt(.init(nonce: request.nonce, result: result), pid: pid, dir: dir) }
    guard now.timeIntervalSince(request.at) <= codexHandoffLife else {
        answer("the request expired before the supervisor read it"); return nil
    }
    if let busy { answer(busy); return nil }
    guard let home = targetHome(request.accountID) else {
        answer("the target account is no longer in the fleet snapshot"); return nil
    }
    switch codexHandoffSource(pid: pid, targetHome: home, fallbackDirectory: fallbackDirectory(), dir: dir) {
    case .refused(let why):
        answer(why)
    case .ready(let thread, let directory):
        guard thread == request.threadID else { answer("the conversation changed since you asked"); return nil }
        if let other = codexHandoffOtherWriter(thread: thread, pid: pid, dir: dir) { answer(other); return nil }
        answer(codexHandoffQueued)
        return CodexHandoffPlan(threadID: thread, directory: directory, targetHome: home,
                                spendReserve: request.spendReserve)
    }
    return nil
}
