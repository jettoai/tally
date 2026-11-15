import Foundation

// The root evidence helper (B-4616, second half): the sudoers rule, the helper script, the install
// script, the setup outcomes and the `tally forensics` request channel. Nothing here is privileged:
// scripts are run by /bin/sh against fake tools and temp paths.

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

typealias P = ProcessForensicsPrivilege
let fm = FileManager.default
let scratch = fm.temporaryDirectory.appendingPathComponent("forensicspriv-\(getpid())")
try? fm.removeItem(at: scratch)
try! fm.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: scratch) }

/// Runs /bin/sh with the given arguments; returns the exit code and stdout.
func sh(_ arguments: [String], env: [String: String] = [:]) -> (code: Int32, out: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = arguments
    task.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    task.standardInput = FileHandle.nullDevice
    try! task.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return (task.terminationStatus, String(decoding: data, as: UTF8.self))
}
func write(_ text: String, to url: URL, mode: Int = 0o644) {
    fm.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: mode])
}

// MARK: - T1 the sudoers rule

let expectedRule = """
    # Installed by Tally (B-4616): lets this account run one read-only evidence helper as root, and remove it.
    # Remove with: tally forensics remove
    albertliu ALL=(root) NOPASSWD: /Library/PrivilegedHelperTools/ai.jetto.tally.forensics, /bin/rm -f /etc/sudoers.d/tally-forensics /Library/PrivilegedHelperTools/ai.jetto.tally.forensics

    """
let rule = P.sudoersRule(user: "albertliu")
expect(rule == expectedRule, "T1 the rule is exactly the approved text")
let ruleLines = (rule ?? "").split(separator: "\n").filter { !$0.hasPrefix("#") }
expect(ruleLines.count == 1 && !(rule ?? "").contains("*") && !(rule ?? "").contains("/usr/bin/sample")
       && !(rule ?? "").contains("fs_usage") && !(rule ?? "").contains("ALL=(ALL"),
       "T1 one rule line, no wildcard, no sample or fs_usage named, root only")
for bad in ["ALL", "root,x", "a\nb", "Albert", "", "-x", "1abc", "a b", "a\n", "%admin", "a;b", "a#b", "a/b", "é", "a,b", "a\u{0}"] {
    expect(P.sudoersRule(user: bad) == nil, "T1 refuses the user name \(bad.debugDescription)")
}
for good in ["albertliu", "_svc", "a.b-c_1", "a"] {
    expect(P.sudoersRule(user: good) != nil, "T1 accepts the user name \(good)")
}
do {  // the real parser, not a regex of ours
    let file = scratch.appendingPathComponent("rule.sudoers")
    write(rule ?? "", to: file)
    expect(sh(["-c", "/usr/sbin/visudo -cf '\(file.path)' > /dev/null 2>&1"]).code == 0, "T1 the real visudo parses the rule")
    write((rule ?? "") + "bad line here (\n", to: file)
    expect(sh(["-c", "/usr/sbin/visudo -cf '\(file.path)' > /dev/null 2>&1"]).code != 0, "T1 the real visudo refuses a broken file (the check can fail)")
}
expect(P.removeArguments == ["/bin/rm", "-f", P.sudoersPath, P.wrapperPath]
       && (rule ?? "").contains(P.removeArguments.joined(separator: " "))
       && P.removeScript == "'/bin/rm' '-f' '\(P.sudoersPath)' '\(P.wrapperPath)'",
       "T1 the removal the rule allows, the one sudo -n runs and the one the window runs are one list")

// MARK: - T2 the helper script, run with fake tools

let log = scratch.appendingPathComponent("calls.log")
let fakeSample = scratch.appendingPathComponent("fake-sample")
let fakeFsUsage = scratch.appendingPathComponent("fake-fs_usage")
write("""
    #!/bin/sh
    echo "sample $*" >> '\(log.path)'
    while [ $# -gt 0 ]; do if [ "$1" = "-file" ]; then shift; echo FAKE-SAMPLE-BODY > "$1"; fi; shift; done
    """, to: fakeSample, mode: 0o755)
write("""
    #!/bin/sh
    echo "fs_usage $*" >> '\(log.path)'
    echo FAKE-FSUSAGE-BODY
    """, to: fakeFsUsage, mode: 0o755)
let helper = scratch.appendingPathComponent("helper.sh")
write(P.wrapperScript(sample: fakeSample.path, fsUsage: fakeFsUsage.path), to: helper)

let badArguments: [[String]] = [[], ["0"], ["01"], ["1 2"], ["1", "2"], ["-file"], ["$(id)"], ["12345678"], [""],
                                ["1;ls"], ["1\n2"], ["١٢٣"], ["-1"], ["1e3"], ["/etc/passwd"], ["../1"], ["`id`"], ["1 -file /tmp/x"]]
for arguments in badArguments {
    try? fm.removeItem(at: log)
    let result = sh([helper.path] + arguments)
    expect(result.code == 64 && !fm.fileExists(atPath: log.path) && result.out.isEmpty,
           "T2 the helper refuses \(arguments.debugDescription) with 64 and runs nothing")
}
for pid in ["1", "12345", "9999999"] {
    try? fm.removeItem(at: log)
    let result = sh([helper.path, pid])
    let calls = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    expect(result.code == 0 && calls.contains("sample \(pid) 10 -mayDie -file ") && calls.contains("fs_usage -w -t 10 -f filesys")
           && result.out.contains("=== sample \(pid) ===") && result.out.contains("FAKE-SAMPLE-BODY")
           && result.out.contains("FAKE-FSUSAGE-BODY"),
           "T2 pid \(pid) runs both tools and prints both answers")
}

// MARK: - T3 the helper's text

let text = P.wrapperScript()
expect(!text.contains("/usr/local"), "T3 never names a folder this user owns")
let tokens = Set(text.split(whereSeparator: { " \n\t\"'=;()".contains($0) }).map(String.init).filter { $0.hasPrefix("/") }
    .flatMap { $0.split(separator: ":").map(String.init) })
let allowed: Set<String> = ["/bin/sh", "/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/bin/mktemp", "/bin/rm",
                            "/usr/bin/head", "/usr/bin/sample", "/usr/bin/fs_usage", "/dev/null",
                            "/private/tmp/tally-forensics.XXXXXX"]
expect(tokens.isSubset(of: allowed), "T3 the only absolute paths are system tools: \(tokens.subtracting(allowed).sorted())")
expect(text.components(separatedBy: "-file").count == 2 && text.contains("-file \"$d/sample.txt\""),
       "T3 the one -file names a file in the helper's own root-only folder")
let argumentUses = text.replacingOccurrences(of: "case \"$1\" in", with: "")
    .replacingOccurrences(of: "pid=$1", with: "").replacingOccurrences(of: "${#1}", with: "")
expect(!argumentUses.contains("$1") && !argumentUses.contains("$@") && !argumentUses.contains("$*") && !text.contains("eval"),
       "T3 the argument is read three times, only as a number")
expect(text.hasPrefix("#!/bin/sh\n") && text.contains("LC_ALL=C"), "T3 plain sh in the C locale")

// MARK: - T4 the install script

let wrapperDest = scratch.appendingPathComponent("installed-wrapper")
let sudoersDest = scratch.appendingPathComponent("installed-sudoers")
let failingVisudo = scratch.appendingPathComponent("visudo-fails")
write("#!/bin/sh\nexit 1\n", to: failingVisudo, mode: 0o755)
func install(visudo: String, sudoers: URL = sudoersDest, env: [String: String] = [:]) -> Int32 {
    let script = P.installScript(visudo: visudo, owner: "", wrapper: wrapperDest.path, sudoers: sudoers.path)
    return sh(["-c", script, "sh", P.wrapperScript(), rule ?? ""], env: env).code
}
let failed = install(visudo: failingVisudo.path)
expect(failed == 65 && !fm.fileExists(atPath: sudoersDest.path) && !fm.fileExists(atPath: wrapperDest.path),
       "T4 a visudo that refuses the file leaves nothing behind (exit \(failed))")
let succeeded = install(visudo: "/usr/sbin/visudo")
let modes = [wrapperDest, sudoersDest].map { ((try? fm.attributesOfItem(atPath: $0.path)[.posixPermissions]) as? Int) ?? -1 }
expect(succeeded == 0 && modes == [0o755, 0o440]
       && (try? String(contentsOf: wrapperDest, encoding: .utf8)) == P.wrapperScript() + "\n"
       && (try? String(contentsOf: sudoersDest, encoding: .utf8)) == (rule ?? "") + "\n",
       "T4 with a visudo that agrees both files land, 0755 and 0440 (exit \(succeeded), modes \(modes.map { String($0, radix: 8) }))")
try? fm.removeItem(at: wrapperDest); try? fm.removeItem(at: sudoersDest)
let brokenRule = sh(["-c", P.installScript(owner: "", wrapper: wrapperDest.path, sudoers: sudoersDest.path), "sh",
                      P.wrapperScript(), "x ALL=(root) NOPASSWD: (\n"])
expect(brokenRule.code == 65 && !fm.fileExists(atPath: sudoersDest.path), "T4 the real visudo stops a broken rule before any write")
let rolledBack = install(visudo: "/usr/sbin/visudo", sudoers: scratch.appendingPathComponent("no-such-folder/sudoers"))
expect(rolledBack == 66 && !fm.fileExists(atPath: wrapperDest.path), "T4 a failed second install takes the first back (exit \(rolledBack))")
do {  // C-1: a bare `mktemp -d` lands in a per-user temp folder (or TMPDIR), where a same-account program can
      // rename root's temp folder away between visudo and install; the parent must be sticky and root-owned
    let userTmp = scratch.appendingPathComponent("user-tmpdir")
    try? fm.createDirectory(at: userTmp, withIntermediateDirectories: true)
    let seen = scratch.appendingPathComponent("visudo-saw")
    let spyVisudo = scratch.appendingPathComponent("visudo-spy")
    write("#!/bin/sh\np=$(/usr/bin/dirname \"$(/usr/bin/dirname \"$2\")\")\n[ -k \"$p\" ] && s=sticky || s=plain\n"
          + "echo \"$p $s $(/usr/bin/stat -f %Su \"$p\")\" > '\(seen.path)'\n", to: spyVisudo, mode: 0o755)
    let code = install(visudo: spyVisudo.path, env: ["TMPDIR": userTmp.path + "/"])
    let saw = (try? String(contentsOf: seen, encoding: .utf8)) ?? ""
    expect(code == 0 && saw == "/private/tmp sticky root\n",
           "T4 with TMPDIR in the user's folder, the install's temp folder sits in sticky root-owned /private/tmp (saw \(saw.debugDescription))")
    try? fm.removeItem(at: wrapperDest); try? fm.removeItem(at: sudoersDest)
}
expect(P.installScript().contains("-o root -g wheel") && P.installScript().contains("'/etc/sudoers.d/tally-forensics'")
       && P.installScript().contains("'/Library/PrivilegedHelperTools/ai.jetto.tally.forensics'"),
       "T4 the installed script writes root-owned files at the two approved paths")

// MARK: - T5 the password window's answers and the setup outcomes

expect(AdminShell.result(exitCode: 0, stderr: "") == .done, "T5 exit 0 is done")
expect(AdminShell.result(exitCode: 1, stderr: "0:17: execution error: 使用者取消操作。 (-128)") == .cancelled
       && AdminShell.result(exitCode: 1, stderr: "execution error: User canceled. (-128)") == .cancelled, "T5 -128 is cancelled in any language")
expect(AdminShell.result(exitCode: 1, stderr: "boom (3)\n") == .failed("boom (3)"), "T5 anything else is failed")
expect(AdminShell.result(exitCode: 3, stderr: "x marker x", foreignMarker: "marker") == .foreignFile
       && AdminShell.result(exitCode: 3, stderr: "x marker x") == .failed("x marker x"), "T5 the foreign-file marker only counts when asked for")

final class Elevations: @unchecked Sendable {
    var scripts: [String] = []; var arguments: [[String]] = []; var prompts: [String] = []
    func record(_ script: String, _ args: [String], _ prompt: String) { scripts.append(script); arguments.append(args); prompts.append(prompt) }
}
func elevator(_ answer: AdminShell.Result, _ log: Elevations) -> ProcessForensicsSetup.Elevate {
    { script, args, prompt in log.record(script, args, prompt); return answer }
}
do {
    let seen = Elevations()
    let ok = ProcessForensicsSetup.install(user: "albertliu", prompt: "P", elevate: elevator(.done, seen), state: { .installed })
    expect(ok == .succeeded && seen.scripts == [P.installScript()] && seen.arguments == [[P.wrapperScript(), rule ?? ""]] && seen.prompts == ["P"],
           "T5 install hands the window the install script, the helper text and the rule")
    let none = Elevations()
    expect(ProcessForensicsSetup.install(user: "albertliu", prompt: "P", elevate: elevator(.cancelled, none), state: { .notInstalled }) == .cancelled,
           "T5 a cancelled window is cancelled")
    expect(ProcessForensicsSetup.install(user: "albertliu", prompt: "P", elevate: elevator(.done, none), state: { .notInstalled }) == .failed,
           "T5 a window that said done while the disk says otherwise is failed")
    expect(ProcessForensicsSetup.install(user: "albertliu", prompt: "P", elevate: elevator(.failed("x"), none), state: { .installed }) == .failed,
           "T5 a failed window is failed")
    let refused = Elevations()
    expect(ProcessForensicsSetup.install(user: "Al Bert", prompt: "P", elevate: elevator(.done, refused), state: { .installed }) == .failed
           && refused.scripts.isEmpty, "T5 a user name that is not plain never reaches the window")

    let quiet = Elevations()
    expect(ProcessForensicsSetup.remove(prompt: "P", elevate: elevator(.done, quiet), sudoRemove: { true }, state: { .notInstalled }) == .succeeded
           && quiet.scripts.isEmpty, "T5 nothing installed is removed without a window")
    var removed = false
    expect(ProcessForensicsSetup.remove(prompt: "P", elevate: elevator(.done, quiet), sudoRemove: { removed = true; return true },
                                        state: { removed ? .notInstalled : .installed }) == .succeeded && quiet.scripts.isEmpty,
           "T5 the rule's own removal needs no window")
    let window = Elevations()
    var gone = false
    expect(ProcessForensicsSetup.remove(prompt: "P", elevate: { s, a, p in window.record(s, a, p); gone = true; return .done },
                                        sudoRemove: { false }, state: { gone ? .notInstalled : .incomplete }) == .succeeded
           && window.scripts == [P.removeScript] && window.arguments == [[]], "T5 a refused sudo falls back to the window")
    expect(ProcessForensicsSetup.remove(prompt: "P", elevate: elevator(.cancelled, window), sudoRemove: { false }, state: { .installed }) == .cancelled,
           "T5 a cancelled removal changes nothing")
}

// MARK: - T6 the state

func state(wrapper: Bool, rule: Bool, allowed: Bool) -> P.State {
    P.state(exists: { $0 == P.wrapperPath ? wrapper : rule }, allowed: { allowed })
}
expect(state(wrapper: false, rule: false, allowed: false) == .notInstalled && state(wrapper: true, rule: true, allowed: true) == .installed
       && state(wrapper: true, rule: true, allowed: false) == .incomplete && state(wrapper: true, rule: false, allowed: true) == .incomplete
       && state(wrapper: false, rule: true, allowed: true) == .incomplete, "T6 installed means both files and an effective rule")

// MARK: - T7 the request channel

expect(parseForensicsArgs(["setup"]) == ForensicsArgs(action: .setup, timeout: 180)
       && parseForensicsArgs(["remove", "--timeout", "5"]) == ForensicsArgs(action: .remove, timeout: 5)
       && parseForensicsArgs(["status"])?.action == .status, "T7 setup, remove and status parse; the wait defaults to three minutes")
for bad in [[], ["install"], ["setup", "--timeout"], ["setup", "--timeout", "0"], ["setup", "--timeout", "x"], ["setup", "--now"], ["--timeout", "5"], ["setup", "extra"]] {
    expect(parseForensicsArgs(bad) == nil, "T7 usage error for \(bad)")
}
expect(isValidForensicsRequestID(UUID().uuidString) && !isValidForensicsRequestID("") && !isValidForensicsRequestID("../x")
       && !isValidForensicsRequestID("a/b") && !isValidForensicsRequestID("a b") && !isValidForensicsRequestID(String(repeating: "a", count: 65))
       && isValidForensicsRequestID(String(repeating: "a", count: 64)), "T7 an id is only what a UUID has, at most 64")
let t0 = Date(timeIntervalSince1970: 1_800_000_000)
expect(forensicsPromptAllowed(lastShownAt: nil, now: t0) && !forensicsPromptAllowed(lastShownAt: t0, now: t0.addingTimeInterval(599))
       && forensicsPromptAllowed(lastShownAt: t0, now: t0.addingTimeInterval(600)) && forensicsPromptAllowed(lastShownAt: t0, now: t0.addingTimeInterval(-5)),
       "T7 the window opens at most once in ten minutes (a clock set back does not lock it)")
do {
    let dir = scratch.appendingPathComponent("answers")
    writeForensicsResult("abc", .pending, dir: dir)
    expect(readForensicsResult("abc", dir: dir) == .pending, "T7 an answer round-trips")
    writeForensicsResult("abc", .done, dir: dir)
    expect(readForensicsResult("abc", dir: dir) == .done && readForensicsResult("nope", dir: dir) == nil, "T7 the last answer wins; no answer is nil")
    writeForensicsResult("../escape", .done, dir: dir)
    expect(!fm.fileExists(atPath: scratch.appendingPathComponent("escape.result").path) && readForensicsResult("../escape", dir: dir) == nil,
           "T7 an id with a slash writes nothing")
    let mode = ((try? fm.attributesOfItem(atPath: forensicsResultURL("abc", dir: dir).path)[.posixPermissions]) as? Int) ?? -1
    expect(mode == 0o600, "T7 the answer file is 0600")
    try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86_400)], ofItemAtPath: forensicsResultURL("abc", dir: dir).path)
    writeForensicsResult("fresh", .done, dir: dir)
    sweepForensicsResults(dir: dir, now: Date())
    expect(readForensicsResult("abc", dir: dir) == nil && readForensicsResult("fresh", dir: dir) == .done, "T7 an answer nobody read goes after a day, a fresh one stays")
}

if failures > 0 { print("\(failures) FAILED"); exit(1) }
print("ALL PASSED")
