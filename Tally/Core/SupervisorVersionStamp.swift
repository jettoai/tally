import Darwin
import Foundation

// WHICH BUILD IS WATCHING A SESSION, asked of the supervisor's CHILD rather than of the file the
// supervisor writes.
//
// Every supervisor stamps the build it captured at startup into the environment of every child it
// spawns (`supervisedChildEnvironment`), and has done since v0.26. It is what the status line
// inside that terminal already reads to say the supervisor updates at its next idle moment
// (Statusline.swift), so this is the SAME fact read a second way rather than a second fact: the
// board and the status line cannot disagree about a session, and a supervisor that replaces itself
// terminates its child first and spawns the next one with the new stamp (SelfUpdate.swift), so the
// reading corrects itself at the same instant the badge should come down.
//
// WHY NOT THE STATE FILE'S OWN FIELD, which is what the board shipped with (v0.64.3,
// `SessionStateRecord.supervisorVersion`). That field is written by builds from 0.64.3 onwards and
// by nothing older, and a supervisor that publishes no version reads as "cannot compare" - which is
// the right answer to give and the wrong answer to have on the day it matters, because the sessions
// a changeover leaves behind are by definition the ones on the OLDER build. Measured on this
// machine with 0.64.3 installed: four supervisors still running 0.64.2, four cards saying nothing,
// which is the same board an entirely up-to-date fleet draws. The field remains as the fallback for
// the case this reading cannot answer, and the two agree wherever both are present.
//
// ONE KEY, NEVER THE ENVIRONMENT. The child is a Claude Code process and its environment carries
// the user's credentials. Nothing here decodes that buffer into a dictionary or hands it to a
// caller: it is scanned for one prefix and one value comes back.
//
// sysctl RATHER THAN `ps`. A fork, an exec and a parse per card per refresh, twice a second for as
// long as a board is open, for a reading the kernel hands over directly. Same rule as the footprint
// readers next door (`ProcessTreeReaders`), for the same reason.

/// The variable a supervisor stamps its captured build into, for every child it spawns. Named here
/// as well as at the writing end because this is the other half of that contract, and the suite
/// pins the two against each other by asking the writer for a child environment and reading it back
/// with this key.
let supervisorVersionEnvKey = "TALLY_SUPERVISOR_VERSION"

/// The build of the supervisor that spawned this process, read out of its environment.
///
/// nil for everything the machine will not answer, which is ordinary rather than exceptional here:
/// the process has ended between the scan and this call, it belongs to another user (the kernel
/// refuses `KERN_PROCARGS2` outright), or it was spawned by a supervisor too old to stamp anything.
/// All three mean "cannot say", which is what the board draws nothing for.
func supervisorVersionStamp(ofProcess pid: Int) -> String? {
    guard let pid = Int32(exactly: pid) else { return nil }
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    // SIZED FIRST, then filled. The other way to size this buffer is `KERN_ARGMAX`, which is a
    // megabyte on this machine and which every published example allocates outright; a process's
    // actual arguments and environment measure about 4.5KB, and this runs once per card per refresh
    // for as long as somebody is looking at the board. The size probe cannot go stale between the
    // two calls: both halves of that buffer are fixed at exec.
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 0 else { return nil }
    return parseSupervisorVersion(procargs: Data(buffer.prefix(size)))
}

/// The stamp inside a `KERN_PROCARGS2` buffer, which is laid out as an argument count, the path the
/// program was executed from, alignment padding, that many arguments, and then the environment -
/// every part after the count being a NUL-terminated string.
///
/// THE COUNT IS WHAT SEPARATES THE TWO HALVES, and it is the only thing that does: arguments and
/// environment entries are the same shape of string in one run, so a scan that skipped the walk
/// would read a command line mentioning this variable as if the process had been launched with it.
/// The walk is cheap and the buffer states everything it needs.
///
/// Pure, and separated from the call above for the reason every reader in this project is: a
/// harness can state what a buffer means with no processes around it, and the shape of this one is
/// exactly where a silent misreading would live.
func parseSupervisorVersion(procargs: Data) -> String? {
    let header = MemoryLayout<Int32>.size
    guard procargs.count > header else { return nil }
    let argc = procargs.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int32.self) }
    guard argc >= 0 else { return nil }
    let fields = procargs.dropFirst(header).split(separator: 0, omittingEmptySubsequences: false)
    // The executable path, then however many NULs the kernel padded the alignment out with, then
    // the arguments. Empty fields are skipped rather than counted: the padding is a property of the
    // machine's word size, not of the process.
    var index = 1
    while index < fields.count, fields[index].isEmpty { index += 1 }
    index += Int(argc)
    guard index <= fields.count else { return nil }
    let prefix = Array("\(supervisorVersionEnvKey)=".utf8)
    for field in fields[index...] where field.starts(with: prefix) {
        // An empty value is not a version. A supervisor with nothing to stamp sets no variable at
        // all, so an empty one can only come from something else exporting the name, and reading it
        // as a build would put an empty badge on a card.
        let value = String(decoding: field.dropFirst(prefix.count), as: UTF8.self)
        return value.isEmpty ? nil : value
    }
    return nil
}
