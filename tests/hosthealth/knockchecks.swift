import Foundation

// THE SENTENCE A SESSION IS TOLD, AND THE PROMISES AROUND IT: what the knock says, what it repairs
// on the way, when it is owed one at all, and the structural bounds none of that can be driven
// against (TallyCLI/HostHealthKnockLogic.swift, and the parts of Tally/Core/HostHealthLogic.swift
// the supervisor rather than the app reads).
//
// SPLIT OFF main.swift ON SIZE, the division tests/supervisor keeps: the entry file holds the
// fixtures, `expect` and the tally, and each topic is one `run*Checks()` next to it. Nothing here
// changed in the move.

func runKnockChecks() {
    // MARK: - 5. The sentence a session is told

    /// The byte budget the station hands in (`sessionInputMaxBytes`), mirrored here because this
    /// harness compiles no CLI file. Two source locks in section 7 are what keep the mirror true: one
    /// reads the number out of the channel that owns it, and one reads the call that hands it over.
    let knockBytes = 200

    do {
        let alarm = HostHealthAlarm(at: at(0), load1: 273, freeBytes: gigabyte * 9 / 10, top: sampleTop)
        expect(hostHealthKnockSentence(alarm, bytes: knockBytes)
                == "[host-health] load=273 free=0.9GB top=node,qemu,Google Chrome",
               "the sentence is one line naming the reading and what is holding the memory")
        let unnamed = HostHealthAlarm(at: at(0), load1: 273, freeBytes: gigabyte, top: [])
        expect(hostHealthKnockSentence(unnamed, bytes: knockBytes)
                == "[host-health] load=273 free=1.0GB",
               "…and leaves the phrase out entirely when the scan named nothing")
    }

    // A NAME IS A FILENAME, AND A FILENAME MAY HOLD ANYTHING. This sentence is typed into a terminal
    // one byte at a time, so a newline in the middle of it is a Return - the first half is submitted as
    // a prompt and the rest goes into whatever comes up next - and an ESC is a command to a TUI. The
    // fixture carries both, plus a name long enough to prove the cut is by BYTES: three ordinary names
    // (which is what this suite asserted "exactly one line" against until 2026-09-05) would stay green
    // with no repair anywhere in the path.
    do {
        let hostile = [HostHealthProcess(name: "node\u{1B}[31m\nqemu", rss: 14 * gigabyte),
                       HostHealthProcess(name: "\u{7}bell", rss: 6 * gigabyte),
                       HostHealthProcess(name: String(repeating: "測", count: 200), rss: 4 * gigabyte)]
        let alarm = HostHealthAlarm(at: at(0), load1: 273, freeBytes: gigabyte * 9 / 10, top: hostile)
        let line = hostHealthKnockSentence(alarm, bytes: knockBytes)
        expect(!line.contains("\n") && !line.contains("\r"), "…and is exactly one line")
        expect(!line.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) },
               "…with no byte in it a terminal reads as a keystroke rather than as text")
        expect(!line.contains("\u{1B}"), "…and no escape for a TUI to read as a command")
        expect(line.utf8.count <= knockBytes,
               "…inside the channel's byte budget (\(line.utf8.count) of \(knockBytes))")
        expect(!line.unicodeScalars.contains { $0.value == 0xFFFD },
               "…cut between characters rather than through one")
        expect(line.hasPrefix("[host-health] load=273 free=0.9GB top=node"),
               "…and what survives still reads as the sentence, naming the process")
    }

    // THE SAME NAMES REACH TWO MORE FACES, and both are records rather than prompts: one line per
    // event in `~/.tally/logs/host-health.log`, and one phrase shared by the status section and the
    // notification body. A newline in a name breaks each of those formats in its own way - a record
    // split in half, a `grep` hit with no reading on it, a status line that is suddenly two.
    do {
        let hostile = [HostHealthProcess(name: "node\u{1B}[31m\nqemu", rss: 14 * gigabyte),
                       HostHealthProcess(name: "\u{7}bell", rss: 6 * gigabyte)]
        let report = HostHealthReport(sampledAt: at(0), load1: 273, cores: 16,
                                      freeBytes: gigabyte * 9 / 10, state: .alarmed, since: at(0),
                                      lastAlarm: HostHealthAlarm(at: at(0), load1: 273,
                                                                 freeBytes: gigabyte * 9 / 10,
                                                                 top: hostile))
        let record = hostHealthLogLine(.alarm, report: report, now: at(0))
        let body = String(record.dropLast())
        expect(record.hasSuffix("\n") && !body.contains("\n") && !body.contains("\r"),
               "one event is one line in the log, whatever the names in it hold")
        expect(!body.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) },
               "…and no control byte survives into the record")
        expect(body.contains("top=node") && body.contains("bell:"),
               "…while what is left still names what was holding the memory")
        let phrase = hostHealthTopText(hostile, unit: "GB")
        expect(!phrase.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) },
               "the phrase the status line and the notification body are built out of carries none")
        let status = hostHealthStatusLine(report, now: at(0)) ?? ""
        expect(!status.contains("\n") && !status.contains("\u{1B}"),
               "…so the status section stays one line with no escape in it")
    }

    // A name that is nothing BUT those bytes is left out rather than printed as an empty field.
    do {
        let blank = HostHealthAlarm(at: at(0), load1: 273, freeBytes: gigabyte,
                                    top: [HostHealthProcess(name: "\u{1B}\u{7}", rss: gigabyte)])
        expect(hostHealthKnockSentence(blank, bytes: knockBytes) == "[host-health] load=273 free=1.0GB",
               "a name that strips to nothing is left out of the phrase")
    }

    // MARK: - 6. One sentence per alarm

    /// A report as the app would have published it: SAMPLED at one instant and carrying the alarm it
    /// raised at another. The two are the same instant on the sample that raises one, and drift apart
    /// for as long as it stands, which is what this document being rewritten every minute looks like.
    func alarmedReport(at moment: Date, alarmedAt raised: Date? = nil) -> HostHealthReport {
        let alarm = raised ?? moment
        return HostHealthReport(sampledAt: moment, load1: 273, cores: 16, freeBytes: gigabyte * 9 / 10,
                                state: .alarmed, since: alarm,
                                lastAlarm: HostHealthAlarm(at: alarm, load1: 273,
                                                           freeBytes: gigabyte * 9 / 10,
                                                           top: sampleTop))
    }

    do {
        var state = HostHealthKnockState()
        var reads = 0
        // Each look is one supervisor tick against the document as it stands that minute: a fresh
        // sampling instant, the same alarm underneath it, and the tick's own clock alongside.
        func look(_ minute: Int) -> HostHealthAlarm? {
            let stamp = at(minute)
            return HostHealthKnockLogic.observe(&state, stamp: stamp, now: stamp,
                                                read: { reads += 1
                                                        return alarmedReport(at: stamp,
                                                                             alarmedAt: at(0)) })
        }
        expect(look(0)?.at == at(0), "an alarmed report owes this session a sentence")
        expect(reads == 1, "…decoded once")
        // The station records the announcement only once the bytes are on their way, which is why the
        // reading before that still owes: a tick whose gate held has said nothing.
        expect(look(0)?.at == at(0), "…still owed while nothing has been said")
        expect(reads == 1, "…and the unchanged document is not decoded again")
        state.announced = at(0)
        expect(look(0) == nil, "once said, the same alarm is never said again")
        // The app rewrites this document every minute for as long as the alarm stands. A station keyed
        // on the document rather than on the alarm would say the same thing sixty times an hour.
        for minute in 1...60 {
            _ = look(minute)
        }
        expect(look(61) == nil, "…not even after the report has been rewritten sixty times")
        expect(reads == 62, "…though every rewrite was read")
    }

    // A SECOND alarm is different news, and is said.
    do {
        var state = HostHealthKnockState(seenAt: at(0), report: alarmedReport(at: at(0)),
                                         announced: at(0))
        let second = alarmedReport(at: at(30))
        let owed = HostHealthKnockLogic.observe(&state, stamp: at(30), now: at(30), read: { second })
        expect(owed?.at == at(30), "a machine that recovered and crossed again is announced again")
    }

    // A calm report owes nothing, and neither does an alarmed one this build cannot read an alarm out
    // of: an alarm with no instant on it could never be said exactly once.
    do {
        var state = HostHealthKnockState()
        let calmReport = HostHealthReport(sampledAt: at(0), load1: 3.2, cores: 16,
                                          freeBytes: 41 * gigabyte, state: .normal, since: at(0),
                                          lastAlarm: nil)
        expect(HostHealthKnockLogic.observe(&state, stamp: at(0), now: at(0),
                                            read: { calmReport }) == nil,
               "a calm report owes nothing")
        var second = HostHealthKnockState()
        let headless = HostHealthReport(sampledAt: at(0), load1: 273, cores: 16, freeBytes: gigabyte,
                                        state: .alarmed, since: at(0), lastAlarm: nil)
        expect(HostHealthKnockLogic.observe(&second, stamp: at(0), now: at(0),
                                            read: { headless }) == nil,
               "…and neither does an alarm with no instant on it")
        expect(HostHealthKnockLogic.observe(&second, stamp: at(0), now: at(0),
                                            read: { headless }) == nil,
               "…however many ticks look at it")
    }

    // A report that has GONE is not a machine that recovered: the cache goes with it, so a Tally that
    // was closed mid-alarm and reopened tells this session again.
    do {
        var state = HostHealthKnockState()
        let report = alarmedReport(at: at(0))
        _ = HostHealthKnockLogic.observe(&state, stamp: at(0), now: at(0), read: { report })
        state.announced = at(0)
        expect(HostHealthKnockLogic.observe(&state, stamp: nil, now: at(0), read: { report }) == nil,
               "no report on disk owes nothing")
        expect(state.report == nil && state.seenAt == nil, "…and the cache is dropped with it")
        state.announced = nil
        let back = alarmedReport(at: at(5), alarmedAt: at(0))
        expect(HostHealthKnockLogic.observe(&state, stamp: at(5), now: at(5),
                                            read: { back })?.at == at(0),
               "…and a report that comes back is read afresh")
    }

    // MARK: - 7. A reading nobody has rewritten in a while

    // THE DOCUMENT OUTLIVES THE APP THAT WROTE IT, which is the case the gone-report rule above does
    // not reach: a Tally closed mid-alarm leaves an alarmed file on disk, and to every supervisor that
    // starts afterwards it reads exactly like a machine in trouble right now. Nothing in the sentence
    // says how old it is, so the age has to decide whether it is said at all.
    do {
        var state = HostHealthKnockState()
        let report = alarmedReport(at: at(0))
        expect(HostHealthKnockLogic.observe(&state, stamp: at(0), now: at(6), read: { report }) == nil,
               "an alarm sampled six minutes ago is not announced as the machine right now")
        expect(state.report == report && state.seenAt == at(0),
               "…and the cache is left standing, so the next rewrite is judged on its own")
        var fresh = HostHealthKnockState()
        expect(HostHealthKnockLogic.observe(&fresh, stamp: at(0), now: at(4),
                                            read: { report })?.at == at(0),
               "…while one sampled four minutes ago still is")
    }

    // The line itself, from both sides of it: five samples, and the constant rather than a number
    // spelled twice.
    do {
        expect(HostHealthLogic.staleAfter == 5 * HostHealthLogic.sampleInterval,
               "the staleness line is five samples")
        let report = alarmedReport(at: at(0))
        var atLine = HostHealthKnockState()
        expect(HostHealthKnockLogic.observe(&atLine, stamp: at(0),
                                            now: at(0) + HostHealthLogic.staleAfter,
                                            read: { report })?.at == at(0),
               "a report exactly at the line is still news")
        var past = HostHealthKnockState()
        expect(HostHealthKnockLogic.observe(&past, stamp: at(0),
                                            now: at(0) + HostHealthLogic.staleAfter + 1,
                                            read: { report }) == nil,
               "…and one second past it is not")
    }

    // AND SILENCE IS NOT PERMANENT. The app coming back rewrites the document; a machine that is still
    // in trouble is announced off that fresh reading, alarm instant and all.
    do {
        var state = HostHealthKnockState()
        expect(HostHealthKnockLogic.observe(&state, stamp: at(0), now: at(30),
                                            read: { alarmedReport(at: at(0)) }) == nil,
               "a stale alarm says nothing")
        expect(HostHealthKnockLogic.observe(&state, stamp: at(30), now: at(30),
                                            read: { alarmedReport(at: at(30),
                                                                  alarmedAt: at(0)) })?.at == at(0),
               "…and the rewrite that follows says it, off the alarm it was raised at")
    }

    // MARK: - 8. The promises a pure harness cannot drive

    func source(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    let timing = source("Tally/Stores/ProcessFootprintTiming.swift")
    let monitor = source("Tally/Core/HostHealthMonitor.swift")
    let readers = source("Tally/Core/HostHealthReaders.swift")
    let station = source("TallyCLI/HostHealthKnock.swift")
    let loop = source("TallyCLI/Supervisor.swift")
    let statusCommand = source("TallyCLI/main.swift")
    let project = source("project.yml")

    expect(!timing.isEmpty && !monitor.isEmpty && !station.isEmpty && !loop.isEmpty,
           "the sources this suite reads are readable from it")

    // IT OPENS NO TIMER OF ITS OWN. The one timer in this feature is the footprint sampler's, which
    // already runs for the life of the process, and the watch rides it.
    expect(timing.contains("HostHealthMonitor.shared.tick()"),
           "the watch rides the footprint sampler's existing tick")
    expect(!monitor.contains("Timer(") && !monitor.contains("DispatchSourceTimer")
            && !monitor.contains("asyncAfter"),
           "…and starts no timer, queue or delay of its own")

    // AND SPAWNS NOTHING. The whole point of this landing in this app is that a machine which cannot
    // fork is exactly the machine this is reporting on.
    for file in [monitor, readers] {
        expect(!file.contains("Process()") && !file.contains("posix_spawn")
                && !file.contains("system("),
               "the watch runs no subprocess")
    }
    for command in ["/usr/bin/top", "/usr/bin/vm_stat", "/bin/ps", "/bin/sh", "/usr/bin/env"] {
        expect(!monitor.contains(command) && !readers.contains(command),
               "…and names no shell command (\(command))")
    }

    // THE THROTTLE IS BY THE CLOCK, so both of the sampler's rates deliver the same one sample a
    // minute.
    expect(monitor.contains("now.timeIntervalSince(last) < HostHealthLogic.sampleInterval"),
           "the watch throttles itself against the clock")
    expect(source("Tally/Core/HostHealthLogic.swift")
            .contains("static let sampleInterval: TimeInterval = 60"),
           "…at one sample a minute")

    // AN ORDINARY SAMPLE IS TWO SYSCALLS. The process table is walked in `heaviest` and nowhere else,
    // and `heaviest` is called from exactly one place: the branch that has just raised an alarm.
    expect(readers.contains("proc_listallpids") == false,
           "the sample path does not walk the process table itself")
    expect(readers.contains("ProcessTree.liveProcesses()"),
           "…the one walk it makes is the shared one")
    /// Where the block whose opening brace ends at `from` closes, by counting braces from there.
    ///
    /// NAIVE ABOUT BRACES INSIDE STRINGS AND COMMENTS, deliberately: what it measures is nine lines of
    /// arithmetic in a file this suite also asserts spawns nothing and opens no timer, and a matcher
    /// that parsed Swift to find the end of an `if` would be a larger thing than the promise it guards.
    func blockEnd(_ text: String, from: String.Index) -> String.Index? {
        var depth = 1
        var cursor = from
        while cursor < text.endIndex {
            switch text[cursor] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return cursor }
            default: break
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    do {
        let calls = monitor.components(separatedBy: "HostHealthReaders.heaviest()").count - 1
        expect(calls == 1, "the expensive scan has exactly one caller")
        guard let branch = monitor.range(of: "if event == .alarm {"),
              let call = monitor.range(of: "HostHealthReaders.heaviest()"),
              let close = blockEnd(monitor, from: branch.upperBound) else {
            expect(false, "the expensive scan sits inside the alarm branch")
            exit(1)
        }
        // BETWEEN THE BRANCH'S BRACES, not merely after the word `if`. The earlier version of this
        // assertion compared the two positions only, so moving the scan BELOW the closing brace - which
        // is every sample walking the process table, the exact cost this promise exists to bound - left
        // it green (codex review of 10f10b5).
        expect(branch.upperBound < call.lowerBound && call.upperBound <= close,
               "…and it sits inside the alarm branch, between its braces")
    }
    expect(monitor.contains("if event == .alarm { post(report) }"),
           "a recovery is written down and not announced")

    // THE NOTIFICATION'S OWN BODY CANNOT BE DRIVEN FROM HERE (it is @MainActor, localised and ends in
    // SystemAlert), so what is stated is where it gets its names: the one phrase this suite asserts
    // repairs them.
    expect(monitor.contains("hostHealthTopText(report.lastAlarm?.top ?? [], unit: \"GB\")"),
           "the banner's body is built out of the phrase the names are repaired in")

    // THE STATION SPEAKS LAST AND THROUGH THE EXISTING DOOR. Placed after the quota knock, told what
    // that knock typed, and holding entirely when a filed sentence is still sitting unread.
    do {
        guard let knock = loop.range(of: "applyQuotaKnock("),
              let host = loop.range(of: "applyHostHealthKnock(") else {
            expect(false, "the tick runs the host-health station")
            exit(1)
        }
        expect(knock.upperBound < host.lowerBound,
               "the host-health station speaks after the quota knock")
        let call = String(loop[host.lowerBound...].prefix(900))
        expect(call.contains("typedAlready: action.typed != nil || resumed != nil || knocked != nil"),
               "…and stays silent on a tick that has already written to this composer")
        expect(call.contains("filing: { quotaKnockFiling }"),
               "…and is filed or typed on the same reading the quota knock uses")
    }
    expect(station.contains("guard !undelivered(pid, dir) else { return nil }"),
           "a filed sentence nobody has read yet is not written over")
    expect(station.contains("sessionInputHold(state: session, quiet: quiet, turnEnded: turnEnded(),"),
           "the typed channel asks the same gate every other writer asks")
    expect(station.contains("state.announced = alarm.at"),
           "the announcement is recorded before the bytes go out")

    // THE STALENESS GATE IS FED THE STATION'S OWN CLOCK, which is the half a pure harness cannot see:
    // the rule is asserted above against instants handed in, and this is what hands the real one in.
    expect(station.contains("HostHealthKnockLogic.observe(&state, stamp: modified(file), now: now,"),
           "the station measures the report's age against this tick")

    // AND THE SENTENCE IS CUT BY BYTES. `String.prefix` counts CHARACTERS, so 200 CJK ones went in as
    // 600 bytes, and every one of them is 30ms the poll loop spends blocked (codex review of 10f10b5).
    expect(station.contains("hostHealthKnockSentence(alarm, bytes: sessionInputMaxBytes)"),
           "the station cuts the sentence to the channel's byte budget")
    expect(!station.contains(".prefix(sessionInputMaxBytes)"),
           "…and never by a character count")
    expect(source("TallyCLI/SessionInputRequest.swift").contains("let sessionInputMaxBytes = 200"),
           "…which is the 200 this suite's own budget mirrors")

    // AND NOTHING IN THIS FEATURE ENDS ANYTHING. The incident report asked for reporting first.
    for file in [monitor, readers, station, source("Tally/Core/HostHealthLogic.swift")] {
        expect(!file.contains("kill(") && !file.contains("SIGTERM") && !file.contains("SIGKILL"),
               "the watch signals nothing")
    }

    // The status section, and the one file both processes read the record out of.
    expect(statusCommand.contains("if let host = hostHealthStatusLine(loadHostHealthReport()) {"),
           "`tally status` prints the host section")
    expect(project.contains("- path: Tally/Core/HostHealthLogic.swift"),
           "…out of the record the CLI target compiles with the app")
    expect(project.contains("- path: Tally/Core/KeystrokeText.swift"),
           "…and the one rule the names in that sentence are repaired through, compiled by both")

    // The names in the report are executable names, never arguments: this document is read into a
    // conversation, and argv is a string that can carry a token.
    expect(readers.contains("ProcessTree.executablePath(of: entry.key)"),
           "the alarm names processes by their executable")
    expect(!readers.contains("KERN_PROCARGS") && !readers.contains("commandLine("),
           "…and never reads argv")
}
