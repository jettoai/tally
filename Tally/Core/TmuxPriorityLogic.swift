import Foundation

/// The rules of the tmux priority guard (B-4266), pure so a harness can state them with no machine
/// under them. The syscalls are in TmuxPriorityReaders.swift and the watch that tells is
/// TmuxPriorityMonitor.swift.
///
/// WHY THIS IS WATCHED AT ALL. A tmux server started from a launchd background job (no
/// `ProcessType`) is born at priority 20 instead of the 31 of an ordinary shell, and every window
/// it opens inherits that. On Apple silicon such processes are scheduled onto the efficiency
/// cores: on 2026-11-09 a server at 20 held 41 sessions with four efficiency cores at 100% and
/// twelve performance cores at 18 to 37%, and nothing in Tally said so. The priority of a running
/// process cannot be raised, so the only remedy is a restart of tmux, which is the user's call.
enum TmuxPriorityLogic {
    /// The priority an ordinary foreground shell and its children run at. Below it the server was
    /// started in the background class.
    static let normalPriority = 31

    /// One sample a minute by the clock, the rate of the host-health watch next door.
    static let sampleInterval: TimeInterval = 60

    /// Whether a priority reading is below normal. A reading that could not be taken is not "low":
    /// a guard that cannot see says nothing.
    static func isLow(_ priority: Int?) -> Bool {
        guard let priority else { return false }
        return priority < normalPriority
    }

    /// Whether to warn about one server. Both halves are needed: a low-priority tmux holding only
    /// the user's own shells is nobody's incident, and the agents are what the slow cores hurt.
    static func shouldWarn(priority: Int?, hasAgent: Bool) -> Bool {
        isLow(priority) && hasAgent
    }

    /// Whether an executable path is Claude Code or Codex. The last component names the program,
    /// except when it is a version number: Claude Code has installed itself as
    /// `~/.local/share/claude/versions/2.1.233`, so the walk continues up through the installer's
    /// container words (the rule `ProcessTree.displayName(forPath:)` applies).
    static func isAgentPath(_ path: String) -> Bool {
        var parts = path.split(separator: "/").map(String.init)
        guard var name = parts.popLast() else { return false }
        while isVersionNumber(name) || ["versions", "bin"].contains(name.lowercased()) {
            guard let next = parts.popLast() else { return false }
            name = next
        }
        return ["claude", "codex"].contains(name.lowercased())
    }

    private static func isVersionNumber(_ name: String) -> Bool {
        var digits = Substring(name)
        if digits.hasPrefix("v") { digits = digits.dropFirst() }
        return digits.contains(where: \.isNumber) && digits.allSatisfy { $0.isNumber || $0 == "." }
    }

    /// Every descendant of `root` given each pid's parent, breadth first. A cycle (a recycled pid
    /// that points back up) ends the walk instead of looping.
    static func descendants(of root: pid_t, parents: [pid_t: pid_t]) -> [pid_t] {
        var children: [pid_t: [pid_t]] = [:]
        for (pid, parent) in parents where pid != parent { children[parent, default: []].append(pid) }
        var seen: Set<pid_t> = [root]
        var order: [pid_t] = []
        var queue = [root]
        while !queue.isEmpty {
            let next = queue.removeFirst()
            for child in (children[next] ?? []).sorted() where seen.insert(child).inserted {
                order.append(child)
                queue.append(child)
            }
        }
        return order
    }
}

/// One tmux server as the reader saw it: its pid, its priority (nil when the kernel would not say)
/// and whether any Claude Code or Codex process runs under it.
struct TmuxServerReading: Equatable {
    var pid: pid_t
    var priority: Int?
    var hasAgent: Bool
}

/// Which servers have been told to the user. A server is announced once for as long as it stays
/// alive and low, and a new pid is judged afresh, so the restart that fixes it re-arms the guard.
///
/// A server that stays low but loses its agents for a minute keeps its entry: announcing it again
/// when an agent returns would be the same news twice.
struct TmuxPriorityTracker: Equatable {
    private(set) var announced: Set<pid_t> = []

    /// Fold one scan in and answer the servers to announce now.
    mutating func fold(_ readings: [TmuxServerReading]) -> [TmuxServerReading] {
        announced = announced.intersection(readings.filter { TmuxPriorityLogic.isLow($0.priority) }.map(\.pid))
        var fresh: [TmuxServerReading] = []
        for reading in readings.sorted(by: { $0.pid < $1.pid })
        where TmuxPriorityLogic.shouldWarn(priority: reading.priority, hasAgent: reading.hasAgent)
            && !announced.contains(reading.pid) {
            announced.insert(reading.pid)
            fresh.append(reading)
        }
        return fresh
    }
}

/// The banner's title. `localized` is the app's `L`, handed in so this stays pure.
func tmuxPriorityAlertTitle(localized: (String) -> String) -> String {
    localized("tmux is running at low priority")
}

/// The banner's body: what is wrong, why it matters, and the one thing that fixes it. Tally does
/// not restart tmux itself, because every window under it holds work.
func tmuxPriorityAlertBody(priority: Int, localized: (String) -> String) -> String {
    String(format: localized("tmux runs at priority %@ (normal is 31), so the Claude and Codex sessions under it are scheduled onto the slow cores. Restarting tmux restores it. Save your work before you restart."),
           String(priority))
}

/// One line for `~/.tally/logs/host-health.log`, in the `key=value` shape of its neighbours.
func tmuxPriorityLogLine(_ reading: TmuxServerReading, now: Date = Date()) -> String {
    "\(ISO8601DateFormatter().string(from: now)) tmux-low-priority pid=\(reading.pid) "
        + "priority=\(reading.priority.map(String.init) ?? "unknown") normal=\(TmuxPriorityLogic.normalPriority)\n"
}
