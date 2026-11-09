import Foundation

// Assertion harness for the tmux priority guard (B-4266): the rules
// (Tally/Core/TmuxPriorityLogic.swift), the reader (TmuxPriorityReaders.swift) against `ps`, and
// the structural promises a pure harness cannot drive (the tick it rides, nothing spawned or
// signalled, `pth_priority` and never `pti_priority`).

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS: \(name)") } else { failures += 1; print("FAIL: \(name)") }
}
func source(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}
/// What `ps` prints for a pid, the oracle the reader is held to.
func psPriority(_ pid: pid_t) -> Int? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-o", "pri=", "-p", String(pid)]
    let pipe = Pipe()
    task.standardOutput = pipe
    guard (try? task.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

// MARK: the rule: a low server with an agent under it, and nothing else

expect(TmuxPriorityLogic.shouldWarn(priority: 31, hasAgent: true) == false, "31 with agents does not warn")
expect(TmuxPriorityLogic.shouldWarn(priority: 37, hasAgent: true) == false, "above normal does not warn")
expect(TmuxPriorityLogic.shouldWarn(priority: 20, hasAgent: true), "20 with agents warns")
expect(TmuxPriorityLogic.shouldWarn(priority: 30, hasAgent: true), "30 is already below normal and warns")
expect(TmuxPriorityLogic.shouldWarn(priority: 20, hasAgent: false) == false,
       "20 with neither claude nor codex under it does not warn")
expect(TmuxPriorityLogic.shouldWarn(priority: nil, hasAgent: true) == false,
       "an unreadable priority does not warn")
expect(TmuxPriorityLogic.isLow(nil) == false && TmuxPriorityLogic.isLow(0), "nil is not low, 0 is")

// MARK: what counts as an agent

expect(TmuxPriorityLogic.isAgentPath("/Users/u/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude"),
       "the Claude Code app binary")
expect(TmuxPriorityLogic.isAgentPath("/Users/u/.local/share/claude/versions/2.1.233"),
       "a versioned Claude Code install is named by the directory above the version")
expect(TmuxPriorityLogic.isAgentPath("/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"),
       "the Codex binary")
expect(TmuxPriorityLogic.isAgentPath("/opt/homebrew/bin/zsh") == false, "a shell is not an agent")
expect(TmuxPriorityLogic.isAgentPath("/usr/bin/python3") == false, "python is not an agent")
expect(TmuxPriorityLogic.isAgentPath("/Users/u/claude-notes/vim") == false, "a directory named claude is not a program")
expect(TmuxPriorityLogic.isAgentPath("") == false && TmuxPriorityLogic.isAgentPath("/") == false,
       "an empty path is nobody")

// MARK: descendants

let parents: [pid_t: pid_t] = [10: 1, 11: 10, 12: 11, 13: 10, 20: 1, 21: 20, 30: 31, 31: 30]
expect(TmuxPriorityLogic.descendants(of: 10, parents: parents) == [11, 13, 12],
       "descendants come breadth first and stay under the root")
expect(TmuxPriorityLogic.descendants(of: 99, parents: parents).isEmpty, "a root with no children has none")
expect(TmuxPriorityLogic.descendants(of: 30, parents: parents) == [31], "a parent cycle ends the walk")

// MARK: announce once per server

var tracker = TmuxPriorityTracker()
let low = TmuxServerReading(pid: 5445, priority: 20, hasAgent: true)
expect(tracker.fold([low]) == [low], "a low server with agents is announced")
expect(tracker.fold([low]).isEmpty, "…once")
expect(tracker.fold([TmuxServerReading(pid: 5445, priority: 20, hasAgent: false)]).isEmpty
        && tracker.fold([low]).isEmpty, "…and not again when its agents leave for a minute and return")
let replacement = TmuxServerReading(pid: 6000, priority: 20, hasAgent: true)
expect(tracker.fold([replacement]) == [replacement], "a new pid is judged afresh")
expect(tracker.fold([TmuxServerReading(pid: 6000, priority: 31, hasAgent: true)]).isEmpty
        && tracker.fold([replacement]) == [replacement],
       "a server that recovered and fell again is announced again")
var quiet = TmuxPriorityTracker()
expect(quiet.fold([TmuxServerReading(pid: 1, priority: 31, hasAgent: true),
                   TmuxServerReading(pid: 2, priority: 20, hasAgent: false),
                   TmuxServerReading(pid: 3, priority: nil, hasAgent: true)]).isEmpty,
       "normal, agent-less and unreadable servers announce nothing")

// MARK: the words

let en: (String) -> String = { $0 }
let body = tmuxPriorityAlertBody(priority: 20, localized: en)
expect(tmuxPriorityAlertTitle(localized: en) == "tmux is running at low priority", "the title")
expect(body.contains("priority 20") && body.contains("slow cores") && body.contains("Restarting tmux")
        && body.contains("Save your work"), "the body says what, why, the fix and to save first")
expect(!body.contains("\u{2014}") && !tmuxPriorityAlertTitle(localized: en).contains("\u{2014}"),
       "no em dash in the words")
expect(tmuxPriorityLogLine(low, now: Date(timeIntervalSince1970: 0))
        == "1970-01-01T00:00:00Z tmux-low-priority pid=5445 priority=20 normal=31\n", "the log line")
expect(tmuxPriorityLogLine(TmuxServerReading(pid: 1, priority: nil, hasAgent: true)).contains("priority=unknown"),
       "an unreadable priority is written as unknown, not as a number")

// MARK: the reader against `ps`

let parentPid = getppid()
if let expected = psPriority(parentPid) {
    // Within 2: a busy process's priority moves by a point between the two reads. The thing told
    // apart is 20 against 31, which is nine.
    expect(abs((TmuxPriorityReaders.maxThreadPriority(of: parentPid) ?? -99) - expected) <= 2,
           "the reader agrees with ps on this process's parent (\(expected))")
} else {
    expect(true, "ps could not read the parent; comparison skipped")
}
expect(TmuxPriorityReaders.maxThreadPriority(of: 0x7fff_fff0) == nil,
       "a pid that does not exist reads as nil and does not crash")
let scanned = TmuxPriorityReaders.scan()
for server in scanned {
    guard let expected = psPriority(server.pid) else { continue }
    expect(abs((server.priority ?? -99) - expected) <= 2,
           "tmux server \(server.pid): reader \(server.priority.map(String.init) ?? "nil") is within 2 of ps \(expected)")
    expect(abs((TmuxPriorityReaders.maxThreadPriority(of: server.pid) ?? -99) - expected) <= 2,
           "tmux server \(server.pid): the max over its threads is the ps priority")
}
expect(TmuxPriorityReaders.scan(uid: 0x7fff_fff0).isEmpty, "a user with no processes has no servers")

// MARK: structure

let readers = source("Tally/Core/TmuxPriorityReaders.swift")
let monitor = source("Tally/Core/TmuxPriorityMonitor.swift")
let logic = source("Tally/Core/TmuxPriorityLogic.swift")
let timing = source("Tally/Stores/ProcessFootprintTiming.swift")
expect(!readers.isEmpty && !monitor.isEmpty && !logic.isEmpty && !timing.isEmpty, "the sources are readable")
expect(readers.contains("pth_priority") && !readers.contains("task.pti_priority") && !readers.contains(".pti_priority"),
       "the priority is read from the threads, never from pti_priority")
expect(timing.contains("TmuxPriorityMonitor.shared.tick()"), "the guard rides the footprint sampler's tick")
for file in [readers, monitor, logic] {
    expect(!file.contains("Timer(") && !file.contains("DispatchSourceTimer") && !file.contains("asyncAfter"),
           "no timer of its own")
    expect(!file.contains("Process()") && !file.contains("posix_spawn") && !file.contains("system(")
            && !file.contains("kill(") && !file.contains("SIGTERM") && !file.contains("kill-server"),
           "spawns nothing and signals nothing")
}
expect(monitor.contains("now.timeIntervalSince(last) < TmuxPriorityLogic.sampleInterval")
        && logic.contains("static let sampleInterval: TimeInterval = 60"), "one scan a minute by the clock")
expect(monitor.contains("HostHealthLogic.alertsEnabled(.standard)"), "it speaks through the host-health banner switch")

// MARK: the five languages

let catalogData = (try? Data(contentsOf: URL(fileURLWithPath: "Tally/Resources/Localizable.xcstrings"))) ?? Data()
let catalog = (try? JSONSerialization.jsonObject(with: catalogData)) as? [String: Any]
let strings = catalog?["strings"] as? [String: [String: Any]] ?? [:]
for key in ["tmux is running at low priority",
            "tmux runs at priority %@ (normal is 31), so the Claude and Codex sessions under it are scheduled onto the slow cores. Restarting tmux restores it. Save your work before you restart."] {
    let localizations = strings[key]?["localizations"] as? [String: Any] ?? [:]
    for language in ["zh-Hant", "zh-Hans", "ja", "ko", "tr"] {
        let unit = (localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any]
        let value = unit?["value"] as? String ?? ""
        expect(unit?["state"] as? String == "translated" && !value.isEmpty && !value.contains("\u{2014}"),
               "\(language) translation present, no em dash: \(key.prefix(24))")
        if key.contains("%@") { expect(value.contains("%@"), "\(language) keeps the %@ argument") }
    }
}

print(failures == 0 ? "all tmux priority checks passed" : "\(failures) tmux priority checks failed")
exit(failures == 0 ? 0 : 1)
