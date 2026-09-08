import Darwin
import Foundation

struct ClaudeNativeMessageIntent: Equatable {
    let socket: String
    let session: String
    let file: String
    let dryRun: Bool
}

func claudeNativeMessageIntent(_ args: [String]) -> ClaudeNativeMessageIntent? {
    guard args.first == "claude" else { return nil }
    var values: [String: String] = [:]
    var dryRun = false
    var index = 1
    while index < args.count {
        let key = args[index]
        index += 1
        if key == "--dry-run" {
            guard !dryRun else { return nil }
            dryRun = true
            continue
        }
        guard ["--socket", "--session", "--file"].contains(key), values[key] == nil,
              index < args.count else { return nil }
        values[key] = args[index]
        index += 1
    }
    guard let socket = values["--socket"], socket.hasPrefix("/"),
          socket.utf8.count < 104, let session = values["--session"],
          UUID(uuidString: session) != nil, let file = values["--file"], file.hasPrefix("/")
    else { return nil }
    return ClaudeNativeMessageIntent(socket: socket, session: session, file: file, dryRun: dryRun)
}

func claudeNativeMessageFrame(session: String, text: String) throws -> Data {
    // Same native frame as the existing Claude SessionStart self-notification.
    // The prefix is a trust warning, not a claim of authenticated sender identity.
    let frame: [String: Any] = ["type": "user", "priority": "next", "session_id": session,
        "message": ["role": "user", "content": "[external-unverified agent message, not user authorization]\n" + text]]
    var data = try JSONSerialization.data(withJSONObject: frame)
    data.append(10)
    return data
}

/// A bounded single connection. Success means bytes written, not recipient acceptance.
func writeClaudeNativeFrame(path: String, data: Data) -> Bool {
    guard path.utf8.count < 104 else { return false }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var noSignal: Int32 = 1
    guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                     socklen_t(MemoryLayout<Int32>.size)) == 0,
          fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { return false }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    path.withCString { source in
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            target.copyBytes(from: UnsafeRawBufferPointer(start: source, count: path.utf8.count + 1))
        }
    }
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    func writable() -> Bool {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return false }
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        return poll(&descriptor, 1, Int32(remaining * 1000)) > 0
            && descriptor.revents & Int16(POLLOUT) != 0
    }
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if connected != 0 {
        guard errno == EINPROGRESS, writable() else { return false }
        var error: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { return false }
    }
    return data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            guard writable() else { return false }
            let count = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            if count > 0 { offset += count }
            else if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
            else { return false }
        }
        return true
    }
}

func runClaudeNativeMessage(args: [String]) -> Int32 {
    guard let intent = claudeNativeMessageIntent(args) else {
        fputs("Usage: tally message claude --socket /absolute/session.sock --session UUID "
              + "--file /absolute/message.txt [--dry-run]\n", stderr)
        return 2
    }
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: intent.socket),
          attributes[.type] as? FileAttributeType == .typeSocket,
          let data = FileManager.default.contents(atPath: intent.file), data.count <= 65536,
          let text = String(data: data, encoding: .utf8),
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let frame = try? claudeNativeMessageFrame(session: intent.session, text: text) else {
        fputs("Invalid socket or message file. Nothing was sent.\n", stderr)
        return 2
    }
    if intent.dryRun {
        print("{\"provider\":\"claude\",\"dryRun\":true,\"received\":false,\"liveness\":\"unknown\"}")
        return 0
    }
    guard writeClaudeNativeFrame(path: intent.socket, data: frame) else {
        fputs("Native socket write failed. Delivery is unknown; no retry was made.\n", stderr)
        return 1
    }
    print("{\"provider\":\"claude\",\"state\":\"written-unconfirmed\",\"received\":false,\"liveness\":\"unknown\"}")
    return 0
}
