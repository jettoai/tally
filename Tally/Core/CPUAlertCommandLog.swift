import Foundation

// THE COMMAND LINES BEHIND A CPU BANNER, kept in a file of their own so a banner that names a
// process can later be traced to who started it and with what (the banner itself prints names only).
//
// This is the one place the CPU watch writes ARGUMENTS to disk, which is why it is a separate file
// (`~/.tally/logs/cpu-alert-commands.log`, 0600, never uploaded or knocked on: the structural
// checks in tests/cpualert/main.swift pin that). Masking is a deny-list; its named blind spot is a
// short secret passed as a bare positional argument (`mysql -pabc123`), which no rule can tell from
// a port number. The 0600 mode and the no-upload rule carry that gap.
//
// FOUNDATION ONLY, so the harness compiles it: the sysctl that reads an argument vector is in
// CPUAlertCommandReaders.swift.

enum CPUAlertCommandMask {
    static let redacted = "<redacted>"

    /// A flag, variable or query name whose value is a secret.
    private static let sensitiveName = try! NSRegularExpression(
        pattern: "token|secret|key|pass(word|wd)?|auth|cookie|credential|aud|sig(nature)?|bearer",
        options: .caseInsensitive)
    private static let envAssignment = try! NSRegularExpression(pattern: "^[A-Za-z_][A-Za-z0-9_]*=")
    private static let userinfo = try! NSRegularExpression(pattern: "(://)[^/@\\s]*:[^/@\\s]*@")
    private static let queryParameter = try! NSRegularExpression(pattern: "([?&][^=&\\s]+)=[^&\\s]*")
    private static let tokenShape = try! NSRegularExpression(
        pattern: "sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9]{8,}|github_pat_[A-Za-z0-9_]{8,}"
            + "|xox[abpr]-[A-Za-z0-9-]{8,}|AKIA[0-9A-Z]{16}"
            + "|eyJ[A-Za-z0-9_-]+\\.eyJ[A-Za-z0-9_-]+(\\.[A-Za-z0-9_-]*)?")
    /// Inside one long argument (`zsh -c 'export TOKEN=x; curl --api-key y'`, which is how a coding
    /// agent starts almost every command), the same three shapes the per-argument rules catch.
    private static let embeddedValue = "(\"[^\"]*\"|'[^']*'|[^\\s\"';&|]+)"
    private static let embeddedAssignment = try! NSRegularExpression(
        pattern: "\\b([A-Za-z_][A-Za-z0-9_]*)=" + embeddedValue)
    private static let embeddedFlag = try! NSRegularExpression(
        pattern: "(\\s--?[A-Za-z][A-Za-z0-9_-]*)([= ])" + embeddedValue)
    private static let bearer = try! NSRegularExpression(
        pattern: "((?:bearer|authorization:?)\\s+(?:bearer\\s+)?)[^\\s\"';&|]+", options: .caseInsensitive)
    private static let longRun = try! NSRegularExpression(pattern: "[A-Za-z0-9+/_-]{32,}={0,2}")
    private static let uuid = try! NSRegularExpression(
        pattern: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")

    private static func whole(_ text: String) -> NSRange { NSRange(text.startIndex..., in: text) }
    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: whole(text)) != nil
    }
    private static func replaced(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: whole(text), withTemplate: template)
    }

    /// One argument vector as one log-safe line fragment. `arguments` must be the argument vector
    /// only (`arguments(procargs:)`), never the environment block that follows it in memory.
    static func mask(arguments: [String], home: String) -> String {
        var out: [String] = []
        var redactNext = false
        for raw in arguments {
            if redactNext {
                redactNext = false
                if !raw.hasPrefix("-") { out.append(redacted); continue }
            }
            var arg = home.isEmpty ? raw : raw.replacingOccurrences(of: home, with: "~")
            if arg.hasPrefix("-") {
                if let equals = arg.firstIndex(of: "=") {
                    if matches(sensitiveName, String(arg[..<equals])) {
                        out.append(String(arg[...equals]) + redacted)
                        continue
                    }
                } else if matches(sensitiveName, arg) {
                    redactNext = true
                    out.append(quoted(plain(arg)))
                    continue
                }
            } else if matches(envAssignment, arg), let equals = arg.firstIndex(of: "="),
                      matches(sensitiveName, String(arg[..<equals])) {
                out.append(String(arg[...equals]) + redacted)
                continue
            }
            if arg.contains(where: \.isWhitespace) { arg = redactEmbedded(arg) }
            arg = replaced(userinfo, in: arg, with: "$1" + redacted + "@")
            arg = redactQuery(arg)
            arg = replaced(tokenShape, in: arg, with: redacted)
            arg = redactLongRuns(arg)
            out.append(quoted(plain(arg)))
        }
        return out.joined(separator: " ")
    }

    private static func redactEmbedded(_ text: String) -> String {
        var result = text
        for (regex, nameGroup) in [(embeddedAssignment, 1), (embeddedFlag, 1)] {
            for match in regex.matches(in: result, range: whole(result)).reversed() {
                guard let name = Range(match.range(at: nameGroup), in: result),
                      matches(sensitiveName, String(result[name])),
                      let value = Range(match.range(at: regex === embeddedFlag ? 3 : 2), in: result) else { continue }
                result.replaceSubrange(value, with: redacted)
            }
        }
        return replaced(bearer, in: result, with: "$1" + redacted)
    }

    private static func redactQuery(_ text: String) -> String {
        var result = text
        for match in queryParameter.matches(in: text, range: whole(text)).reversed() {
            guard let range = Range(match.range(at: 1), in: result),
                  matches(sensitiveName, String(result[range])),
                  let full = Range(match.range, in: result) else { continue }
            result.replaceSubrange(full, with: String(result[range]) + "=" + redacted)
        }
        return result
    }

    /// A run of 32 or more key-alphabet characters holding both a letter and a digit is a secret
    /// whatever flag it follows (a 64-digit hex, a base64 key). A path (it has a `/`) and a UUID
    /// (a session id, which a reader needs to join on) are not.
    private static func redactLongRuns(_ text: String) -> String {
        var result = text
        for match in longRun.matches(in: text, range: whole(text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let run = String(result[range])
            let hasLetter = run.contains { $0.isLetter }
            let hasDigit = run.contains { $0.isNumber }
            guard hasLetter, hasDigit, !run.contains("/"), !matches(uuid, run) else { continue }
            result.replaceSubrange(range, with: "<redacted:\(run.utf8.count)>")
        }
        return result
    }

    /// Control characters out, so a record is one line; an argument with a space or no text
    /// is quoted so the line can be read back into arguments.
    private static func plain(_ text: String) -> String {
        keystrokeStripped(text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " "))
    }

    private static func quoted(_ text: String) -> String {
        text.isEmpty || text.contains(" ") ? "\"" + text.replacingOccurrences(of: "\"", with: "\\\"") + "\"" : text
    }

    /// The argument vector inside a `KERN_PROCARGS2` buffer: an argument count, the path the program
    /// ran from, alignment NULs, then exactly that many NUL-terminated arguments, and AFTER them the
    /// environment, which is where secrets live and which this never returns.
    static func arguments(procargs: Data) -> [String]? {
        let header = MemoryLayout<Int32>.size
        guard procargs.count > header else { return nil }
        let argc = procargs.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 0, as: Int32.self)) }
        guard argc >= 0 else { return nil }
        let fields = procargs.dropFirst(header).split(separator: 0, omittingEmptySubsequences: false)
        var index = 1
        while index < fields.count, fields[index].isEmpty { index += 1 }
        guard argc > 0, index + argc <= fields.count else { return argc == 0 ? [] : nil }
        return fields[index..<(index + argc)].map { String(decoding: $0, as: UTF8.self) }
    }

    /// The command a shell was asked to run (`zsh -c '<this>'`), nil when `arguments` is not one.
    static func shellCommand(in arguments: [String]) -> String? {
        let shells: Set<String> = ["zsh", "bash", "sh", "dash", "fish"]
        guard let program = arguments.first, shells.contains((program as NSString).lastPathComponent),
              let flag = arguments.firstIndex(where: {
                  $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.dropFirst().contains("c")
              }),
              let command = arguments[(flag + 1)...].firstIndex(where: { !$0.hasPrefix("-") })
        else { return nil }
        return arguments[command]
    }
}

struct CPUAlertCommandRecord: Equatable, Sendable {
    var rank: Int
    var pid: Int32
    /// Share of the machine, in the units of the banner's title.
    var share: Double
    var group: String
    var category: String
    var chain: String
    /// The nearest ancestor shell's `-c` command, masked.
    var origin: String?
    var argv: String
}

enum CPUAlertCommandLog {
    static let maxRecords = 5
    static let maxArgvBytes = 16 * 1024
    static let fileLimit = 2 * 1024 * 1024

    /// The `maxRecords` busiest processes with the group each is charged to, for the records.
    static func top(_ scan: CPUAlertScan, busy: Double, roots: Set<String>, home: String,
                    isCheckout: (String) -> Bool, displayName: (String) -> String?,
                    browsers: Set<String>) -> [(work: CPUAlertProcessWork, group: String, category: String, share: Double)] {
        let byPid = Dictionary(scan.processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let accounted = scan.processes.reduce(0) { $0 + $1.seconds }
        let denominator = max(scan.busySeconds, accounted)
        guard denominator > 0 else { return [] }
        let busiest = scan.processes.filter { $0.seconds > 0 }
            .sorted { $0.seconds == $1.seconds ? $0.pid < $1.pid : $0.seconds > $1.seconds }
            .prefix(maxRecords)
        return busiest.map { work in
            let (kind, name) = CPUAlertLogic.owner(of: work.pid, in: byPid, roots: roots, home: home,
                                                   isCheckout: isCheckout, displayName: displayName,
                                                   browsers: browsers)
            let category = CPUAlertCulprit(name: name, percent: 0, kind: kind,
                                           role: CPUAlertLogic.role(kind, work)).category
            return (work, name, category, work.seconds / denominator * busy)
        }
    }

    /// `pid:name<pid:name<...` from `pid` up to launchd, a Claude Code session root, or `limit`
    /// levels. A parent that cannot be named ends the chain as `pid:?`.
    static func chain(of pid: Int32, parent: (Int32) -> Int32?, name: (Int32) -> String?,
                      limit: Int = CPUAlertLogic.maxAncestors) -> String {
        var parts: [String] = []
        var cursor = pid
        var seen: Set<Int32> = []
        while parts.count < limit, seen.insert(cursor).inserted {
            guard let label = name(cursor) else { parts.append("\(cursor):?"); break }
            parts.append("\(cursor):\(keystrokeStripped(label))")
            guard cursor > 1, label != "claude", let up = parent(cursor), up > 0 else { break }
            cursor = up
        }
        return parts.joined(separator: "<")
    }

    /// `arguments` joined and masked, cut at `maxArgvBytes` with a marker that says how much went.
    static func argvField(_ arguments: [String], home: String) -> String {
        let text = CPUAlertCommandMask.mask(arguments: arguments, home: home)
        guard text.utf8.count > maxArgvBytes else { return text }
        let kept = keystrokeClipped(text, bytes: maxArgvBytes)
        return kept + "...(+\(text.utf8.count - kept.utf8.count) bytes)"
    }

    /// One header and a line per record, the header naming the same instant as `cpu-alert.log`'s
    /// line for this banner so the two join on it.
    static func block(_ event: CPUAlertEvent, busy: Double, cores: Int, records: [CPUAlertCommandRecord],
                      now: Date) -> String {
        let stamp = ISO8601DateFormatter().string(from: now)
        let kind = event == .handover ? "handover" : "alarm"
        var lines = ["\(stamp) cpu-alert-cmd=\(kind) cpu=\(Int(busy.rounded())) cores=\(cores) records=\(records.count)"]
        for record in records.prefix(maxRecords) {
            var line = "\(stamp) cpu-alert-cmd=proc rank=\(record.rank) pid=\(record.pid) "
                + "cpu=\(Int(record.share.rounded())) group=\(quotedField(record.group)) cat=\(record.category) "
                + "chain=\(record.chain)"
            if let origin = record.origin {
                line += " origin=\"" + origin.replacingOccurrences(of: "\"", with: "\\\"") + "\""
            }
            lines.append(line + " argv=" + record.argv)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func quotedField(_ text: String) -> String {
        let clean = keystrokeStripped(text)
        return clean.contains(" ") || clean.isEmpty ? "\"" + clean + "\"" : clean
    }

    /// Append `text`; a file that would pass `limit` is moved to `<name>.1` first (replacing the
    /// older one), so the disk holds two generations at most. Created 0600 and kept there: the
    /// default path (`Data.write`) creates it under the umask, which is 0644.
    static func append(_ text: String, to file: URL, limit: Int = fileLimit) {
        let fm = FileManager.default
        let data = Data(text.utf8)
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        if size > 0, size + data.count > limit {
            let older = URL(fileURLWithPath: file.path + ".1")
            try? fm.removeItem(at: older)
            try? fm.moveItem(at: file, to: older)
        }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            _ = fm.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

let cpuAlertCommandsFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/logs/cpu-alert-commands.log")
