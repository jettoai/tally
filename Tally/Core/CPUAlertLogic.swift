import Foundation

// WHETHER THE MACHINE'S CPU HAS BEEN FULL FOR LONG ENOUGH TO SAY SO, and which project is behind it.
//
// A SECOND QUESTION BESIDE THE HOST WATCH, not a replacement for it (HostHealthLogic.swift). That
// watch asks whether the machine is starving (load at three times the core count, or under 2 GB
// free) and names memory holders by executable. This one asks what a person with a dev server and
// a build running actually wants to know: the CPU has been pinned for half a minute, whose work is
// it? The answer comes from the per-project rollup the session board already keeps
// (`MachineLoadRollup`), so it names a checkout rather than `node`.
//
// PURE, on the split this repository makes everywhere it takes a reading: the syscalls are in
// CPUAlertReaders.swift and the banner and the log are in CPUAlertMonitor.swift.

/// Cumulative CPU ticks across every core, as `HOST_CPU_LOAD_INFO` hands them over.
struct CPUTicks: Equatable, Sendable {
    var user: UInt64
    var system: UInt64
    var idle: UInt64
    var nice: UInt64
}

/// One name on the banner and its share of the whole machine, 0 to 100.
struct CPUAlertCulprit: Equatable, Sendable {
    var name: String
    var percent: Double
}

/// One project as the rollup reads it, reduced to what this file needs. A plain value rather than
/// `ProjectLoad`, so the harness can compile this file without the rollup and its Darwin readers.
struct CPUAlertProjectInput: Equatable, Sendable {
    var name: String
    /// Share of ONE core, the unit `ProjectLoad.cpuPercent` is in; nil when not yet read twice.
    var oneCorePercent: Double?
}

enum CPUAlertPhase: String, Equatable, Sendable {
    case normal
    case alarmed
}

/// Why a crossing was not announced, for the log.
enum CPUAlertSilence: String, Equatable, Sendable {
    case host
    case cooldown
}

enum CPUAlertEvent: Equatable, Sendable {
    /// Crossed into alarm. `silence` is nil when the banner goes out.
    case alarm(silence: CPUAlertSilence?)
    /// Still in alarm, and the leading project changed and held long enough to be news.
    case handover
    /// Back under the exit line for long enough. Logged, never announced.
    case clear
}

struct CPUAlertTracker: Equatable, Sendable {
    var phase: CPUAlertPhase = .normal
    var lastTicks: CPUTicks?
    var lastSampleAt: Date?
    /// Start of the first window in the current run over the entry line (normal) or under the exit
    /// line (alarmed). The start of the WINDOW, i.e. the previous sample's instant, so three
    /// ten-second windows over the line read as thirty seconds rather than twenty.
    var runSince: Date?
    /// When the alarm began, for the banner's duration.
    var alarmSince: Date?
    var lastBannerAt: Date?
    /// The leader named by the last banner that went out.
    var announcedLeader: String?
    /// A leader different from `announcedLeader`, and since when it has held.
    var candidateLeader: String?
    var candidateSince: Date?
}

enum CPUAlertLogic {
    static let enterPercent = 90.0
    static let exitPercent = 75.0
    static let sustain: TimeInterval = 30
    static let clearAfter: TimeInterval = 60
    /// Throttle, by the clock: the footprint timer ticks every 2 s with the board up and every 10 s
    /// behind it, and both must deliver the same watch.
    static let sampleInterval: TimeInterval = 10
    /// A gap longer than this is a machine that slept or a sampler that did not get a turn; the
    /// reading across it is an average over the gap and is dropped.
    static let maxGap: TimeInterval = 25
    static let cooldown: TimeInterval = 600
    /// How recent a host-pressure alarm silences this one.
    static let hostQuiet: TimeInterval = 120
    /// A project below this share of the machine is not named.
    static let minimumShare = 5.0
    /// A project must hold this share to be the leader a handover is decided on.
    static let leaderShare = 10.0
    /// The projects must explain at least this fraction of the busy figure, or the process table is
    /// scanned for the rest.
    static let explainedFraction = 0.6
    static let maxNames = 3

    /// The Settings switch (`SettingsStore.cpuAlertEnabled` writes it). Read here as well so the
    /// monitor needs no store behind it; on unless somebody turned it off.
    static let enabledKey = "cpuAlertEnabled"
    static func isEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Busy share of the whole machine between two readings, 0 to 100, or nil when the pair cannot
    /// say (no ticks elapsed, or a counter went backwards).
    static func busyPercent(from old: CPUTicks, to new: CPUTicks) -> Double? {
        guard new.user >= old.user, new.system >= old.system,
              new.idle >= old.idle, new.nice >= old.nice else { return nil }
        let busy = Double((new.user - old.user) + (new.system - old.system) + (new.nice - old.nice))
        let total = busy + Double(new.idle - old.idle)
        guard total > 0 else { return nil }
        return busy / total * 100
    }

    private static func ranked(_ culprits: [CPUAlertCulprit]) -> [CPUAlertCulprit] {
        culprits.sorted { $0.percent == $1.percent ? $0.name < $1.name : $0.percent > $1.percent }
    }

    /// The rollup's projects as shares of the whole machine, named ones only, largest first.
    static func projectCulprits(_ projects: [CPUAlertProjectInput], cores: Int) -> [CPUAlertCulprit] {
        guard cores > 0 else { return [] }
        return ranked(projects.compactMap { project in
            project.oneCorePercent.map {
                CPUAlertCulprit(name: project.name, percent: $0 / Double(cores))
            }
        }.filter { $0.percent >= minimumShare })
    }

    /// The leading project a handover is decided on, or nil when no project holds `leaderShare`.
    static func leader(_ culprits: [CPUAlertCulprit]) -> String? {
        culprits.first.flatMap { $0.percent >= leaderShare ? $0.name : nil }
    }

    /// Whether the projects leave too much of the busy figure unexplained.
    static func needsProcessScan(_ culprits: [CPUAlertCulprit], busy: Double) -> Bool {
        culprits.reduce(0) { $0 + $1.percent } < busy * explainedFraction
    }

    /// Projects and unattributed processes merged into what the banner names.
    static func named(projects: [CPUAlertCulprit], others: [CPUAlertCulprit]) -> [CPUAlertCulprit] {
        Array(ranked(projects + others.filter { $0.percent >= minimumShare }).prefix(maxNames))
    }

    private static func hostRecent(_ alarmed: Bool, _ at: Date?, now: Date) -> Bool {
        alarmed || (at.map { now.timeIntervalSince($0) < hostQuiet } ?? false)
    }

    /// Fold one reading in. `leader` is this sample's leading project; `hostAlarmAt` is when the
    /// host watch last raised an alarm (nil when it never has), and `hostAlarmed` whether it is in
    /// alarm right now.
    static func advance(_ tracker: CPUAlertTracker, ticks: CPUTicks, leader: String?,
                        hostAlarmed: Bool, hostAlarmAt: Date?,
                        at now: Date) -> (CPUAlertTracker, CPUAlertEvent?) {
        var next = tracker
        next.lastTicks = ticks
        next.lastSampleAt = now
        guard let old = tracker.lastTicks, let windowStart = tracker.lastSampleAt,
              now.timeIntervalSince(windowStart) <= maxGap,
              let busy = busyPercent(from: old, to: ticks) else {
            // An unread stretch breaks any run, the handover candidate's included.
            next.runSince = nil
            next.candidateLeader = nil
            next.candidateSince = nil
            return (next, nil)
        }
        switch tracker.phase {
        case .normal:
            guard busy >= enterPercent else { next.runSince = nil; return (next, nil) }
            let since = next.runSince ?? windowStart
            next.runSince = since
            guard now.timeIntervalSince(since) >= sustain else { return (next, nil) }
            next.phase = .alarmed
            next.alarmSince = since
            next.runSince = nil
            next.candidateLeader = nil
            next.candidateSince = nil
            let cooling = (tracker.lastBannerAt.map { now.timeIntervalSince($0) < cooldown } ?? false)
                && leader == tracker.announcedLeader
            let silence: CPUAlertSilence?
            if hostRecent(hostAlarmed, hostAlarmAt, now: now) {
                silence = .host
            } else if cooling {
                silence = .cooldown
            } else {
                silence = nil
            }
            if silence == nil {
                next.lastBannerAt = now
                next.announcedLeader = leader
            }
            return (next, .alarm(silence: silence))
        case .alarmed:
            if busy < exitPercent {
                // A cool window is not the new leader holding a hot CPU.
                next.candidateLeader = nil
                next.candidateSince = nil
                let since = next.runSince ?? windowStart
                next.runSince = since
                guard now.timeIntervalSince(since) >= clearAfter else { return (next, nil) }
                next.phase = .normal
                next.runSince = nil
                next.alarmSince = nil
                next.candidateLeader = nil
                next.candidateSince = nil
                return (next, .clear)
            }
            next.runSince = nil
            // Handover: a different leader, held for `sustain`, past the cooldown.
            guard let leader, leader != tracker.announcedLeader else {
                next.candidateLeader = nil
                next.candidateSince = nil
                return (next, nil)
            }
            if next.candidateLeader != leader {
                next.candidateLeader = leader
                next.candidateSince = windowStart
            }
            let held = next.candidateSince.map { now.timeIntervalSince($0) >= sustain } ?? false
            let cooled = tracker.lastBannerAt.map { now.timeIntervalSince($0) >= cooldown } ?? true
            guard held, cooled, !hostRecent(hostAlarmed, hostAlarmAt, now: now) else {
                return (next, nil)
            }
            next.lastBannerAt = now
            next.announcedLeader = leader
            next.candidateLeader = nil
            next.candidateSince = nil
            return (next, .handover)
        }
    }

    /// The busy figure of the reading `advance` is about to fold, for the banner.
    static func lastBusy(_ before: CPUAlertTracker, _ ticks: CPUTicks) -> Double? {
        before.lastTicks.flatMap { busyPercent(from: $0, to: ticks) }
    }

    /// Seconds the alarm has held, rounded to ten and never under `sustain`, for the banner.
    static func heldSeconds(since: Date?, now: Date) -> Int {
        guard let since else { return Int(sustain) }
        let rounded = Int((now.timeIntervalSince(since) / 10).rounded()) * 10
        return max(Int(sustain), rounded)
    }

    /// The names as one phrase: `bigdata 61%, tally 12%`. Names are repaired through the one rule
    /// this repository has for text that may hold a newline or an ESC (KeystrokeText.swift), and a
    /// name that strips to nothing is left out. Nil when nothing is left, which the caller spells
    /// as "unknown".
    static func phrase(_ culprits: [CPUAlertCulprit], separator: String) -> String? {
        let parts = culprits.compactMap { culprit -> String? in
            let name = keystrokeStripped(culprit.name)
            return name.isEmpty ? nil : "\(name) \(Int(culprit.percent.rounded()))%"
        }
        return parts.isEmpty ? nil : parts.joined(separator: separator)
    }

    /// The banner's names, largest first, cleaned the way `phrase` is (control characters stripped,
    /// an emptied name left out) and paired with the leader's own test (`leaderShare`): `share`
    /// carries every name's own rounded percent when the leading culprit clears it, or every share
    /// reads nil when nobody does, which the caller reads as "no single cause" rather than pointing
    /// at a project a reader would ask "why does 9% count" about.
    static func namedShares(_ culprits: [CPUAlertCulprit]) -> [(name: String, share: Int?)] {
        let leading = culprits.first.map { $0.percent >= leaderShare } ?? false
        return culprits.compactMap { culprit -> (name: String, share: Int?)? in
            let name = keystrokeStripped(culprit.name)
            guard !name.isEmpty else { return nil }
            return (name, leading ? Int(culprit.percent.rounded()) : nil)
        }
    }

    /// One line for `~/.tally/logs/cpu-alert.log`: ISO instant, fixed `key=value` fields, the names
    /// last. Names only, never arguments.
    static func logLine(_ event: CPUAlertEvent, busy: Double, cores: Int,
                        culprits: [CPUAlertCulprit], now: Date) -> String {
        let (kind, extra): (String, String) = switch event {
        case .alarm(let silence):
            ("alarm", silence.map { " announced=no reason=\($0.rawValue)" } ?? " announced=yes")
        case .handover: ("handover", " announced=yes")
        case .clear: ("clear", "")
        }
        let names = culprits.map {
            "\(keystrokeStripped($0.name)):\(Int($0.percent.rounded()))"
        }.joined(separator: ",")
        return "\(ISO8601DateFormatter().string(from: now)) cpu-alert=\(kind) "
            + "cpu=\(Int(busy.rounded())) cores=\(cores)\(extra)"
            + (names.isEmpty ? "\n" : " top=\(names)\n")
    }
}

let cpuAlertLogFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/logs/cpu-alert.log")
