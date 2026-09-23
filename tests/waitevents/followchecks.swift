import Foundation

// `tally events --follow` (TallyCLI/EventsFollow.swift), F1-F16. Each check runs the follower as a
// real child process (this test binary re-executed in child mode, see the top of `main.swift`) so
// stdout is a real pipe, signals are real signals and the exit code is a real exit code. Every child
// is started against a fresh temp dir; `t12Event` and `expect` are top-level in `main.swift`.

/// One follower child. Stdout lines are collected as they arrive; stderr is read once after exit.
final class FollowChild {
    let process = Process()
    private let out = Pipe()
    private let err = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var collected: [String] = []
    private let lineArrived = DispatchSemaphore(value: 0)
    private let exitedSignal = DispatchSemaphore(value: 0)
    private var hasExited = false
    private var stderrCache: String?

    init(dir: URL, args: [String]) {
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        var env = ProcessInfo.processInfo.environment
        env["TALLY_WAITEVENTS_FOLLOW_CHILD_DIR"] = dir.path
        env["TALLY_WAITEVENTS_FOLLOW_CHILD_ARGS"] = args.joined(separator: " ")
        process.environment = env
        process.standardOutput = out
        process.standardError = err
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self.lock.lock()
            self.buffer.append(data)
            var added = 0
            while let newline = self.buffer.firstIndex(of: 0x0A) {
                self.collected.append(String(decoding: self.buffer[self.buffer.startIndex..<newline],
                                             as: UTF8.self))
                self.buffer.removeSubrange(self.buffer.startIndex...newline)
                added += 1
            }
            self.lock.unlock()
            for _ in 0..<added { self.lineArrived.signal() }
        }
        let exitedSignal = self.exitedSignal
        process.terminationHandler = { _ in exitedSignal.signal() }
        try? process.run()
    }

    var lines: [String] { lock.lock(); defer { lock.unlock() }; return collected }

    /// Waits until at least `n` lines arrived or the deadline passes; returns what arrived.
    @discardableResult
    func waitForLines(_ n: Int, timeout: TimeInterval) -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        while lines.count < n {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 || lineArrived.wait(timeout: .now() + left) == .timedOut { break }
        }
        return lines
    }

    func seqs() -> [Int] {
        let decoder = sessionWaitEventDecoder()
        return lines.compactMap { try? decoder.decode(SessionWaitEvent.self, from: Data($0.utf8)).seq }
    }

    func waitExit(timeout: TimeInterval) -> (status: Int32, reason: Process.TerminationReason)? {
        if !hasExited {
            guard exitedSignal.wait(timeout: .now() + timeout) == .success else { return nil }
            hasExited = true
        }
        return (process.terminationStatus, process.terminationReason)
    }

    /// `waitExit`, stopping the child when it has not exited by then so a failed check never leaks it.
    func waitExitOrStop(timeout: TimeInterval) -> (status: Int32, reason: Process.TerminationReason)? {
        let exit = waitExit(timeout: timeout)
        if exit == nil { stop() }
        return exit
    }

    /// Only after the child exited (reading earlier would block on a live writer).
    func stderrText() -> String {
        if let stderrCache { return stderrCache }
        let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        stderrCache = text
        return text
    }

    func closeStdout() {
        out.fileHandleForReading.readabilityHandler = nil
        out.fileHandleForReading.closeFile()
    }

    /// Stops reading but keeps the read end open, so the child's stdout pipe fills and stays full.
    func pauseReading() { out.fileHandleForReading.readabilityHandler = nil }

    func stop() {
        if waitExit(timeout: 0) == nil, process.isRunning {
            process.terminate()
            if waitExit(timeout: 2) == nil {
                kill(process.processIdentifier, SIGKILL)
                _ = waitExit(timeout: 2)
            }
        }
    }
}

func runFollowChecks() {
    func freshDir(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tally-waitevents-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    func appendReal(_ dir: URL) { appendSessionWaitEvent(t12Event, dir: dir) }
    func encodedLine(seq: Int) -> String {
        var event = t12Event
        event.seq = seq
        return String(decoding: (try? sessionWaitEventEncoder().encode(event)) ?? Data(), as: UTF8.self)
    }
    func crafted(_ seqs: [Int]) -> Data {
        Data(seqs.map { encodedLine(seq: $0) + "\n" }.joined().utf8)
    }
    func writeSeq(_ dir: URL, _ next: Int) {
        try? "\(next)".write(to: dir.appendingPathComponent("seq"), atomically: true, encoding: .utf8)
    }
    func writeCrafted(_ dir: URL, seqs: [Int], nextSeq: Int) {
        try? crafted(seqs).write(to: dir.appendingPathComponent("spool.jsonl"))
        writeSeq(dir, nextSeq)
    }
    /// A trim-style replacement: a new inode renamed over the spool path.
    func renameOver(_ dir: URL, seqs: [Int]) {
        let tmp = dir.appendingPathComponent("spool.jsonl.tmp-x")
        try? crafted(seqs).write(to: tmp)
        _ = rename(tmp.path, dir.appendingPathComponent("spool.jsonl").path)
    }
    func appendBytes(_ dir: URL, _ data: Data) {
        guard let handle = try? FileHandle(forWritingTo: dir.appendingPathComponent("spool.jsonl"))
        else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    }
    func follow(_ dir: URL, _ args: [String]) -> FollowChild {
        FollowChild(dir: dir, args: ["--follow"] + args)
    }
    let negativeWindow: TimeInterval = 0.4

    // F1: a new event reaches the consumer within a bounded time (kernel file events, not a timer).
    do {
        let dir = freshDir("f1")
        for _ in 0..<3 { appendReal(dir) }
        let child = follow(dir, ["--since", "2"])
        child.waitForLines(1, timeout: 5)
        let started = Date()
        appendReal(dir)
        child.waitForLines(2, timeout: 1.0)
        let elapsed = Date().timeIntervalSince(started)
        expect(child.seqs() == [3, 4] && elapsed < 1.0,
               "F1: a new event is printed within 1.0 s (measured \(Int(elapsed * 1000)) ms, seqs \(child.seqs()))")
        child.stop()
    }

    // F2: --since start point is exact: no duplicate, no skip.
    do {
        let dir = freshDir("f2")
        for _ in 0..<5 { appendReal(dir) }
        let child = follow(dir, ["--since", "2"])
        child.waitForLines(3, timeout: 5)
        appendReal(dir)
        child.waitForLines(4, timeout: 2)
        expect(child.seqs() == [3, 4, 5, 6], "F2: --since 2 prints exactly 3,4,5 then 6 (\(child.seqs()))")
        child.stop()
    }

    // F3: no --since starts at --latest-seq (only new events).
    do {
        let dir = freshDir("f3")
        for _ in 0..<3 { appendReal(dir) }
        let child = follow(dir, [])
        Thread.sleep(forTimeInterval: negativeWindow)
        let before = child.lines.count
        appendReal(dir)
        child.waitForLines(1, timeout: 2)
        Thread.sleep(forTimeInterval: 0.1)
        expect(before == 0 && child.seqs() == [4],
               "F3: without --since only the new event is printed (before \(before), seqs \(child.seqs()))")
        child.stop()
    }

    // F4: follow keeps working across a trim-style rename (new inode), no dup, no skip.
    do {
        let dir = freshDir("f4")
        for _ in 0..<3 { appendReal(dir) }
        let child = follow(dir, ["--since", "0"])
        child.waitForLines(3, timeout: 5)
        renameOver(dir, seqs: [2, 3])
        appendReal(dir)
        appendReal(dir)
        child.waitForLines(5, timeout: 2)
        Thread.sleep(forTimeInterval: 0.1)
        expect(child.seqs() == [1, 2, 3, 4, 5], "F4: a trim rename is followed (\(child.seqs()))")
        child.stop()
    }

    // F5: --since below a trimmed prefix exits 3 naming the case and both numbers.
    do {
        let dir = freshDir("f5")
        writeCrafted(dir, seqs: [5, 6, 7], nextSeq: 8)
        let child = follow(dir, ["--since", "1"])
        let exit = child.waitExitOrStop(timeout: 2)
        let text = child.stderrText()
        expect(exit?.status == 3 && exit?.reason == .exit && text.contains("trimmed")
               && text.contains("cursor 1") && text.contains("seq 5") && child.lines.isEmpty,
               "F5: trimmed prefix at start exits 3 (\(String(describing: exit)), \(text.debugDescription))")
    }

    // F6: a trim that cuts past the cursor while following exits 3.
    do {
        let dir = freshDir("f6")
        for _ in 0..<3 { appendReal(dir) }
        let child = follow(dir, ["--since", "0"])
        child.waitForLines(3, timeout: 5)
        writeSeq(dir, 10)
        renameOver(dir, seqs: [8, 9])
        let exit = child.waitExitOrStop(timeout: 2)
        let text = child.stderrText()
        expect(exit?.status == 3 && text.contains("trimmed") && text.contains("cursor 3")
               && text.contains("seq 8"),
               "F6: a trim past the cursor while following exits 3 (\(String(describing: exit)), \(text.debugDescription))")
    }

    // F7: seq regression at start (cursor above the latest written seq) exits 3 before printing.
    do {
        let dir = freshDir("f7")
        writeCrafted(dir, seqs: [1, 2, 3], nextSeq: 4)
        let child = follow(dir, ["--since", "30"])
        let exit = child.waitExitOrStop(timeout: 2)
        let text = child.stderrText()
        expect(exit?.status == 3 && text.contains("rebuilt") && text.contains("cursor 30")
               && text.contains("latest seq 3") && child.lines.isEmpty,
               "F7: seq regression at start exits 3 (\(String(describing: exit)), \(text.debugDescription))")
    }

    // F8: seq regression while following (spool and counter wiped, appends restart at 1) exits 3.
    do {
        let dir = freshDir("f8")
        for _ in 0..<3 { appendReal(dir) }
        let child = follow(dir, ["--since", "0"])
        child.waitForLines(3, timeout: 5)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("spool.jsonl"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("seq"))
        appendReal(dir)
        let exit = child.waitExitOrStop(timeout: 2)
        let text = child.stderrText()
        expect(exit?.status == 3 && text.contains("rebuilt"),
               "F8: seq regression while following exits 3 (\(String(describing: exit)), \(text.debugDescription))")
    }

    // F9: a hole that is not a trim is warned about and skipped; the follower keeps running.
    do {
        let dir = freshDir("f9")
        writeCrafted(dir, seqs: [1, 2, 4], nextSeq: 5)
        let child = follow(dir, ["--since", "0"])
        child.waitForLines(3, timeout: 2)
        Thread.sleep(forTimeInterval: negativeWindow)
        let running = child.waitExit(timeout: 0) == nil
        appendReal(dir)
        child.waitForLines(4, timeout: 2)
        child.stop()
        let text = child.stderrText()
        expect(child.seqs() == [1, 2, 4, 5] && running && text.contains("seq hole")
               && text.contains("expected 3"),
               "F9: a non-trim hole is warned and followed past (\(child.seqs()), running \(running), \(text.debugDescription))")
    }

    // F10: a partial last line is neither printed nor skipped; it prints once its newline lands.
    do {
        let dir = freshDir("f10")
        for _ in 0..<2 { appendReal(dir) }
        let child = follow(dir, ["--since", "1"])
        child.waitForLines(1, timeout: 5)
        writeSeq(dir, 4)
        let line = Data(encodedLine(seq: 3).utf8)
        let half = line.count / 2
        appendBytes(dir, line.prefix(half))
        Thread.sleep(forTimeInterval: negativeWindow)
        let whileTorn = child.lines.count
        appendBytes(dir, line.suffix(from: line.startIndex + half) + Data("\n".utf8))
        child.waitForLines(2, timeout: 1.0)
        expect(whileTorn == 1 && child.seqs() == [2, 3],
               "F10: a partial line waits for its newline (torn \(whileTorn), seqs \(child.seqs()))")
        child.stop()
    }

    // F11: the consumer closing stdout ends the follower (no write needed to notice).
    do {
        let dir = freshDir("f11")
        appendReal(dir)
        let child = follow(dir, ["--since", "0"])
        child.waitForLines(1, timeout: 5)
        child.closeStdout()
        let exit = child.waitExitOrStop(timeout: 2)
        expect(exit?.status == 0 && exit?.reason == .exit,
               "F11: closing stdout ends the follower with 0 (\(String(describing: exit)))")
    }

    // F12: SIGTERM ends the follower cleanly with 0.
    do {
        let dir = freshDir("f12")
        appendReal(dir)
        let child = follow(dir, ["--since", "0"])
        child.waitForLines(1, timeout: 5)
        child.process.terminate()
        let exit = child.waitExitOrStop(timeout: 2)
        expect(exit?.status == 0 && exit?.reason == .exit,
               "F12: SIGTERM ends the follower with 0 (\(String(describing: exit)))")
    }

    // F13: a non-integer --since is a usage error (2), not a follow.
    do {
        let dir = freshDir("f13")
        let child = follow(dir, ["--since", "x"])
        let exit = child.waitExitOrStop(timeout: 2)
        expect(exit?.status == 2, "F13: --follow --since x exits 2 (\(String(describing: exit)))")
    }

    // F14: the events dir does not exist yet; the first append into it is followed.
    do {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tally-waitevents-f14-\(UUID().uuidString)/events")
        let child = follow(dir, ["--since", "0"])
        Thread.sleep(forTimeInterval: negativeWindow)
        let started = Date()
        appendReal(dir)
        child.waitForLines(1, timeout: 1.0)
        let elapsed = Date().timeIntervalSince(started)
        expect(child.seqs() == [1] && elapsed < 1.0,
               "F14: a missing events dir is created and followed (\(Int(elapsed * 1000)) ms, seqs \(child.seqs()))")
        child.stop()
    }

    // F15/F16: a stop signal ends the follower with 0 even while its stdout pipe is full and the
    // consumer keeps the read end open without reading.
    for (tag, sig) in [("F15", SIGTERM), ("F16", SIGINT)] {
        let dir = freshDir(tag.lowercased())
        writeCrafted(dir, seqs: Array(1...3000), nextSeq: 3001)   // ~1 MB, far over a 64 KiB pipe
        let child = follow(dir, ["--since", "0"])
        child.pauseReading()
        Thread.sleep(forTimeInterval: 1.0)                         // let the pipe fill
        let filled = child.lines.count < 3000                      // non-vacuous: output really backed up
        kill(child.process.processIdentifier, sig)
        let exit = child.waitExitOrStop(timeout: 2)
        expect(filled && exit?.status == 0 && exit?.reason == .exit,
               "\(tag): signal \(sig) ends a follower blocked on a full stdout pipe with 0 "
               + "(filled \(filled), \(String(describing: exit)))")
    }
}
