import Darwin
import Foundation

// `tally events --follow [--since <seq>]`: print every spool event after a cursor, then block and
// print each newly appended one as a single JSON line (same encoding as `--since`). Local consumers
// get events as they happen with no listener, no URL and no polling of their own.
//
// TRIGGER: kqueue, not a sleep loop. The events DIRECTORY vnode fires on every rename in it (the
// `seq` rewrite, a trim renaming a new spool into place, the directory being recreated); the spool
// FILE vnode fires on appends. Both are needed: an append renames `seq` first and writes the line
// after (SessionWaitSpool.swift `appendSessionWaitEvent`), so the directory event alone arrives too
// early to see the line.
//
// SAFETY PUMP every `eventsFollowSafetyInterval` (60 s, the kevent timeout): kqueue delivers every
// event on a registered vnode, but there are windows with no watch at all (directory removed and
// recreated, spool replaced between the inode check and the reopen). One stat and one small `seq`
// read per minute closes them; it is a net, not the delivery path.
//
// SEQ RULES, per decoded line, in file order, per inode:
// - `seq <= cursor`: skip (dedupe across restarts and trim renames).
// - `seq == cursor + 1`: print, advance.
// - `seq > cursor + 1` on the FIRST decodable line of this inode: `trimmed` (a trim only ever
//   removes a prefix), exit.
// - `seq > cursor + 1` after an earlier decodable line of the same inode: a HOLE (an append whose
//   line write failed after it took its number). Warn, print, advance: the missing event never
//   reached disk, so exiting would restart every consumer at the same spot forever.
// - `latestWrittenSeq < cursor` on any pump: `rebuilt`, exit (checked before reading, because a
//   rebuilt spool's lines all have seq <= cursor and would otherwise be skipped silently forever).
//
// NO LOCK ON READ: a reader can see a line mid-write. Bytes after the last newline stay in `carry`
// and are never treated as a line until their newline arrives; a reopen (new inode) drops `carry`,
// because the trim that caused it ran under the appenders' lock after that write completed, so the
// complete line is in the new file.

enum EventsFollowResult: Equatable {
    case stopped                                   // a stop signal arrived
    case outputClosed                              // the consumer went away (EOF / EPIPE)
    case trimmed(cursor: Int, firstAvailable: Int) // events after cursor were cut from the spool
    case rebuilt(cursor: Int, latest: Int)         // the seq counter is below the cursor
    case setupFailed(String)                       // kqueue / dir open failed
}

let eventsFollowSafetyInterval: TimeInterval = 60

func followSessionWaitEvents(since: Int, dir: URL = tallyEventsDir, outputFD: Int32,
                             stopSignals: [Int32],
                             safetyInterval: TimeInterval = eventsFollowSafetyInterval,
                             warn: (String) -> Void) -> EventsFollowResult {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let spoolPath = dir.appendingPathComponent("spool.jsonl").path  // same name as SessionWaitSpool.swift
    let kq = kqueue()
    guard kq >= 0 else { return .setupFailed("kqueue failed: errno \(errno)") }
    defer { close(kq) }

    func register(_ ident: Int32, _ filter: Int32, _ fflags: Int32 = 0) {
        var change = kevent(ident: UInt(ident), filter: Int16(filter),
                            flags: UInt16(EV_ADD | EV_CLEAR), fflags: UInt32(fflags), data: 0, udata: nil)
        _ = kevent(kq, &change, 1, nil, 0, nil)
    }
    let vnodeFlags = NOTE_WRITE | NOTE_EXTEND | NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE | NOTE_ATTRIB

    for sig in stopSignals { register(sig, EVFILT_SIGNAL) }

    _ = fcntl(outputFD, F_SETNOSIGPIPE, 1)   // same call as Tally/Core/Harness/HarnessProcess.swift
    var outStat = stat()
    if fstat(outputFD, &outStat) == 0,
       (outStat.st_mode & S_IFMT) == S_IFIFO || (outStat.st_mode & S_IFMT) == S_IFSOCK {
        register(outputFD, EVFILT_WRITE)      // EV_EOF once the last reader closes
    }

    var dirFD: Int32 = -1
    func openDir() {
        if dirFD >= 0 { close(dirFD) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirFD = open(dir.path, O_EVTONLY)
        if dirFD >= 0 { register(dirFD, EVFILT_VNODE, vnodeFlags) }
    }
    openDir()
    guard dirFD >= 0 else { return .setupFailed("cannot watch \(dir.path)") }
    defer { if dirFD >= 0 { close(dirFD) } }

    var fileFD: Int32 = -1
    var filePos: Int64 = 0            // bytes consumed from fileFD (complete lines + carry)
    var carry = Data()                // bytes after the last newline: a partial line, never consumed
    var prevSeqInFile: Int? = nil     // seq of the previous decodable line in THIS inode
    var cursor = since
    defer { if fileFD >= 0 { close(fileFD) } }

    let decoder = sessionWaitEventDecoder()
    let encoder = sessionWaitEventEncoder()

    func openSpool() {   // precondition: fileFD closed
        fileFD = open(spoolPath, O_RDONLY)
        filePos = 0; carry = Data(); prevSeqInFile = nil
        if fileFD >= 0 { register(fileFD, EVFILT_VNODE, vnodeFlags) }
    }

    /// Write one line to the consumer; false = consumer gone (EPIPE or any other write error).
    func writeLine(_ line: String) -> Bool {
        let bytes = Array((line + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { write(outputFD, $0.baseAddress, $0.count) }
            if n < 0 { if errno == EINTR { continue }; return false }
            offset += n
        }
        return true
    }

    /// Read fileFD to EOF, emit every complete line. Returns an exit result or nil to keep going.
    func drain() -> EventsFollowResult? {
        guard fileFD >= 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fileFD, &buffer, buffer.count)
            if n < 0 { if errno == EINTR { continue }; return nil }
            if n == 0 { return nil }
            filePos += Int64(n)
            carry.append(contentsOf: buffer[0..<n])
            while let newline = carry.firstIndex(of: 0x0A) {
                let lineData = carry[carry.startIndex..<newline]
                carry.removeSubrange(carry.startIndex...newline)
                guard let event = try? decoder.decode(SessionWaitEvent.self, from: Data(lineData))
                else { continue }                          // undecodable: skip, like readSessionWaitEvents
                defer { prevSeqInFile = event.seq }
                if event.seq <= cursor { continue }        // already delivered (or before --since)
                if event.seq > cursor + 1 {
                    if prevSeqInFile == nil {              // nothing earlier in this inode: a trimmed prefix
                        return .trimmed(cursor: cursor, firstAvailable: event.seq)
                    }
                    warn("tally events --follow: seq hole (not a trim): expected \(cursor + 1), "
                         + "got \(event.seq); continuing")
                }
                guard let data = try? encoder.encode(event),
                      let json = String(data: data, encoding: .utf8) else { continue }
                guard writeLine(json) else { return .outputClosed }
                cursor = event.seq
            }
        }
    }

    /// One catch-up pass: regression check, drain current inode, switch inode if the path moved.
    func pump() -> EventsFollowResult? {
        let latest = latestWrittenSeq(dir: dir)
        if latest < cursor { return .rebuilt(cursor: cursor, latest: latest) }
        var dirStat = stat(), dirFDStat = stat()
        if stat(dir.path, &dirStat) != 0 || fstat(dirFD, &dirFDStat) != 0
            || dirStat.st_ino != dirFDStat.st_ino || dirStat.st_dev != dirFDStat.st_dev { openDir() }
        // Old inode first: a trim may have cut lines we can still read here.
        if let result = drain() { return result }
        var pathStat = stat(), fdStat = stat()
        let pathExists = stat(spoolPath, &pathStat) == 0
        let sameInode = fileFD >= 0 && fstat(fileFD, &fdStat) == 0 && pathExists
            && pathStat.st_ino == fdStat.st_ino && pathStat.st_dev == fdStat.st_dev
            && Int64(pathStat.st_size) >= filePos
        if !sameInode {
            if fileFD >= 0 { close(fileFD); fileFD = -1 }  // closing the fd drops its kevent
            if pathExists { openSpool(); if let result = drain() { return result } }
        }
        return nil
    }

    // `[kevent](...)` would parse as an array of the kevent FUNCTION, hence the explicit init.
    var events = Array(repeating: kevent(ident: 0, filter: 0, flags: 0, fflags: 0, data: 0, udata: nil),
                       count: 8)
    while true {
        if let result = pump() { return result }
        var timeout = timespec(tv_sec: Int(safetyInterval), tv_nsec: 0)
        let count = kevent(kq, nil, 0, &events, Int32(events.count), &timeout)
        if count < 0 { if errno == EINTR { continue }; return .setupFailed("kevent failed: errno \(errno)") }
        for event in events.prefix(Int(count)) {
            if event.filter == Int16(EVFILT_SIGNAL) { return .stopped }
            if event.filter == Int16(EVFILT_WRITE), event.flags & UInt16(EV_EOF) != 0 { return .outputClosed }
        }
    }
}
