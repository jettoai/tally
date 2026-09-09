import Darwin
import Foundation

struct HarnessProcessResult {
    let code: Int32
    let stdout: Data
    let stderr: Data
    let failure: String?
}

/// Drain all three pipes together, with a deadline and a private child process group.
/// Hook payloads and output stay in memory rather than temporary transcript files.
enum HarnessProcess {
    static func run(executable: String, arguments: [String], input: Data, cwd: String,
                    environment: [String: String], timeout: Double) throws -> HarnessProcessResult {
        var descriptors: [[Int32]] = []
        defer { for pair in descriptors { for fd in pair where fd >= 0 { Darwin.close(fd) } } }
        for _ in 0..<3 {
            var pair: [Int32] = [0, 0]
            guard Darwin.pipe(&pair) == 0 else { throw HarnessError("Cannot create hook pipes.") }
            descriptors.append(pair)
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0 else { throw HarnessError("Cannot prepare a hook process.") }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        let chdirResult: Int32
        if #available(macOS 26.0, *) { chdirResult = posix_spawn_file_actions_addchdir(&actions, cwd) }
        else { chdirResult = posix_spawn_file_actions_addchdir_np(&actions, cwd) }
        guard posix_spawn_file_actions_adddup2(&actions, descriptors[0][0], STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, descriptors[1][1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, descriptors[2][1], STDERR_FILENO) == 0,
              chdirResult == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            throw HarnessError("Cannot isolate the hook process group.")
        }
        for pair in descriptors {
            for fd in pair { guard posix_spawn_file_actions_addclose(&actions, fd) == 0 else {
                throw HarnessError("Cannot configure hook pipe ownership.")
            } }
        }
        var argv = ([executable] + arguments).map { strdup($0) } + [nil]
        var env = environment.sorted(by: { $0.key < $1.key }).map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var pid: pid_t = 0
        let spawn = argv.withUnsafeMutableBufferPointer { a in
            env.withUnsafeMutableBufferPointer { e in
                posix_spawn(&pid, executable, &actions, &attributes, a.baseAddress!, e.baseAddress!)
            }
        }
        guard spawn == 0 else { throw HarnessError("Hook process could not start (\(spawn)).") }
        for (i, j) in [(0, 0), (1, 1), (2, 1)] { Darwin.close(descriptors[i][j]); descriptors[i][j] = -1 }
        let fds = [descriptors[0][1], descriptors[1][0], descriptors[2][0]]
        for fd in fds { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        _ = fcntl(fds[0], F_SETNOSIGPIPE, 1)
        var polling = [pollfd(fd: fds[0], events: Int16(POLLOUT), revents: 0),
                       pollfd(fd: fds[1], events: Int16(POLLIN), revents: 0),
                       pollfd(fd: fds[2], events: Int16(POLLIN), revents: 0)]
        var offset = 0, output = Data(), errors = Data(), status: Int32 = 0
        var exited = false, failure: String?, exitTime: TimeInterval?
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let limit = 1_048_576
        func closeInput() {
            if descriptors[0][1] >= 0 { Darwin.close(descriptors[0][1]); descriptors[0][1] = -1 }
            polling[0].fd = -1
        }
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if !exited && waitpid(pid, &status, WNOHANG) == pid { exited = true; exitTime = now; closeInput() }
            if now >= deadline { failure = "Hook exceeded its deadline."; break }
            if exited && polling[1].fd < 0 && polling[2].fd < 0 { break }
            if let exitTime, now - exitTime > 1 { failure = "Hook left output pipes open."; break }
            if offset == input.count { closeInput() }
            if poll(&polling, nfds_t(polling.count), 20) < 0 && errno != EINTR {
                failure = "Hook pipe polling failed."; break
            }
            if polling[0].fd >= 0 && polling[0].revents & Int16(POLLOUT) != 0 {
                let count = input.withUnsafeBytes { bytes in
                    Darwin.write(fds[0], bytes.baseAddress!.advanced(by: offset), input.count - offset)
                }
                if count > 0 { offset += count }
                else if count < 0 && ![EAGAIN, EINTR].contains(errno) { closeInput() }
            }
            for index in 1...2 where polling[index].fd >= 0 {
                if polling[index].revents & Int16(POLLIN | POLLHUP | POLLERR) == 0 { continue }
                var buffer = [UInt8](repeating: 0, count: 16_384)
                let count = Darwin.read(fds[index], &buffer, buffer.count)
                if count > 0 {
                    if index == 1 { output.append(contentsOf: buffer.prefix(count)) }
                    else { errors.append(contentsOf: buffer.prefix(count)) }
                    if output.count + errors.count > limit { failure = "Hook output exceeded the size limit." }
                } else if count == 0 || (count < 0 && ![EAGAIN, EINTR].contains(errno)) {
                    polling[index].fd = -1
                }
            }
            if failure != nil { break }
        }
        if failure != nil { _ = kill(-pid, SIGKILL) }
        if !exited {
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        }
        let code = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return HarnessProcessResult(code: code, stdout: output, stderr: errors, failure: failure)
    }
}
