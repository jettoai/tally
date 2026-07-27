import Darwin
import Foundation

// Group 20: taking a worktree's processes down (TallyCLI/WorktreeKill.swift) - the order they are
// signalled in, the rescan that catches a respawn, and handing the terminal back. Runs as one
// function main.swift calls, which owns the shared harness (`check`, `sh`, `tempDir`, `rp`).

func runKillChecks() {
    // MARK: - 20a. Signal order and terminal selection (pure)

    let supervisor = ProcInfo(pid: 100, ppid: 1, name: "bash", cwd: "/wt")
    let child = ProcInfo(pid: 101, ppid: 100, name: "claude", cwd: "/wt")
    let unrelated = ProcInfo(pid: 102, ppid: 1, name: "fswatch", cwd: "/wt")
    let ordered = killWaves([child, unrelated, supervisor])
    check("a target that parents another target is signalled first",
          ordered.supervisors.map(\.pid) == [100])
    check("everything else follows in the order it was scanned",
          ordered.rest.map(\.pid) == [101, 102])
    check("our own binary counts as a supervisor even with no parent known",
          killWaves([ProcInfo(pid: 1, name: "claude", cwd: "/wt"),
                     ProcInfo(pid: 2, name: "tally", cwd: "/wt")]).supervisors.map(\.pid) == [2])
    check("with no supervisor among them the order is untouched",
          killWaves([child, unrelated]).supervisors.isEmpty &&
          killWaves([child, unrelated]).rest.map(\.pid) == [101, 102])
    check("an empty batch has no waves",
          killWaves([]).supervisors.isEmpty && killWaves([]).rest.isEmpty)

    check("the terminals to restore are the distinct ones, first seen first",
          terminalsToRestore([ProcInfo(pid: 1, name: "claude", cwd: "/wt", tty: "/dev/ttys003"),
                              ProcInfo(pid: 2, name: "tally", cwd: "/wt", tty: "/dev/ttys001"),
                              ProcInfo(pid: 3, name: "claude", cwd: "/wt", tty: "/dev/ttys003")])
            == ["/dev/ttys003", "/dev/ttys001"])
    check("a process with no terminal contributes none",
          terminalsToRestore([ProcInfo(pid: 1, name: "claude", cwd: "/wt"),
                              ProcInfo(pid: 2, name: "claude", cwd: "/wt", tty: "")]).isEmpty)

    // MARK: - 20b. The rescan loop, over real child processes

    // Every process signalled below is one this test started: a pid that is not ours is never
    // passed to the killer, so a regression cannot reach anything else on the machine.
    func spawnSleeper() -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try? process.run()
        return process
    }
    func info(_ process: Process, ppid: pid_t = 0, name: String = "claude") -> ProcInfo {
        ProcInfo(pid: process.processIdentifier, ppid: ppid, name: name, cwd: "/wt")
    }
    func waitUntilGone(_ process: Process) -> Bool {
        var waited = 0
        while process.isRunning, waited < 50 { usleep(100_000); waited += 1 }
        return !process.isRunning
    }

    let original = spawnSleeper()
    let respawn = spawnSleeper()
    var served = false
    let caught = killWorktreeProcesses([info(original)], rescan: {
        if served { return [] }
        served = true
        return [info(respawn)]
    })
    check("a process that appeared after the kill is caught by the rescan", caught == 2)
    check("the original is gone", waitUntilGone(original))
    check("and so is the one that replaced it", waitUntilGone(respawn))

    // A worktree that keeps producing processes ends the command with a warning rather than
    // spinning in it: the loop signals one batch plus at most two more.
    let endless = (0 ..< 4).map { _ in spawnSleeper() }
    var queue = Array(endless.dropFirst())
    var rescans = 0
    let bounded = killWorktreeProcesses([info(endless[0])], rescan: {
        rescans += 1
        return queue.isEmpty ? [] : [info(queue.removeFirst())]
    })
    check("the loop signals one batch plus two rescans, never more",
          bounded == worktreeKillRounds && rescans == worktreeKillRounds)
    check("everything it reached is gone",
          endless.prefix(3).allSatisfy(waitUntilGone))
    check("the one past the bound is left running, not silently lost", endless[3].isRunning)
    endless[3].terminate()

    // MARK: - 20c. A parent that respawns its child, end to end

    // The shape of the field failure: a supervisor whose whole job is to relaunch the child it is
    // watching. Signalled together, it notices the dead child first and starts one that no list
    // from before the kill can name; the fix signals it first and confirms it is gone.
    let harness = tempDir()
    let pidFile = "\(harness)/children"
    let script = "\(harness)/supervisor.sh"
    try? """
    #!/bin/bash
    while true; do
      /bin/sleep 30 &
      echo $! >> "$1"
      wait $!
    done
    """.write(toFile: script, atomically: true, encoding: .utf8)
    let fakeSupervisor = Process()
    fakeSupervisor.executableURL = URL(fileURLWithPath: "/bin/bash")
    fakeSupervisor.arguments = [script, pidFile]
    try? fakeSupervisor.run()

    func recordedChildren() -> [pid_t] {
        let text = (try? String(contentsOfFile: pidFile, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }
    var waited = 0
    while recordedChildren().isEmpty, waited < 50 { usleep(100_000); waited += 1 }
    let firstChild = recordedChildren().first ?? 0
    check("the fake supervisor started a child to watch", firstChild > 0)

    let supervisorPid = fakeSupervisor.processIdentifier
    let batch = [ProcInfo(pid: firstChild, ppid: supervisorPid, name: "claude", cwd: "/wt"),
                 ProcInfo(pid: supervisorPid, ppid: 0, name: "bash", cwd: "/wt")]
    let signalled = killWorktreeProcesses(batch, rescan: {
        recordedChildren().filter { kill($0, 0) == 0 }
            .map { ProcInfo(pid: $0, ppid: supervisorPid, name: "claude", cwd: "/wt") }
    })
    check("the supervisor and its child were both signalled", signalled >= 2)
    check("the supervisor is gone", waitUntilGone(fakeSupervisor))
    check("no child of it is left running, respawned or otherwise",
          recordedChildren().allSatisfy { kill($0, 0) != 0 })

    // MARK: - 20d. Handing a terminal back

    check("the notice says who printed it, what happened, and what to do",
          worktreeShellNotice.hasPrefix("[tally] ") && worktreeShellNotice.contains("closed")
              && worktreeShellNotice.contains("cd elsewhere"))
    check("it is one line of ASCII with no em dash",
          !worktreeShellNotice.contains("\n") && !worktreeShellNotice.contains("\u{2014}"))

    // A real pty put into the state a killed TUI leaves behind: canonical input and signal keys
    // off, which is what turns Ctrl+C into a byte and mouse movement into text on screen.
    let controller = posix_openpt(O_RDWR | O_NOCTTY | O_NONBLOCK)
    check("the test could open a pty to break", controller >= 0)
    if controller >= 0 {
        grantpt(controller)
        unlockpt(controller)
        let devicePath = ptsname(controller).map { String(cString: $0) } ?? ""
        let device = open(devicePath, O_RDWR | O_NOCTTY)
        var raw = termios()
        tcgetattr(device, &raw)
        raw.c_lflag &= ~tcflag_t(ICANON | ISIG | ECHO)
        tcsetattr(device, TCSANOW, &raw)
        var broken = termios()
        tcgetattr(device, &broken)
        check("the pty really is in the broken state before the restore",
              broken.c_lflag & tcflag_t(ISIG) == 0 && broken.c_lflag & tcflag_t(ICANON) == 0)

        restoreTerminals([devicePath])

        var restored = termios()
        tcgetattr(device, &restored)
        check("Ctrl+C makes a signal again after the restore",
              restored.c_lflag & tcflag_t(ISIG) != 0)
        check("and the line discipline is back to canonical with echo",
              restored.c_lflag & tcflag_t(ICANON) != 0 && restored.c_lflag & tcflag_t(ECHO) != 0)

        // Everything written to the device shows up on the controller side, which is what a person
        // watching the tab sees: the reset sequence first, then the notice, in that order.
        var seen = ""
        var reads = 0
        var buffer = [UInt8](repeating: 0, count: 4096)
        while reads < 20, !seen.contains(worktreeShellNotice) {
            let count = read(controller, &buffer, buffer.count)
            if count > 0 { seen += String(decoding: buffer[0 ..< count], as: UTF8.self) }
            reads += 1
            usleep(20_000)
        }
        check("the tab is told what happened and how to get out of it",
              seen.contains(worktreeShellNotice))
        check("the notice lands after the reset, not before it",
              (seen.range(of: "\u{1B}[?1000l")?.lowerBound).map { reset in
                  seen.range(of: worktreeShellNotice).map { $0.lowerBound > reset } ?? false
              } == true)
        check("restoring a terminal that does not exist is a no-op, not a failure",
              { restoreTerminals(["/dev/definitely-not-a-tty"]); return true }())
        close(device)
        close(controller)
    }
}
