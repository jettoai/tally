import Darwin
import Foundation

// Which Claude Code task list a supervised session writes, kept the same across every relaunch.
//
// Claude Code picks the list per PROCESS: without `CLAUDE_CODE_TASK_LIST_ID` it names the list
// after the implicit team it creates at start-up, `session-<first 8 of this run's id>`, so every
// relaunch (a move to another account, a self-update, a reload) starts writing an empty list while
// the old one sits in the previous config home (measured on 2.1.284, 2026-09-29). The variable
// wins over every team name, so pinning it per session and making `<home>/tasks/<id>` resolve to
// one real directory keeps a single list for the life of the session.
//
// A session still under a supervisor from before this build changes list once, at the upgrade:
// which list its child was writing is another process's state, and it is not inferred here.

let taskListEnvKey = "CLAUDE_CODE_TASK_LIST_ID"
let taskListPublishedSuffix = ".tasklist"

/// The list a session writes: the id handed to every child, and the one real directory behind it.
struct TaskListPin: Equatable {
    let id: String
    /// Absolute path of the directory that holds the list. Every home the session lands on gets
    /// `<home>/tasks/<id>` pointing here.
    let dir: String
}

/// Claude Code rewrites anything outside this set to "-" before using the id as a directory name,
/// so an id outside it would name a different directory than the one this file links.
func isTaskListID(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 128 else { return false }
    return value.unicodeScalars.allSatisfy {
        ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" || $0 == "_"
    }
}

/// Same shape as Claude Code's own default, so tools that list `tasks/session-*` still see it.
func freshTaskListID(_ uuid: UUID = UUID()) -> String {
    "session-" + String(uuid.uuidString.prefix(8)).lowercased()
}

func taskListDir(home: String, id: String) -> String {
    URL(fileURLWithPath: home).appendingPathComponent("tasks").appendingPathComponent(id).path
}

/// Resolves symlinks in the whole path (a home's `tasks` may itself be a link).
func realTaskListPath(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
}

/// The pin for a session starting now. An id in the environment is honoured only when nothing
/// supervised this process's parent: a `tally claude` started from inside another supervised
/// session inherits that session's id, and writing into it would merge two sessions' lists.
func initialTaskListPin(home: String, base: [String: String],
                        fresh: () -> String = { freshTaskListID() }) -> TaskListPin {
    let nested = base["TALLY_SUPERVISOR_PID"].map { !$0.isEmpty } ?? false
    if !nested, let own = base[taskListEnvKey], isTaskListID(own) {
        return TaskListPin(id: own, dir: realTaskListPath(taskListDir(home: home, id: own)))
    }
    let id = fresh()
    return TaskListPin(id: id, dir: taskListDir(home: home, id: id))
}

// MARK: - Making the pinned list reachable from the home a child is about to run in

enum TaskListPlacement: Equatable {
    case inPlace          // the home IS where the list lives
    case linked           // a new symlink
    case alreadyLinked
    case relinked         // a symlink to somewhere else was replaced
    case movedAside(String, Int)   // a real directory was renamed out of the way (json count)
    case rebased(TaskListPin)      // the list's own home is gone; a new directory here
    case failed
}

func placeTaskList(_ pin: TaskListPin, inHome home: String,
                   now: Date = Date()) -> TaskListPlacement {
    let fm = FileManager.default
    var pin = pin
    var rebased = false
    // The config home that held the list (dir is `<home>/tasks/<id>`). Gone means the account was
    // removed, and its list with it: start a new one where the session now runs.
    let listHome = URL(fileURLWithPath: pin.dir).deletingLastPathComponent()
        .deletingLastPathComponent().path
    if !fm.fileExists(atPath: listHome) {
        pin = TaskListPin(id: pin.id, dir: taskListDir(home: home, id: pin.id))
        rebased = true
    }
    try? fm.createDirectory(atPath: pin.dir, withIntermediateDirectories: true)
    let target = taskListDir(home: home, id: pin.id)
    if realTaskListPath(target) == realTaskListPath(pin.dir) {
        return rebased ? .rebased(pin) : (isSymlink(target) ? .alreadyLinked : .inPlace)
    }
    try? fm.createDirectory(atPath: URL(fileURLWithPath: target).deletingLastPathComponent().path,
                            withIntermediateDirectories: true)
    var outcome = TaskListPlacement.linked
    if isSymlink(target) {
        outcome = .relinked
    } else if fm.fileExists(atPath: target) {
        // Never merged, never deleted: whatever was written here stays readable beside the link.
        let aside = target + ".tally-aside-\(Int(now.timeIntervalSince1970))"
        let count = ((try? fm.contentsOfDirectory(atPath: target)) ?? [])
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.count
        guard (try? fm.moveItem(atPath: target, toPath: aside)) != nil else { return .failed }
        outcome = .movedAside(aside, count)
    }
    // Atomic replace: link under a temporary name, then rename over the target.
    let temp = target + ".tally-link-\(getpid())"
    try? fm.removeItem(atPath: temp)
    guard (try? fm.createSymbolicLink(atPath: temp, withDestinationPath: pin.dir)) != nil,
          rename(temp, target) == 0 else {
        try? fm.removeItem(atPath: temp)
        return .failed
    }
    return rebased ? .rebased(pin) : outcome
}

private func isSymlink(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
}

/// What a board reads to find this session's list: id on line 1, the real directory on line 2.
func publishTaskListPin(_ pin: TaskListPin, pid: String, dir: URL = supervisorStateDir) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? "\(pin.id)\n\(realTaskListPath(pin.dir))\n"
        .write(to: dir.appendingPathComponent(pid + taskListPublishedSuffix),
               atomically: true, encoding: .utf8)
}

func taskListLine(pid: String, pin: TaskListPin, source: String,
                  placement: TaskListPlacement? = nil) -> String {
    var line = "tasklist pid=\(pid) id=\(pin.id) dir=\(pin.dir) source=\(source)"
    if let placement { line += " placement=\(placement)" }
    return line
}
