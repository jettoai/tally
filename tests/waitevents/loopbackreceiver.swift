import Foundation

/// A webhook sink on 127.0.0.1 for the delivery tests: a real listener the real
/// `defaultEventSender` posts to, so a test exercises the whole send path rather than an injected
/// closure. Every request is logged (arrival order, `X-Tally-Event`, the body's `seq`, arrival time)
/// to `logFile`, which is left on disk for the report to cite.
///
/// `onRequest(n)` runs on the accept thread before request `n` (1-based) is answered, so a test can
/// hold a reply (block the deliverer inside its send) or append to the spool mid-pass.
final class LoopbackReceiver: @unchecked Sendable {
    let port: UInt16
    let logFile: URL
    private let fd: Int32
    private let lock = NSLock()
    private var entries: [(event: String, seq: Int)] = []
    private var captured: [(headers: [String: String], body: Data)] = []
    private let onRequest: (Int) -> Void
    private let status: (Int) -> Int

    /// `status(n)` is the HTTP status request `n` is answered with; header names in `requests` are
    /// lowercased.
    init(logFile: URL, onRequest: @escaping (Int) -> Void = { _ in },
         status: @escaping (Int) -> Int = { _ in 200 }) {
        self.logFile = logFile
        self.onRequest = onRequest
        self.status = status
        try? Data().write(to: logFile)
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        listen(listener, 16)
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        fd = listener
        port = UInt16(bigEndian: bound.sin_port)
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    var url: String { "http://127.0.0.1:\(port)/hook" }

    var received: [(event: String, seq: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    var requests: [(headers: [String: String], body: Data)] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    private func acceptLoop() {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { return }
            handle(client)
        }
    }

    private func handle(_ client: Int32) {
        // A reply held past the sender's timeout is written to a socket the sender already closed;
        // without this that write raises SIGPIPE and kills the whole test process.
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(client, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
            guard let text = String(data: data, encoding: .utf8),
                  let split = text.range(of: "\r\n\r\n") else { continue }
            var headers: [String: String] = [:]
            for line in text[..<split.lowerBound].components(separatedBy: "\r\n").dropFirst() {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
            }
            let length = headers["content-length"].flatMap { Int($0) } ?? 0
            let body = String(text[split.upperBound...])
            if body.utf8.count < length { continue }
            let event = headers["x-tally-event"] ?? "?"
            let seq = (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])?["seq"] as? Int ?? -1
            lock.lock()
            entries.append((event, seq))
            captured.append((headers, Data(body.utf8)))
            let number = entries.count
            lock.unlock()
            let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                    formatOptions: [.withInternetDateTime, .withFractionalSeconds])
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(Data("\(number)\t\(event)\tseq=\(seq)\t\(stamp)\n".utf8))
                try? handle.close()
            }
            onRequest(number)
            let reply = "HTTP/1.1 \(status(number)) X\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            _ = reply.withCString { write(client, $0, strlen($0)) }
            break
        }
        close(client)
    }
}
