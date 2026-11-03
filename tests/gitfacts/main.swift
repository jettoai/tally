import Foundation

// Assertion harness for the one-answer-per-directory git gate (`gitDirectoryFacts`,
// TallyCLI/GitRepoRoot.swift): how many git subprocesses a roster of sessions costs, that the
// answers equal the ones the old per-call code gave, and that the short-lived cache neither
// outlives its answer nor hides a directory that is gone.
//
// The fixture is real git in a temp directory, because the answer is git's.

var passed = 0, failed = 0
func check(_ name: String, _ cond: Bool) {
    if cond { passed += 1; print("PASS \(name)") } else { failed += 1; print("FAIL \(name)") }
}

/// `warn` lives in Snapshot.swift, which this suite does not compile; the messages are kept so the
/// "records no main working tree" notice can be compared old against new.
private let warnLock = NSLock()
private var warnings: [String] = []
func warn(_ message: String) { warnLock.lock(); warnings.append(message); warnLock.unlock() }
private func takeWarnings() -> [String] {
    warnLock.lock(); defer { warnLock.unlock() }
    let taken = warnings; warnings = []; return taken
}

/// Counts the git calls the cache makes. `rev-parse` only: that is what the brief measured.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var delay: TimeInterval = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    func hit() { lock.lock(); n += 1; lock.unlock() }
    func reset() { lock.lock(); n = 0; lock.unlock() }
}

let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("tally-gitfacts-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

func git(_ args: [String], in dir: URL) {
    let result = runGit(["-c", "user.email=t@t", "-c", "user.name=T",
                         "-c", "commit.gpgsign=false"] + args, cwd: dir.path)
    if result.code != 0 { print("FAIL setup: git \(args.joined(separator: " ")): \(result.err)") }
}
func mkdir(_ url: URL) { try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }

/// Counting runner: real `runGit` underneath, one tick per `rev-parse`.
func countingRunner(_ counter: Counter) -> GitFactsCache.Runner {
    { args, cwd in
        if args.contains("rev-parse") { counter.hit() }
        if counter.delay > 0 { Thread.sleep(forTimeInterval: counter.delay) }
        return runGit(args, cwd: cwd)
    }
}

// MARK: - Fixture: 12 distinct directories

let repoA = tmp.appendingPathComponent("A")
mkdir(repoA.appendingPathComponent("sub/deep"))
git(["init", "-q", "-b", "main", repoA.path], in: tmp)
git(["commit", "-q", "--allow-empty", "-m", "root"], in: repoA)
let lineL1 = tmp.appendingPathComponent("A-l1")
let lineL2 = tmp.appendingPathComponent("A-l2")
git(["worktree", "add", "-q", "-b", "l1", lineL1.path], in: repoA)
git(["worktree", "add", "-q", "-b", "l2", lineL2.path], in: repoA)
mkdir(lineL1.appendingPathComponent("sub"))

let repoB = tmp.appendingPathComponent("B")
mkdir(repoB.appendingPathComponent("sub"))
git(["init", "-q", "-b", "main", repoB.path], in: tmp)
git(["commit", "-q", "--allow-empty", "-m", "root"], in: repoB)

// A repo whose git dir lives elsewhere: the layout that reaches `resolveMainRepo` case 4.
let repoS = tmp.appendingPathComponent("S")
let gitDirS = tmp.appendingPathComponent("S-gitdir")
mkdir(repoS.appendingPathComponent("sub"))
git(["init", "-q", "-b", "main", "--separate-git-dir", gitDirS.path, repoS.path], in: tmp)
git(["commit", "-q", "--allow-empty", "-m", "root"], in: repoS)
let lineSL = tmp.appendingPathComponent("S-l1")
git(["worktree", "add", "-q", "-b", "sl", lineSL.path], in: repoS)

let plain1 = tmp.appendingPathComponent("n1")
let plain2 = tmp.appendingPathComponent("n2")
mkdir(plain1); mkdir(plain2)

let bare = tmp.appendingPathComponent("bare.git")
git(["init", "-q", "--bare", bare.path], in: tmp)

let twelve: [URL] = [repoA, repoA.appendingPathComponent("sub"), repoA.appendingPathComponent("sub/deep"),
                     lineL1, lineL2, lineL1.appendingPathComponent("sub"),
                     repoB, repoB.appendingPathComponent("sub"),
                     repoS, repoS.appendingPathComponent("sub"), plain1, plain2]

// MARK: - The old algorithm, kept verbatim as the oracle (direct runGit, no cache)

var legacyRevParse = 0
func lg(_ args: [String], cwd: String? = nil) -> (out: String, err: String, code: Int32) {
    if args.contains("rev-parse") { legacyRevParse += 1 }
    return runGit(args, cwd: cwd)
}
func legacyIsWorkingTree(_ candidate: String, ofCommonDir commonDir: String) -> Bool {
    guard !candidate.isEmpty else { return false }
    let probe = lg(["-C", candidate, "rev-parse", "--path-format=absolute", "--git-common-dir"])
    return probe.code == 0 && realpathString(probe.out) == realpathString(commonDir)
}
func legacyResolveMainRepo(cwd: String?) -> String? {
    let common = lg(["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd: cwd)
    guard common.code == 0, !common.out.isEmpty else { return nil }
    if lg(["rev-parse", "--path-format=absolute", "--absolute-git-dir"], cwd: cwd).out == common.out {
        let top = lg(["rev-parse", "--path-format=absolute", "--show-toplevel"], cwd: cwd).out
        if !top.isEmpty { return realpathString(top) }
    }
    if let colocated = colocatedMainRepoPath(gitCommonDir: common.out),
       legacyIsWorkingTree(colocated, ofCommonDir: common.out) {
        return realpathString(colocated)
    }
    let recorded = lg(["config", "--get", "core.worktree"], cwd: cwd).out
    let absolute = recorded.hasPrefix("/") ? recorded : "\(common.out)/\(recorded)"
    if !recorded.isEmpty, legacyIsWorkingTree(absolute, ofCommonDir: common.out) {
        return realpathString(absolute)
    }
    warn("this repository records no main working tree; using its git dir \(common.out)")
    return realpathString(common.out)
}
func legacyCheckout(cwd: String) -> String? {
    let top = lg(["rev-parse", "--path-format=absolute", "--show-toplevel"], cwd: cwd)
    return top.code == 0 && !top.out.isEmpty ? realpathString(top.out) : nil
}

// MARK: - G1: 130 sessions over 12 directories cost 12 rev-parse calls

// The spellings one directory goes by: as made, realpath'd (/private prefix), trailing slash, dot.
func spellings(_ url: URL) -> [String] {
    [url.path, realpathString(url.path), url.path + "/", url.deletingLastPathComponent().path + "/./" + url.lastPathComponent]
}
var roster: [String] = []
var round = 0
while roster.count < 130 {
    for dir in twelve where roster.count < 130 {
        let forms = spellings(dir)
        roster.append(forms[round % forms.count])
    }
    round += 1
}
check("G1 the roster is 130 sessions", roster.count == 130)
check("G1 over 12 distinct directories", Set(roster.map(realpathString)).count == 12)

let g1 = Counter()
gitFactsCache.reset()
gitFactsCache.run = countingRunner(g1)
final class Slots: @unchecked Sendable {
    let lock = NSLock()
    var main = [String?](repeating: nil, count: 130)
    var checkout = [String?](repeating: nil, count: 130)
}
let slots = Slots()
let rosterCopy = roster
DispatchQueue.concurrentPerform(iterations: rosterCopy.count) { i in
    let main = resolveMainRepo(cwd: rosterCopy[i])
    let checkout = gitCheckout(cwd: rosterCopy[i])
    slots.lock.lock(); slots.main[i] = main; slots.checkout[i] = checkout; slots.lock.unlock()
}
print("G1 new: \(g1.count) rev-parse calls for \(roster.count) sessions")
check("G1 rev-parse calls == distinct directories (12)", g1.count == 12)

legacyRevParse = 0
var legacyAnswersEqual = true
for dir in twelve {
    let key = realpathString(dir.path)
    let old = (legacyResolveMainRepo(cwd: key), legacyCheckout(cwd: key))
    for i in roster.indices where realpathString(roster[i]) == key {
        if old.0 != slots.main[i] || old.1 != slots.checkout[i] { legacyAnswersEqual = false }
    }
}
_ = takeWarnings()
print("G1 old: \(legacyRevParse) rev-parse calls for the same 12 directories (one pass each, already deduped by directory)")
check("G1 the old code needed at least 40 for them", legacyRevParse >= 40)
check("G1 every session got the answer the old code gives", legacyAnswersEqual)

// MARK: - G2: answers equal old, shape by shape

let extra: [String] = [lineSL.path, bare.path, repoA.appendingPathComponent(".git").path,
                       tmp.appendingPathComponent("never-existed").path, "",
                       repoA.appendingPathComponent(".git/HEAD").path]
var g2Equal = true
for path in twelve.map(\.path) + extra {
    gitFactsCache.reset()
    gitFactsCache.run = { args, cwd in runGit(args, cwd: cwd) }
    _ = takeWarnings()
    let oldMain = legacyResolveMainRepo(cwd: path), oldTop = legacyCheckout(cwd: path)
    let oldWarn = takeWarnings()
    let newMain = resolveMainRepo(cwd: path), newTop = gitCheckout(cwd: path)
    let newWarn = takeWarnings()
    let same = oldMain == newMain && oldTop == newTop && oldWarn == newWarn
    if !same { g2Equal = false; print("  differs at \(path): old=\(String(describing: oldMain)),\(String(describing: oldTop)) new=\(String(describing: newMain)),\(String(describing: newTop)) warn old=\(oldWarn) new=\(newWarn)") }
}
check("G2 resolveMainRepo and checkout equal the old answers for every shape (plain, nested, linked, separate-git-dir, linked-of-separate with its warning, bare, inside .git, missing, empty, file)", g2Equal)
gitFactsCache.reset()
gitFactsCache.run = { args, cwd in runGit(args, cwd: cwd) }
_ = takeWarnings()
_ = resolveMainRepo(cwd: lineSL.path)
check("G2 the case-4 warning still reaches the user", takeWarnings().count == 1)
check("G2 nil cwd asks from this process's own directory like before",
      resolveMainRepo() == legacyResolveMainRepo(cwd: nil))

// MARK: - G3: concurrent askers of one directory share one git call

let g3 = Counter()
g3.delay = 0.05
gitFactsCache.reset()
gitFactsCache.run = countingRunner(g3)
DispatchQueue.concurrentPerform(iterations: 32) { _ in _ = gitDirectoryFacts(cwd: repoB.path) }
check("G3 32 simultaneous askers of one directory cost 1 rev-parse", g3.count == 1)

// MARK: - G4: an answer lives 5 seconds

let g4 = Counter()
var fake: TimeInterval = 1000
gitFactsCache.reset()
gitFactsCache.run = countingRunner(g4)
gitFactsCache.clock = { fake }
_ = gitDirectoryFacts(cwd: repoB.path)
fake += 4.9; _ = gitDirectoryFacts(cwd: repoB.path)
check("G4 asked again 4.9 s later: reused", g4.count == 1)
fake += 0.2; _ = gitDirectoryFacts(cwd: repoB.path)
check("G4 asked again 5.1 s after the answer: asked git again", g4.count == 2)
fake -= 60; _ = gitDirectoryFacts(cwd: repoB.path)
check("G4 a clock that went backwards is a stale answer", g4.count == 3)

// MARK: - G5: a directory that is gone is not answered from memory

let doomed = repoA.appendingPathComponent("sub/doomed")
mkdir(doomed)
gitFactsCache.reset()
gitFactsCache.run = { args, cwd in runGit(args, cwd: cwd) }
// Asked by its realpath on both sides: a deleted path cannot be resolved, so only the spelling that
// was cached is a spelling that could be answered from memory.
let doomedReal = realpathString(doomed.path)
check("G5 the directory is a checkout while it is there", gitCheckout(cwd: doomedReal) == realpathString(repoA.path))
try? FileManager.default.removeItem(at: doomed)
check("G5 once deleted, resolveMainRepo is nil rather than the remembered repo", resolveMainRepo(cwd: doomedReal) == nil)
check("G5 and so is the checkout", gitCheckout(cwd: doomedReal) == nil)

// MARK: - G6: nobody goes round the gate

func source(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
let inventory = source("TallyCLI/SessionInventory.swift"), pick = source("TallyCLI/NativePick.swift")
let root = source("TallyCLI/GitRepoRoot.swift")
check("G6 the sources are readable", !inventory.isEmpty && !pick.isEmpty && !root.isEmpty)
check("G6 SessionInventory asks the gate, not git", !inventory.contains("runGit([\"rev-parse\"") && inventory.contains("gitCheckout(cwd:"))
check("G6 NativePick asks the gate, not git", !pick.contains("runGit([\"rev-parse\"") && pick.contains("gitCheckout(cwd:"))
check("G6 GitRepoRoot spells rev-parse once, in the gate's own argument builder",
      root.components(separatedBy: "\"rev-parse\"").count - 1 == 1)

// MARK: - G7: a second process reuses the first one's answers (disk layer)

let diskFile = tmp.appendingPathComponent("facts.json")
let g7 = Counter()
func newProcess() {
    gitFactsCache.reset()
    gitFactsCache.run = countingRunner(g7)
    gitFactsCache.diskFile = diskFile
    gitFactsCache.environment = { [:] }   // G7 is about the disk layer, not about the shell it runs in
}
g7.reset(); newProcess()
_ = gitDirectoryFacts(cwd: repoB.path)          // positive
_ = gitDirectoryFacts(cwd: plain1.path)         // negative
check("G7 the first process asks git for both", g7.count == 2)
gitFactsCache.flush()
check("G7 flush writes the file", FileManager.default.fileExists(atPath: diskFile.path))
let writtenKeys = Set(((try? JSONSerialization.jsonObject(with: Data(contentsOf: diskFile)))
    .flatMap { ($0 as? [String: Any])?["entries"] as? [String: Any] } ?? [:]).keys)
check("G7 only the positive answer is on disk", writtenKeys == [realpathString(repoB.path)])

g7.reset(); newProcess()
let again = gitDirectoryFacts(cwd: repoB.path)
check("G7 a new process within 5 s asks git 0 times for a repository",
      g7.count == 0 && again?.toplevel == realpathString(repoB.path))
_ = gitDirectoryFacts(cwd: plain1.path)
check("G7 and 1 time for the directory that was not a repository", g7.count == 1)

// Age the file past the lifetime.
var json = try! JSONSerialization.jsonObject(with: Data(contentsOf: diskFile)) as! [String: Any]
var diskEntries = json["entries"] as! [String: [String: Any]]
for key in diskEntries.keys { diskEntries[key]!["at"] = Date().timeIntervalSince1970 - 6 }
json["entries"] = diskEntries
try! JSONSerialization.data(withJSONObject: json).write(to: diskFile)
g7.reset(); newProcess()
_ = gitDirectoryFacts(cwd: repoB.path)
check("G7 an answer 6 s old on disk is asked again", g7.count == 1)

// A git dir that has moved away is not trusted.
let moving = tmp.appendingPathComponent("moving")
mkdir(moving)
git(["init", "-q", "-b", "main", moving.path], in: tmp)
g7.reset(); newProcess()
_ = gitDirectoryFacts(cwd: moving.path)
gitFactsCache.flush()
let parked = tmp.appendingPathComponent("moving-parked")
try! FileManager.default.moveItem(at: moving.appendingPathComponent(".git"), to: parked)
g7.reset(); newProcess()
_ = gitDirectoryFacts(cwd: moving.path)
check("G7 an answer whose git dir has moved away is asked again", g7.count == 1)
try! FileManager.default.moveItem(at: parked, to: moving.appendingPathComponent(".git"))

// Off unless asked for: with no diskFile the real ~/.tally file is neither read nor written.
gitFactsCache.reset(); gitFactsCache.diskFile = nil
let realFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/git-facts.json").path
func mtime(_ path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
}
let realBefore = mtime(realFile)
_ = gitDirectoryFacts(cwd: repoA.path)
gitFactsCache.flush()
check("G7 with no diskFile nothing is written to ~/.tally/git-facts.json", mtime(realFile) == realBefore)

// MARK: - G8: a process with a git identity override keeps its answers to itself

// What a linked worktree's commit hooks export (git 2.54, measured 2026-11-03): an absolute GIT_DIR
// naming the line's admin dir. Under it git answers for repo A from ANY directory.
let hookEnv = ["GIT_DIR": repoA.appendingPathComponent(".git/worktrees/A-l1").path]
let bSub = repoB.appendingPathComponent("sub").path
let aCommon = realpathString(repoA.appendingPathComponent(".git").path)
check("G8 fixture: the linked line's admin dir exists",
      FileManager.default.fileExists(atPath: hookEnv["GIT_DIR"]!))

/// Real /usr/bin/git with `extra` on top of this process's environment, counting like countingRunner.
func overrideRunner(_ counter: Counter, _ extra: [String: String]) -> GitFactsCache.Runner {
    { args, cwd in
        if args.contains("rev-parse") { counter.hit() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging(extra) { _, new in new }
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true) }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out; process.standardError = err
        guard (try? process.run()) != nil else { return ("", "cannot run git", 127) }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let trim = { (d: Data) in String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        return (trim(o), trim(e), process.terminationStatus)
    }
}
func diskKeys(_ file: URL) -> Set<String> {
    Set(((try? JSONSerialization.jsonObject(with: Data(contentsOf: file)))
        .flatMap { ($0 as? [String: Any])?["entries"] as? [String: Any] } ?? [:]).keys)
}
/// A new process: its git sees `runner`'s environment, the guard sees `env`.
func g8Process(_ runner: @escaping GitFactsCache.Runner, env: [String: String], file: URL) {
    gitFactsCache.reset()
    gitFactsCache.run = runner
    gitFactsCache.environment = { env }
    gitFactsCache.diskFile = file
}
let g8 = Counter()

// Control: with the guard looking at a clean environment, the polluted answers do travel through the
// file, so the other checks measure something.
let g8Control = tmp.appendingPathComponent("g8-control.json")
g8.reset(); g8Process(overrideRunner(g8, hookEnv), env: [:], file: g8Control)
_ = gitDirectoryFacts(cwd: bSub); _ = gitDirectoryFacts(cwd: plain1.path)
gitFactsCache.flush()
g8.reset(); g8Process(countingRunner(g8), env: [:], file: g8Control)
let controlB = gitDirectoryFacts(cwd: bSub), controlPlain = gitDirectoryFacts(cwd: plain1.path)
check("G8 control: with the guard bypassed, a clean process reads repo A's answer for B/sub and an answer for a non-repository from disk (0 rev-parse)",
      g8.count == 0 && controlB.map { realpathString($0.commonDir) } == aCommon && controlPlain != nil)

// a: the writer carries GIT_DIR.
let g8A = tmp.appendingPathComponent("g8-a.json")
g8.reset(); g8Process(overrideRunner(g8, hookEnv), env: hookEnv, file: g8A)
let polluted = gitDirectoryFacts(cwd: bSub); _ = gitDirectoryFacts(cwd: plain1.path)
gitFactsCache.flush()
check("G8 a: the override reaches git (this process's own answer is repo A's, as before c889d0a)",
      polluted.map { realpathString($0.commonDir) } == aCommon)
check("G8 a: a process with GIT_DIR writes nothing to the shared file",
      !FileManager.default.fileExists(atPath: g8A.path)
      && diskKeys(g8A).isDisjoint(with: [realpathString(bSub), realpathString(plain1.path)]))

// b: a clean process afterwards gets git's real answers.
g8.reset(); g8Process(countingRunner(g8), env: [:], file: g8A)
let bCheckout = gitCheckout(cwd: bSub), bMain = resolveMainRepo(cwd: bSub), bPlain = gitCheckout(cwd: plain1.path)
check("G8 b: a clean process after it gets B and \"not a repository\", asking git (2 rev-parse)",
      bCheckout == realpathString(repoB.path) && bMain == realpathString(repoB.path)
      && bPlain == nil && g8.count == 2)

// c: a clean writer, then a reader that carries GIT_DIR.
let g8C = tmp.appendingPathComponent("g8-c.json")
g8.reset(); g8Process(countingRunner(g8), env: [:], file: g8C)
_ = gitDirectoryFacts(cwd: repoB.path)
gitFactsCache.flush()
check("G8 c: the clean writer's answer is on disk", diskKeys(g8C) == [realpathString(repoB.path)])
g8.reset(); g8Process(overrideRunner(g8, hookEnv), env: hookEnv, file: g8C)
_ = gitDirectoryFacts(cwd: repoB.path)
check("G8 c: a process with GIT_DIR does not read the shared file (1 rev-parse)", g8.count == 1)

// d: variables that do not change the answer leave the disk layer on.
let g8D = tmp.appendingPathComponent("g8-d.json")
let quiet = ["GIT_EDITOR": "vi", "GIT_EXEC_PATH": "/Library/Developer/CommandLineTools/usr/libexec/git-core"]
g8.reset(); g8Process(countingRunner(g8), env: quiet, file: g8D)
_ = gitDirectoryFacts(cwd: repoB.path)
gitFactsCache.flush()
g8.reset(); g8Process(countingRunner(g8), env: quiet, file: g8D)
let quietTop = gitDirectoryFacts(cwd: repoB.path)?.toplevel
check("G8 d: GIT_EDITOR and GIT_EXEC_PATH alone keep the disk layer (0 rev-parse)",
      g8.count == 0 && quietTop == realpathString(repoB.path))

// e: the guard's list against the git on this machine.
let engine = runGit(["rev-parse", "--local-env-vars"])
let local = Set(engine.out.split(separator: "\n").map(String.init))
check("G8 e: git answers --local-env-vars", engine.code == 0 && !local.isEmpty)
check("G8 e: every repo-local variable git names is in the guard's list",
      local.isSubset(of: gitIdentityEnvironmentKeys))
check("G8 e: the guard's list is git's plus exactly the two discovery variables",
      gitIdentityEnvironmentKeys.subtracting(local) == ["GIT_CEILING_DIRECTORIES", "GIT_DISCOVERY_ACROSS_FILESYSTEM"])
gitFactsCache.reset(); gitFactsCache.diskFile = nil

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
