import Foundation

// A supervised session keeps one Claude Code task list across every relaunch (TaskListPin.swift).
func runTaskListPinChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("tally-tasklist-\(UUID().uuidString)")
    try! fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    var round = 0
    /// A new scratch directory per case, so no case sees another's files.
    func scratch() -> String {
        round += 1
        let dir = root.appendingPathComponent("case\(round)").path
        try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
    func env(_ id: String?, base: [String: String]) -> [String: String] {
        supervisedChildEnvironment(provider: providers[0], home: "/tmp/A", supervisorVersion: nil,
                                   supervisorPID: "1", supervisorStartedAt: nil, taskListID: id,
                                   base: base)
    }

    // T1
    check("child env carries the session's task list",
          env("session-abc12345", base: [:])[taskListEnvKey] == "session-abc12345")

    // T2
    check("a nested launch never passes the outer list on",
          env(nil, base: [taskListEnvKey: "session-outer000"])[taskListEnvKey] == nil
              && initialTaskListPin(home: "/tmp/A",
                                    base: ["TALLY_SUPERVISOR_PID": "999",
                                           taskListEnvKey: "session-outer000"],
                                    fresh: { "session-new00000" }).id == "session-new00000")

    // T2b
    check("an unsupervised launch from inside a supervised session drops the outer list",
          unsupervisedLaunchUnsets(["TALLY_SUPERVISOR_PID": "999",
                                    taskListEnvKey: "session-outer000"]) == [taskListEnvKey]
              && unsupervisedLaunchUnsets([taskListEnvKey: "shared_1"]).isEmpty
              && ((try? String(contentsOfFile: "TallyCLI/Snapshot.swift", encoding: .utf8)) ?? "")
                  .contains("for key in unsupervisedLaunchUnsets(ProcessInfo.processInfo.environment) { unsetenv(key) }"))

    // T3
    check("a user-exported list is honoured when nothing supervises the parent",
          initialTaskListPin(home: "/tmp/A", base: [taskListEnvKey: "shared_1"],
                             fresh: { "session-new00000" }).id == "shared_1")
    check("an id Claude Code would rewrite is not honoured",
          initialTaskListPin(home: "/tmp/A", base: [taskListEnvKey: "a/b"],
                             fresh: { "session-new00000" }).id == "session-new00000")

    // T5
    let base5 = scratch()
    let homeA = base5 + "/homeA", homeB = base5 + "/homeB"
    try! fm.createDirectory(atPath: homeA, withIntermediateDirectories: true)
    try! fm.createDirectory(atPath: homeB, withIntermediateDirectories: true)
    let pin = initialTaskListPin(home: homeA, base: [:], fresh: { "session-t5000000" })
    let inA = taskListDir(home: homeA, id: pin.id), inB = taskListDir(home: homeB, id: pin.id)
    let placedA = placeTaskList(pin, inHome: homeA)
    let placedB = placeTaskList(pin, inHome: homeB)
    try? "{\"id\":\"1\"}".write(toFile: inB + "/1.json", atomically: true, encoding: .utf8)
    check("a relaunch onto another home reaches the same list",
          placedA == .inPlace && placedB == .linked
              && (try? String(contentsOfFile: inA + "/1.json", encoding: .utf8)) == "{\"id\":\"1\"}"
              && realTaskListPath(inB) == realTaskListPath(inA))

    // T6
    let again = placeTaskList(pin, inHome: homeB)
    let elsewhere = scratch()
    try? fm.removeItem(atPath: inB)
    try? fm.createSymbolicLink(atPath: inB, withDestinationPath: elsewhere)
    let wrong = placeTaskList(pin, inHome: homeB)
    check("an existing link is left alone and a wrong one replaced",
          again == .alreadyLinked && wrong == .relinked
              && realTaskListPath(inB) == realTaskListPath(inA))

    // T7
    let base7 = scratch()
    let homeC = base7 + "/homeC"
    let inC = taskListDir(home: homeC, id: pin.id)
    try! fm.createDirectory(atPath: inC, withIntermediateDirectories: true)
    try! "{}".write(toFile: inC + "/7.json", atomically: true, encoding: .utf8)
    let moved = placeTaskList(pin, inHome: homeC, now: Date(timeIntervalSince1970: 1_000))
    let aside = inC + ".tally-aside-1000"
    check("a real directory in the way is moved aside, never merged or deleted",
          moved == .movedAside(aside, 1) && fm.fileExists(atPath: aside + "/7.json")
              && realTaskListPath(inC) == realTaskListPath(inA))

    // T8
    let base8 = scratch()
    let homeD = base8 + "/homeD"
    try! fm.createDirectory(atPath: homeD, withIntermediateDirectories: true)
    let orphan = TaskListPin(id: "session-t8000000",
                             dir: base8 + "/removedHome/tasks/session-t8000000")
    let rebuilt = placeTaskList(orphan, inHome: homeD)
    let expected = TaskListPin(id: orphan.id, dir: taskListDir(home: homeD, id: orphan.id))
    var isDir: ObjCBool = false
    check("a list whose home is gone is rebuilt where the session now runs",
          rebuilt == .rebased(expected)
              && fm.fileExists(atPath: expected.dir, isDirectory: &isDir) && isDir.boolValue)
    // T8b: B's list was a link into A (an earlier move), and A is gone.
    let base8c = scratch()
    let homeE = base8c + "/homeE"
    let linkedE = taskListDir(home: homeE, id: orphan.id)
    try! fm.createDirectory(atPath: homeE + "/tasks", withIntermediateDirectories: true)
    try! fm.createSymbolicLink(atPath: linkedE, withDestinationPath: orphan.dir)
    let relisted = placeTaskList(orphan, inHome: homeE)
    let wrote = (try? "{}".write(toFile: linkedE + "/1.json", atomically: true, encoding: .utf8)) != nil
    isDir = false
    check("a dangling link into a removed home is replaced by a real list",
          relisted == .rebased(TaskListPin(id: orphan.id, dir: linkedE))
              && fm.fileExists(atPath: linkedE, isDirectory: &isDir) && isDir.boolValue && wrote)
    // A home that exists but has never held a list is not a removed home.
    let base8b = scratch()
    let freshPin = initialTaskListPin(home: base8b, base: [:], fresh: { "session-t8b00000" })
    check("a first list in a home with no tasks directory yet is created in place",
          placeTaskList(freshPin, inHome: base8b) == .inPlace)

    // T9
    func trip(_ carried: TaskListPin?) -> ResuperviseArgs {
        parseResuperviseArgs(Array(selfUpdateArgv(
            binary: "/usr/local/bin/tally", id: "a", label: "A", home: "/h", follow: true,
            taskList: carried, args: ["--resume", "x"]).dropFirst(2)))
    }
    let carried = TaskListPin(id: "session-t9000000", dir: "/h/tasks/session-t9000000")
    check("the pin survives a self-update exec",
          trip(carried).taskList == carried && trip(carried).childArgs == ["--resume", "x"])
    check("an id with a slash does not ride the exec",
          trip(TaskListPin(id: "a/b", dir: "/h/tasks/x")).taskList == nil)
    check("an argv from a build predating the flag parses as no list",
          parseResuperviseArgs(["--id", "a", "--home", "/h", "--", "--resume", "x"]).taskList == nil)

    // Publication, read by a board.
    let stateDir = URL(fileURLWithPath: scratch())
    publishTaskListPin(pin, pid: "4242", dir: stateDir)
    check("the session publishes its list id and real directory",
          (try? String(contentsOf: stateDir.appendingPathComponent("4242.tasklist"),
                       encoding: .utf8)) == "\(pin.id)\n\(realTaskListPath(inA))\n"
              && supervisorStatePid(ofFile: "4242.tasklist") == 4242)

    // handoff.log record: one stamped line per event, like every other record in that file.
    let logLine = taskListLine(pid: "54630", pin: pin, source: "unpinned-predecessor",
                               now: Date(timeIntervalSince1970: 0))
    check("the tasklist record is its own stamped line",
          logLine.hasPrefix("1970-01-01T00:00:00Z tasklist pid=54630 ")
              && logLine.contains(" source=unpinned-predecessor")
              && logLine.hasSuffix("\n") && logLine.filter { $0 == "\n" }.count == 1)

    // A supervisor that died takes `<spid>.tasklist` with it; the conversation record outlives it.
    let records = URL(fileURLWithPath: scratch()), states = URL(fileURLWithPath: scratch())
    let conv = "0e2d823d-1111-4222-8333-444455556666"
    let other = "aa544868-154c-47a0-9d3a-e0cf25447e31"
    // C1
    recordConversationTaskList(pin, conversation: conv, dir: records)
    check("a resumed conversation takes back the list it was recorded with",
          conversationTaskListPin(conv, selfPID: "999999", recordDir: records, stateDir: states)
              == TaskListPin(id: pin.id, dir: realTaskListPath(inA)))
    // C2: no record, no record directory, and a list directory that is gone.
    let gone = TaskListPin(id: "session-c2000000", dir: scratch() + "/removed")
    recordConversationTaskList(gone, conversation: other, dir: records)
    check("no record, no record directory, or a removed list reads as no pin",
          conversationTaskListPin(nil, selfPID: "999999", recordDir: records, stateDir: states) == nil
              && conversationTaskListPin("11111111-2222-4333-8444-555555555555", selfPID: "999999",
                                         recordDir: records, stateDir: states) == nil
              && conversationTaskListPin(conv, selfPID: "999999",
                                         recordDir: records.appendingPathComponent("absent"),
                                         stateDir: states) == nil
              && conversationTaskListPin(other, selfPID: "999999", recordDir: records,
                                         stateDir: states) == nil)
    // C3: this test process stands in for a live supervisor publishing the same list.
    publishTaskListPin(pin, pid: String(getpid()), dir: states)
    check("a list another live supervisor holds is not taken",
          conversationTaskListPin(conv, selfPID: "999999", recordDir: records, stateDir: states) == nil
              && conversationTaskListPin(conv, selfPID: String(getpid()), recordDir: records,
                                         stateDir: states) != nil)
    try? fm.removeItem(at: states.appendingPathComponent("\(getpid()).tasklist"))
    // C4: the recorder follows a `/clear` onto the new conversation, same list.
    let followRecords = URL(fileURLWithPath: scratch())
    var recorder = ConversationTaskListRecorder()
    recorder.sync(nil, pin: pin, dir: followRecords)
    recorder.sync(conv, pin: pin, dir: followRecords)
    recorder.sync(other, pin: pin, dir: followRecords)
    check("a changed conversation id is recorded with the same list",
          recordedConversationTaskList(conv, dir: followRecords) != nil
              && recordedConversationTaskList(conv, dir: followRecords)
                  == recordedConversationTaskList(other, dir: followRecords))
    // C4b: a fork's watcher reports the parent's id first; the parent's record must not change.
    let forkRecords = URL(fileURLWithPath: scratch())
    let forkPin = TaskListPin(id: "session-f0000000", dir: scratch())
    recordConversationTaskList(pin, conversation: conv, dir: forkRecords)
    var forkRecorder = ConversationTaskListRecorder(forkedFrom: conv)
    forkRecorder.sync(conv, pin: forkPin, dir: forkRecords)
    forkRecorder.sync(other, pin: forkPin, dir: forkRecords)
    check("a fork never records its list under the conversation it forked from",
          recordedConversationTaskList(conv, dir: forkRecords)?.id == pin.id
              && recordedConversationTaskList(other, dir: forkRecords)?.id == forkPin.id)
    // C5: the start mode names a cleared, unused conversation back (launchchecks.swift), and the
    // supervisor looks it up; a fork writes a new conversation and never does.
    let supervisorSource = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift",
                                        encoding: .utf8)) ?? ""
    check("a cleared, never-used predecessor is looked up, a fork never is",
          supervisorSource.contains(
              "let resumedConversation = optionsOnly(launchArgs).contains(\"--fork-session\") ? nil")
              && supervisorSource.contains(
                  ": (flagValue(launchArgs, \"--resume\") ?? flagValue(launchArgs, \"-r\") ?? clearedConversation)")
              && supervisorSource.contains(
                  "let recorded = conversationTaskListPin(resumedConversation, selfPID: supervisorPID)"))
    // C6
    let broken = URL(fileURLWithPath: scratch())
    let brokenForms = ["\(pin.id)\n", "a/b\n\(inA)\n", "\(pin.id)\nrelative/dir\n",
                       "\(pin.id)\n\(inA)\nextra\n", ""]
    let brokenReads = brokenForms.map { body -> TaskListPin? in
        try? body.write(to: broken.appendingPathComponent(conv), atomically: true, encoding: .utf8)
        return conversationTaskListPin(conv, selfPID: "999999", recordDir: broken, stateDir: states)
    }
    check("a malformed record reads as no pin",
          brokenReads.allSatisfy { $0 == nil }
              && recordedConversationTaskList("../\(conv)", dir: records) == nil)
}
