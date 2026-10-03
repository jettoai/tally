// Stands in for the Swift CLI at Contents/Helpers/swift/tally (tests/run-entry-tests.sh): reports
// the process it was started as, so the suite can compare it with the one the launcher built
// before it exec'd the Rust entry. One `key=value` line each on stdout.
import Darwin
import Foundation

func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
}

var argvBytes: [UInt8] = []
for index in 0..<Int(CommandLine.argc) {
    if index > 0 { argvBytes.append(0) }
    if let arg = CommandLine.unsafeArgv[index] {
        argvBytes.append(contentsOf: UnsafeBufferPointer(start: UnsafeRawPointer(arg)
            .assumingMemoryBound(to: UInt8.self), count: strlen(arg)))
    }
}

var pipeAction = sigaction()
sigaction(SIGPIPE, nil, &pipeAction)
let pipeHandler = unsafeBitCast(pipeAction.__sigaction_u.__sa_handler, to: Int.self)
var mask = sigset_t()
sigprocmask(SIG_BLOCK, nil, &mask)
let stdinBytes = FileHandle.standardInput.readDataToEndOfFile()
let env = ProcessInfo.processInfo.environment

print("argv=\(hex(argvBytes))")
print("pid=\(getpid())")
print("cwd=\(FileManager.default.currentDirectoryPath)")
print("env=\(env["TALLY_ENTRY_PROBE"] ?? "<unset>")")
print("sigpipe=\(pipeHandler == 1 ? "ign" : pipeHandler == 0 ? "dfl" : "other")")
print("usr1blocked=\((mask & (1 << (SIGUSR1 - 1))) != 0)")
print("fd3=\(fcntl(3, F_GETFD) != -1)")
print("stdin=\(hex(stdinBytes))")
FileHandle.standardError.write("probe-stderr\n".data(using: .utf8)!)
exit(Int32(env["TALLY_ENTRY_PROBE_EXIT"] ?? "0") ?? 0)
