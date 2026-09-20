import Darwin
import Foundation

/// Provider capabilities and process generations, shared by the CLI and the panel.
/// The presence marker is written last and remains fail-closed if metadata is damaged.
struct SessionMonitoring: Codable, Equatable {
    var provider: String
    var supervisorPID: Int32
    var supervisorStart: Int64
    var childPID: Int32?
    var childStart: Int64?
    /// The private terminal owned by the monitored Codex child, published only after the runtime has
    /// proved it is still safe to write through. Older monitoring registrations omit it and remain
    /// monitoring-only.
    var inputTTY: String? = nil
    var nonce: String
    var home: String

    static let suffix = ".monitoring"
    static let presencePrefix = "monitoring:"

    static func generation(_ pid: Int32) -> Int64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int64(info.pbi_start_tvsec) * 1_000_000 + Int64(info.pbi_start_tvusec)
    }

    var isLive: Bool {
        Self.generation(supervisorPID) == supervisorStart
            && (childPID == nil || childPID.flatMap(Self.generation) == childStart)
    }

    func write(dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(
            to: dir.appendingPathComponent(String(supervisorPID) + Self.suffix), options: .atomic)
    }

    static func read(pid: String, dir: URL) -> Self? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(pid + suffix)),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              String(value.supervisorPID) == pid, value.isLive else { return nil }
        return value
    }

    static func isMarked(pid: String, dir: URL) -> Bool {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(pid + suffix).path) {
            return true
        }
        let presence = try? String(contentsOf: dir.appendingPathComponent(pid), encoding: .utf8)
        if presence?.hasPrefix(presencePrefix) == true { return true }
        let account = try? String(contentsOf: dir.appendingPathComponent(pid + ".account"), encoding: .utf8)
        return account?.hasPrefix("codex:") == true
    }

    static func presenceIsLive(pid: String, dir: URL) -> Bool {
        guard isMarked(pid: pid, dir: dir) else { return true }
        guard let value = read(pid: pid, dir: dir),
              let presence = try? String(contentsOf: dir.appendingPathComponent(pid), encoding: .utf8)
        else { return false }
        return presence == presencePrefix + String(value.supervisorStart)
    }

    /// Includes damaged registrations so the legacy probe cannot relabel them as Claude.
    static func markedPids(dir: URL) -> Set<Int32> {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let candidates = Set(files.compactMap { $0.split(separator: ".").first.flatMap { Int32($0) } })
        return Set(candidates.filter { isMarked(pid: String($0), dir: dir) })
    }

    static func staleGeneration(pid: String, dir: URL) -> Bool {
        guard let process = Int32(pid), let current = generation(process) else { return false }
        // Presence is the final publication. Damaged metadata cannot revoke its live owner.
        if let presence = try? String(contentsOf: dir.appendingPathComponent(pid), encoding: .utf8),
           presence.hasPrefix(presencePrefix),
           let recorded = Int64(presence.dropFirst(presencePrefix.count)) {
            return recorded != current
        }
        if let data = try? Data(contentsOf: dir.appendingPathComponent(pid + suffix)),
           let value = try? JSONDecoder().decode(Self.self, from: data) {
            return value.supervisorPID == process && value.supervisorStart != current
        }
        return false
    }

    /// Whether a monitored Codex registration can accept a line at its own terminal.
    ///
    /// This is intentionally narrower than `isLive`: a legacy monitoring record can still prove
    /// that its process exists, but has no verified terminal address to receive a direct prompt.
    /// The runtime owns the stronger terminal checks at delivery time. This guard only permits the
    /// capability to be advertised after that runtime has published a bounded `/dev/...` address.
    static func supportsDirectSend(pid: String, dir: URL) -> Bool {
        guard let identity = read(pid: pid, dir: dir), identity.provider == "codex",
              presenceIsLive(pid: pid, dir: dir), identity.childPID != nil,
              identity.childStart != nil,
              validInputTTY(identity.inputTTY) else { return false }
        return true
    }

    private static func validInputTTY(_ path: String?) -> Bool {
        guard let path, path.hasPrefix("/dev/"), path.count > "/dev/".count else { return false }
        return !path.unicodeScalars.contains { $0.value == 0 || $0.value == 10 || $0.value == 13 }
    }
}

func sessionControlRefusal(pid: String, dir: URL) -> String? {
    guard SessionMonitoring.isMarked(pid: pid, dir: dir) else { return nil }
    if SessionMonitoring.supportsDirectSend(pid: pid, dir: dir) {
        return "This Codex session supports monitoring and direct input, not account, model, clear, or reload controls. Restart with the desired launch settings. Nothing was queued."
    }
    return "This session supports monitoring only. Restart it to change its account, model, or supervisor version. Nothing was queued."
}

/// The one control a current Codex supervisor may advertise. Account, model, clear and reload keep
/// their existing monitoring-only refusal; this check is used solely by `tally session send`.
func sessionSendRefusal(pid: String, dir: URL) -> String? {
    guard SessionMonitoring.isMarked(pid: pid, dir: dir) else { return nil }
    guard SessionMonitoring.supportsDirectSend(pid: pid, dir: dir) else {
        return "This Codex session cannot accept direct input because it has no verified terminal "
            + "target and native turn lifecycle. Trust the installed session hooks, then restart with the current `tally codex resume <thread-id>`. A supervised exact-thread resume without a prompt initializes with one native turn; wait for it to finish. Nothing was queued."
    }
    return nil
}

/// The status contract is capability-specific. A live Codex registration may receive a direct
/// prompt, but it must never inherit Claude's account, model, clear, or reload controls.
func sessionSupportedActions(pid: String, dir: URL) -> [String] {
    guard SessionMonitoring.isMarked(pid: pid, dir: dir) else {
        return ["account", "model", "send", "clear", "reload"]
    }
    return SessionMonitoring.supportsDirectSend(pid: pid, dir: dir) ? ["send"] : []
}
