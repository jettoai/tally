import Foundation

// Issue #8 checks for CLISearchPath. Run through tests/run-clipath-tests.sh, which supplies a scratch
// fixture directory as the first argument and a GUI app's minimal PATH.

var checks = 0
var failures = 0

func expect(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL: \(label)")
    }
}

func readSource(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

func occurrences(_ needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

/// Runs `body` off the main thread and waits for it: top-level code is on the main thread, and the
/// searcher only waits for the login shell when it is not.
final class Box<T>: @unchecked Sendable { var value: T? }

func onBackground<T>(_ body: @escaping @Sendable () -> T) -> T {
    let box = Box<T>()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        box.value = body()
        done.signal()
    }
    done.wait()
    return box.value!
}

let root = CommandLine.arguments[1]
let fm = FileManager.default

func write(_ path: String, _ text: String) {
    try! fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                            withIntermediateDirectories: true)
    try! text.write(toFile: path, atomically: true, encoding: .utf8)
    try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
}

func calls(_ shell: String) -> Int {
    let text = (try? String(contentsOfFile: "\(root)/\(shell).calls", encoding: .utf8)) ?? ""
    return text.split(separator: "\n").count
}

// The npm install form from the issue: a symlink onto a JS entry whose shebang asks env for node,
// with node in the same bin directory.
write("\(root)/prefix/bin/node", "#!/bin/sh\necho \"fake-node:$2\"\n")
write("\(root)/prefix/lib/x/codex.js", "#!/usr/bin/env node\n")
try! fm.createSymbolicLink(atPath: "\(root)/prefix/bin/codex", withDestinationPath: "../lib/x/codex.js")
write("\(root)/shim/codex", "#!/bin/sh\necho shim\n")

let okBody = """
echo "rc noise PATH=/nowhere"
echo __TALLY_LOGIN_PATH_BEGIN__decoy
export PATH="\(root)/shim:\(root)/prefix/bin:/usr/bin:/bin"
for a; do last=$a; done
eval "$last"
echo trailing noise
"""
func shell(_ name: String, _ body: String) -> String {
    let path = "\(root)/\(name)"
    write(path, "#!/bin/sh\necho \"$*\" >> \"$0.calls\"\n\(body)\n")
    return path
}
let okShell = shell("shell-ok", okBody)
let okShell2 = shell("shell-ok2", okBody)
let slowShell = shell("shell-slow", "sleep 2\n\(okBody)")
// A background job left holding stdout: the probe must not wait for end of file.
let hangShell = shell("shell-hang", "sleep 5 & sleep 5")
let failShell = shell("shell-fail", "exit 1")

func searcher(_ shell: String, timeout: TimeInterval = 5) -> CLISearchPath {
    CLISearchPath(home: "\(root)/home", systemDirectories: [], loginShell: shell,
                  shimDirectory: "\(root)/shim", probeTimeout: timeout)
}

let codex = "\(root)/prefix/bin/codex"

// C0: the premise. Without it every check below is vacuous.
do {
    let env = Process()
    env.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    env.arguments = ["node", "--version"]
    env.standardOutput = FileHandle.nullDevice
    env.standardError = FileHandle.nullDevice
    try! env.run()
    env.waitUntilExit()
    expect(env.terminationStatus != 0, "C0 vacuous: node on minimal PATH")
}

// C1: found through the login PATH, unresolved, and never the shim that precedes it.
let ok = searcher(okShell)
let found = onBackground { ok.resolve("codex") }
expect(found == codex, "C1 resolve finds the npm prefix CLI and skips the shim (got \(found ?? "nil"))")

// C2: the child's PATH puts the CLI's own directory first, drops the shim, removes duplicates.
let childPath = onBackground { ok.childPATH(for: codex, inherited: "/usr/bin:/bin") }
expect(childPath == "\(root)/prefix/bin:/usr/bin:/bin", "C2 child PATH shape (got \(childPath))")
// An executable outside the login PATH and an inherited PATH the login PATH lacks: each of the
// three sources has to show up, in order.
let otherPath = onBackground { ok.childPATH(for: "\(root)/other/codex", inherited: "/usr/sbin:/usr/bin") }
expect(otherPath == "\(root)/other:\(root)/prefix/bin:/usr/bin:/bin:/usr/sbin",
       "C2 dirname, then login PATH, then inherited (got \(otherPath))")

// C3: the CLI actually starts with the searcher's environment.
let started = await CLIRunner.run(codex, arguments: ["--version"], searchPath: ok)
expect(started?.exitCode == 0
       && started?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "fake-node:--version",
       "C3 the npm CLI starts (rc \(started?.exitCode ?? -1), stderr \(started?.stderr ?? ""))")

// C4: the call as every existing caller writes it, with the shared searcher.
let legacy = await CLIRunner.run(codex, arguments: ["--version"])
expect(legacy?.exitCode == 0
       && legacy?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "fake-node:--version",
       "C4 the npm CLI starts through the default run (rc \(legacy?.exitCode ?? -1), stderr \(legacy?.stderr ?? ""))")

// C5: only the text between the last begin marker and its end marker counts.
let begin = CLISearchPath.beginMarker, end = CLISearchPath.endMarker
expect(CLISearchPath.parse("a\n\(begin)\n/x:/y\n\(end)\nz") == ["/x", "/y"], "C5 parse between markers")
expect(CLISearchPath.parse("PATH=/x:/y") == nil, "C5 no markers is a failure")
expect(CLISearchPath.parse("\(begin)\n/x:/y\n") == nil, "C5 begin only is a failure")
expect(CLISearchPath.parse("\(begin)\n/a\n\(end)\n\(begin)\n/b\n\(end)\n") == ["/b"], "C5 last pair wins")

// C6: the main thread never waits for the login shell.
let slow = searcher(slowShell)
let mainStart = Date()
let onMain = slow.resolve("codex")
let mainElapsed = Date().timeIntervalSince(mainStart)
expect(onMain == nil && mainElapsed < 0.5,
       "C6 main thread answers at once (got \(onMain ?? "nil") after \(mainElapsed)s)")
let afterWarm = onBackground { slow.resolve("codex") }
expect(afterWarm == codex, "C6 a background caller then gets the login PATH answer")

// C7: a shell whose background job holds stdout is bounded by the timeout, both for the caller and
// for the probe itself.
let hang = searcher(hangShell, timeout: 1)
let hangStart = Date()
let hung = onBackground { hang.resolve("codex") }
expect(hung == nil && Date().timeIntervalSince(hangStart) < 3, "C7 resolve returns within the timeout")
let probeStart = Date()
let probed = onBackground { CLISearchPath.probe(shell: hangShell, timeout: 1) }
let probeElapsed = Date().timeIntervalSince(probeStart)
expect(probed == nil && probeElapsed < 3, "C7 probe does not wait for end of file (\(probeElapsed)s)")

// C8: a failed read is not retried within the pause.
let fail = searcher(failShell)
_ = onBackground { fail.resolve("codex") }
_ = onBackground { fail.resolve("codex") }
expect(calls("shell-fail") == 1, "C8 failed read retried too soon (\(calls("shell-fail")) calls)")

// C9: a successful read is kept; a miss does not run the rc files again.
let ok2 = searcher(okShell2)
_ = onBackground { ok2.resolve("nope") }
_ = onBackground { ok2.resolve("nope") }
expect(calls("shell-ok2") == 1, "C9 login PATH read again after a miss (\(calls("shell-ok2")) calls)")

// C10: every spawn of a resolved provider CLI builds its environment through the searcher. The
// spawning types cannot be compiled in this suite, so this is a source-text lock.
for path in ["Tally/Providers/Codex/CodexAppServerClient.swift", "Tally/Core/RenewLoginRunner.swift",
             "Tally/Core/EffortLevels.swift"] {
    let count = occurrences("CLISearchPath.shared.environment(for:", in: readSource(path))
    expect(count == 1, "C10 \(path) spawns through CLISearchPath (\(count))")
}
let runnerCount = occurrences("searchPath.environment(for: executable)", in: readSource("Tally/Core/CLIRunner.swift"))
expect(runnerCount == 1, "C10 CLIRunner.run spawns through its searcher (\(runnerCount))")

print("\(checks) checks, \(failures) failed")
if failures > 0 { exit(1) }
