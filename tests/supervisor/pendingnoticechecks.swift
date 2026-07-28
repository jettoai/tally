import Foundation

// The pending-notice badge (PendingNotice.swift): the supervisor's "waiting to do X" moved off the
// terminal it shares with the child and onto the status line.
//
// Why it exists at all: `warn` writes to stderr wherever the cursor is, and the child is drawing a
// TUI there. A message before a restart is fine (the TUI is about to be torn down); a message about
// something NOT happening yet lands in the input box and survives the next redraw as half a line
// (reported twice with screenshots, 2026-07-28). The split is enforced by the source assertions at
// the end of this file, because no value assertion can see where a string was printed.

func runPendingNoticeChecks() {
    // MARK: - 27. The state file

    let noticeDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-notice-\(UUID().uuidString)")
    let noticeAt = Date(timeIntervalSince1970: 1_800_000_000)
    check("nothing pending reads as nothing", readPendingNotice(pid: "111", dir: noticeDir) == nil)
    let queued = PendingNotice(badge: "reload at idle", detail: "restarting when idle",
                               since: noticeAt)
    writePendingNotice(queued, pid: "111", dir: noticeDir)
    check("a written notice round-trips whole",
          readPendingNotice(pid: "111", dir: noticeDir) == queued)
    // One file per pid, exactly like the drift state beside it: two sessions in one terminal
    // multiplexer must never read each other's badge.
    check("another supervisor's pid has its own answer",
          readPendingNotice(pid: "222", dir: noticeDir) == nil)
    // The file sits BESIDE the presence entry rather than replacing it: that entry's existence is
    // what `tally reload` counts, and a notice must not be read as another live supervisor.
    markSupervisorLive(pid: "111", dir: noticeDir)
    check("the notice does not inflate the live-supervisor count",
          liveSupervisorPids(dir: noticeDir) == (supervisorAlive(111) ? [111] : []))
    check("and the presence entry is not the notice",
          readDriftState(pid: "111", dir: noticeDir) == nil)
    clearPendingNotice(pid: "111", dir: noticeDir)
    check("clearing removes the notice", readPendingNotice(pid: "111", dir: noticeDir) == nil)
    check("and leaves the presence entry alone",
          FileManager.default.fileExists(atPath: noticeDir.appendingPathComponent("111").path))
    check("a malformed body reads as nothing pending, not as a crash", {
        try? "not json".write(to: pendingNoticeFile(pid: "333", dir: noticeDir), atomically: true,
                              encoding: .utf8)
        return readPendingNotice(pid: "333", dir: noticeDir) == nil
    }())

    // MARK: - 27b. Written only when it changes

    // The loop polls every 2s and most ticks change nothing. Rewriting regardless would replace the
    // file 30 times a minute per session for the whole of a wait, and would reset `since` each time,
    // so the badge could never carry how long the wait has run.
    var writer = PendingNoticeWriter()
    writer.sync(PendingBadge("reload at idle"), pid: "444", dir: noticeDir, now: noticeAt)
    let first = readPendingNotice(pid: "444", dir: noticeDir)
    check("the first sync writes the badge", first?.badge == "reload at idle")
    check("stamped with when the wait began", first?.since == noticeAt)
    let stamp = try? FileManager.default.attributesOfItem(
        atPath: pendingNoticeFile(pid: "444", dir: noticeDir).path)[.modificationDate] as? Date
    writer.sync(PendingBadge("reload at idle"), pid: "444", dir: noticeDir,
                now: noticeAt.addingTimeInterval(120))
    let unchanged = try? FileManager.default.attributesOfItem(
        atPath: pendingNoticeFile(pid: "444", dir: noticeDir).path)[.modificationDate] as? Date
    check("the same badge again does not touch the file", stamp == unchanged)
    check("so the wait keeps its original start time",
          readPendingNotice(pid: "444", dir: noticeDir)?.since == noticeAt)
    // A badge that CHANGES is a different wait (or the same one escalating), so it is written and
    // re-stamped.
    writer.sync(PendingBadge("reload waiting (keyboard)"), pid: "444", dir: noticeDir,
                now: noticeAt.addingTimeInterval(300))
    let escalated = readPendingNotice(pid: "444", dir: noticeDir)
    check("an escalated badge is written", escalated?.badge == "reload waiting (keyboard)")
    check("and re-stamped, because it is news of its own",
          escalated?.since == noticeAt.addingTimeInterval(300))
    writer.sync(nil, pid: "444", dir: noticeDir, now: noticeAt)
    check("nothing pending unlinks the file", readPendingNotice(pid: "444", dir: noticeDir) == nil)
    // Idempotent in the empty direction too: a session with nothing queued spends its whole life
    // here, and it must not be a delete syscall every 2 seconds.
    writer.sync(nil, pid: "444", dir: noticeDir, now: noticeAt)
    check("and staying empty stays quiet", readPendingNotice(pid: "444", dir: noticeDir) == nil)

    // MARK: - 27c. The sweep reaches both files

    // A SIGKILLed supervisor runs no clear path. Its presence file was already swept; without the
    // notice being swept too, the next process to inherit that pid would wear a dead session's
    // "reload at idle" - the same stale-badge failure the sweep exists to prevent.
    check("a notice file names its supervisor", supervisorStatePid(ofFile: "12345.notice") == 12345)
    check("so does a plain presence file", supervisorStatePid(ofFile: "12345") == 12345)
    check("and nothing else in the directory does",
          supervisorStatePid(ofFile: "notes.txt") == nil
              && supervisorStatePid(ofFile: ".notice") == nil)
    let sweepAt = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-notice-sweep-\(UUID().uuidString)")
    let mine = String(getpid())
    for pid in ["99999", mine] {
        markSupervisorLive(pid: pid, dir: sweepAt)
        writePendingNotice(PendingNotice(badge: "reload at idle", detail: nil, since: noticeAt),
                           pid: pid, dir: sweepAt)
    }
    try? "notes".write(to: sweepAt.appendingPathComponent("notes.txt"), atomically: true,
                       encoding: .utf8)
    sweepDeadSupervisorState(dir: sweepAt)
    check("a dead supervisor's notice is swept", readPendingNotice(pid: "99999", dir: sweepAt) == nil)
    check("along with its presence entry",
          !FileManager.default.fileExists(atPath: sweepAt.appendingPathComponent("99999").path))
    check("a live supervisor keeps its notice", readPendingNotice(pid: mine, dir: sweepAt) != nil)
    check("and files that are not ours are still left alone",
          FileManager.default.fileExists(atPath: sweepAt.appendingPathComponent("notes.txt").path))
    try? FileManager.default.removeItem(at: sweepAt)
    try? FileManager.default.removeItem(at: noticeDir)

    // MARK: - 27d. One badge, chosen by priority

    // A status line badge is the one thing worth knowing now, not a log: two of them would push the
    // quota meters off the edge. So they are ranked, and everything under the winner waits its turn
    // (each is re-derived from live state every tick, so a covered badge appears the moment the one
    // above it clears).
    let reload = PendingBadge("reload at idle")
    let deadEnd = PendingBadge("no account for fable")
    let queuedFollow = PendingBadge("model change at idle")
    let cap = PendingBadge("cap: waiting for a sibling")
    check("nothing pending chooses nothing", PendingBadges().chosen == nil)
    check("a reload the user asked for outranks everything",
          PendingBadges(reload: reload, followDeadEnd: deadEnd, followQueued: queuedFollow,
                        capWaiting: cap).chosen == reload)
    check("a follow with nowhere to land outranks one merely queued",
          PendingBadges(followDeadEnd: deadEnd, followQueued: queuedFollow,
                        capWaiting: cap).chosen == deadEnd)
    check("a queued follow outranks a capped wait",
          PendingBadges(followQueued: queuedFollow, capWaiting: cap).chosen == queuedFollow)
    check("and a capped wait shows when it is the only thing left",
          PendingBadges(capWaiting: cap).chosen == cap)

    // MARK: - 27e. What the loop's state turns into

    let policy = LaunchPolicy(model: "claude-fable-5", effort: "xhigh")
    let deadEndBadges = supervisorPendingBadges(reload: nil, followDeadEnd: true,
                                                followQueued: false, policy: policy,
                                                capReason: nil)
    check("a dead-ended follow names the model nothing can serve",
          deadEndBadges.chosen?.badge == "no account for fable")
    check("and keeps the sentence it used to print as the detail",
          deadEndBadges.chosen?.detail?.contains("no eligible account can serve it yet") == true)
    let queuedBadges = supervisorPendingBadges(reload: nil, followDeadEnd: false,
                                               followQueued: true, policy: policy, capReason: nil)
    check("a queued follow says the change is coming",
          queuedBadges.chosen?.badge == "model change at idle")
    check("with the model and effort it will adopt in the detail",
          queuedBadges.chosen?.detail?.contains("claude-fable-5/xhigh") == true)
    check("a capped session names what it is waiting for",
          supervisorPendingBadges(reload: nil, followDeadEnd: false, followQueued: false,
                                  policy: policy,
                                  capReason: "waiting for a sibling").chosen?.badge
              == "cap: waiting for a sibling")
    // The first tick after a cap has no reason yet (the waiting branch has not run), and "cap: " on
    // its own says nothing.
    check("a cap with no reason yet badges nothing",
          supervisorPendingBadges(reload: nil, followDeadEnd: false, followQueued: false,
                                  policy: policy, capReason: "").chosen == nil)
    check("and neither does a session with nothing pending at all",
          supervisorPendingBadges(reload: nil, followDeadEnd: false, followQueued: false,
                                  policy: policy, capReason: nil).chosen == nil)
    // A badge shares its row with the quota meters, so length is a real constraint, not a style.
    for badge in [reload, deadEnd, queuedFollow, deadEndBadges.chosen, queuedBadges.chosen] {
        guard let badge else { continue }
        check("the badge \"\(badge.badge)\" fits a status line", badge.badge.count <= 24)
    }

    // MARK: - 27f. The rendered piece

    let renderDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-notice-render-\(UUID().uuidString)")
    check("a supervisor with nothing pending renders nothing",
          pendingNoticePiece(pid: "555", dir: renderDir) == nil)
    writePendingNotice(PendingNotice(badge: "reload at idle", detail: nil, since: noticeAt),
                       pid: "555", dir: renderDir)
    check("and one with a badge renders it behind the waiting glyph",
          pendingNoticePiece(pid: "555", dir: renderDir) == "⏳ reload at idle")
    try? FileManager.default.removeItem(at: renderDir)

    // MARK: - 27g. The line the split is drawn on

    // No value assertion can see WHERE a string was printed, so the boundary lives in the source:
    // a branch that defers must not warn, and a branch that is about to terminate the child must.
    // Both halves are asserted, because a refactor that quietly silenced the second half would
    // leave the user with no explanation for a restart they are watching happen.
    let loop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    let reloadSource = (try? String(contentsOfFile: "TallyCLI/Reload.swift", encoding: .utf8)) ?? ""
    let driftSource = (try? String(contentsOfFile: "TallyCLI/DriftMonitor.swift",
                                   encoding: .utf8)) ?? ""
    check("the sources are readable from the pending-notice checks",
          !loop.isEmpty && !reloadSource.isEmpty && !driftSource.isEmpty)
    func section(_ source: String, from opening: String, to closing: String) -> String? {
        guard let start = source.range(of: opening),
              let end = source.range(of: closing, range: start.upperBound ..< source.endIndex)
        else { return nil }
        return String(source[start.upperBound ..< end.lowerBound])
    }
    // The deferring half.
    if let queuedBranch = section(reloadSource, from: "case .queued:", to: "// MARK: - CLI entry") {
        check("a queued reload says nothing on the terminal", !queuedBranch.contains("warn("))
        check("it raises a badge instead", queuedBranch.contains("notice.pending = PendingBadge("))
    } else {
        check("the queued branch was found", false)
    }
    // Both follow branches moved to FollowAdoption.swift; the assertions moved with them, unchanged
    // in meaning. The file also still holds the two announcements that MUST speak (an adoption
    // terminates the child), which the speaking half below covers.
    let followSource = (try? String(contentsOfFile: "TallyCLI/FollowAdoption.swift",
                                    encoding: .utf8)) ?? ""
    check("the follow adoption source is readable from the pending-notice checks",
          !followSource.isEmpty)
    if let deadEnd = section(followSource, from: "guard let repick else {",
                             to: "state.deadEnd = false") {
        check("a follow with nowhere to land says nothing on the terminal",
              !deadEnd.contains("warn("))
    } else {
        check("the follow dead end was found", false)
    }
    if let queuedFollowBranch = section(followSource, from: "// Queued behind", to: "}") {
        check("a queued follow says nothing on the terminal",
              !queuedFollowBranch.contains("warn("))
    } else {
        check("the queued follow branch was found", false)
    }
    if let capWait = section(loop, from: "if let note = action.waitingNote",
                             to: "// Follow the launch default:") {
        check("a capped session waiting for a sibling says nothing on the terminal",
              !capWait.contains("warn("))
    } else {
        check("the cap waiting branch was found", false)
    }
    if let started = section(driftSource, from: "case .started(let flag)?:",
                             to: "case .cleared(let duration)?:") {
        check("a safeguard drift raises a badge rather than a line",
              !started.contains("warn("))
    } else {
        check("the drift started branch was found", false)
    }
    check("and the five-minute drift reminder is gone with it",
          !driftSource.contains("shouldNudge"))
    // The speaking half: every one of these is printed as the child is being terminated, so the
    // terminal is about to be redrawn from scratch and the user needs to know why.
    for announcement in ["reload requested → restarting this session",
                         "cap hit → handing off to",
                         "nearly dry, moving to",
                         "model fell back to",
                         "pinned in Tally → switching to"] {
        let source = announcement.hasPrefix("reload") ? reloadSource
            : announcement.hasPrefix("launch default") ? followSource : loop
        check("\"\(announcement)\" still speaks, because the child is about to go",
              source.contains("warn(\"\(announcement)") || source.contains("\(announcement)"))
    }
    check("the tick keeps the badge in step with what it deferred",
          loop.contains("syncPendingNotice(&pendingNotice, pid: supervisorPID"))
    check("and an exiting supervisor takes its badge with it",
          loop.contains("clearPendingNotice(pid: supervisorPID)"))
}
