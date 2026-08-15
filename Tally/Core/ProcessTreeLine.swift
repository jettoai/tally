import Foundation

/// HOW THE FOOTPRINT READS: what to call a process, which fields the card's one line holds, in what
/// order, and where a number stops being worth a segment at all.
///
/// Split from ProcessTreeStats.swift, which had run out of room, along the seam that file already
/// had inside it: over there is what the numbers MEAN (which pids are in a tree, what two
/// cumulative readings say, who to blame for the difference), and here is what a person sees. Both
/// halves stay pure, so the assertion harness can state either without a process around it.
extension ProcessTree {

    /// What to call a process, given the path of the program it is running.
    ///
    /// THE LAST COMPONENT IS THE NAME, EXCEPT WHEN IT IS A VERSION NUMBER, and that exception is
    /// not an edge case here: Claude Code installs itself as
    /// `~/.local/share/claude/versions/2.1.233`, where the executable FILE is the version, so the
    /// one process this line most often has to name would be printed as "40% CPU (2.1.233)"
    /// (measured on this machine, 2026-08-15). A version is not a name, so the walk continues up
    /// through the installer's own container words until something that names a program appears.
    ///
    /// AN ORDINARY NAME IS NEVER WALKED PAST, because the walk only starts on a version: `bin` and
    /// `versions` are stepped over on the way up and never used to reject a name a program actually
    /// has (`/opt/homebrew/Cellar/uv/0.9.2/bin/uv` is `uv`, and `python3.12` keeps its digits
    /// because letters make it a name rather than a number).
    static func displayName(forPath path: String) -> String? {
        var parts = path.split(separator: "/").map(String.init)
        guard var name = parts.popLast() else { return nil }
        while isVersionNumber(name) || installerContainers.contains(name.lowercased()) {
            guard let next = parts.popLast() else { return nil }
            name = next
        }
        return name
    }

    /// The directories an installer puts a versioned build in, which name nothing on their own.
    /// Both are ones this machine actually holds a program under (measured 2026-08-15).
    private static let installerContainers: Set<String> = ["versions", "bin"]

    /// Digits and dots, optionally led by a `v`: `2.1.233`, `v20.11.0`. Anything with a letter in
    /// it is a name that happens to carry a number, which is most of the interpreters on a machine.
    static func isVersionNumber(_ name: String) -> Bool {
        var digits = Substring(name)
        if digits.hasPrefix("v") { digits = digits.dropFirst() }
        return digits.contains(where: \.isNumber) && digits.allSatisfy { $0.isNumber || $0 == "." }
    }

    /// The card's line: how many processes, how many agents are working under them, what they are
    /// burning, what they are holding, what they are writing and what they are listening on.
    ///
    /// EVERY SEGMENT IS OPTIONAL AND THE SEPARATOR FOLLOWS, which is the rule the identity line one
    /// file over already follows (`SessionRow`): a session with no ports says nothing about ports
    /// rather than printing an empty field, and a tree that has not been read twice yet leaves the
    /// CPU out until it has. A tree with no processes has no line at all.
    ///
    /// DISK APPEARS ONLY WHEN IT IS A FACT ABOUT THE SESSION. Every process writes something, and a
    /// card that carried "0 MB/s" on every session all day would be spending a fifth of its one
    /// line saying nothing. Past a megabyte a second it is the answer to a question somebody is
    /// actually asking - which of these is filling my disk - so that is where it becomes visible.
    ///
    /// ONE NAME PER LINE, AND DISK TAKES IT. Both blamed segments can have a culprit at once, and
    /// two parentheticals is what turns a line into a paragraph on a card one line wide. Disk wins
    /// because it is the rarer sighting: the CPU segment is on every card, while a session writing
    /// megabytes a second is the anomaly somebody opened the panel to find. Memory carries no name
    /// at all - what holds memory persistently is the long-lived process the count and the ports
    /// already point at.
    ///
    /// - Parameters:
    ///   - unit: the word for "processes", already localised, so this stays a pure function of what
    ///     it is handed (the harness compiles it with no bundle around it) and the caller keeps the
    ///     one decision a word carries: whether it is the plural.
    ///   - agentUnit: the same for "agents". IT CARRIES A DEFAULT WHERE `unit` DOES NOT, because
    ///     the two are needed in different states: every line has a process count and only a
    ///     fanned-out session has an agent one, and Swift cannot spell "required when `agents > 0`".
    ///     What a forgotten argument costs is therefore one English word on a translated card,
    ///     which a reader sees; the one production caller is pinned to passing it by an assertion
    ///     that reads its source (processtreelinechecks.swift).
    ///   - maxPorts: how many ports are named before the rest become a count. A card is one line
    ///     wide and a dev box can hold a dozen ports; three is what fits beside the other two
    ///     segments at the panel's narrowest column.
    static func line(_ footprint: ProcessFootprint, unit: String, agentUnit: String = "agents",
                     maxPorts: Int = 3) -> String? {
        let parts = segments(footprint, unit: unit, agentUnit: agentUnit, maxPorts: maxPorts)
        guard !parts.isEmpty else { return nil }
        return parts.map(\.text).joined(separator: pickEffortSeparator)
    }

    /// The same line in the pieces it is drawn from, each saying what it is and whether it is a
    /// warning. `line` is these joined, and stays the sentence a reader hears.
    ///
    /// A WARNING COMES FORWARD, AND THE ORDER MOVING IS THE POINT. A card is 182pt of content at
    /// the panel's narrowest and the line is truncated at its tail, so a full line does not fit:
    /// measured (2026-08-15) at 11pt, `4 procs · 100% CPU · 3.9 GB · ` alone is 165.6pt and the
    /// whole sentence with a warned disk segment is 312.9pt. Left in reading order the warning's
    /// mark survives and its NUMBER does not - a triangle stranded beside the memory figure, which
    /// reads as a warning about the memory and gives no reason for either. So the warned fields are
    /// drawn first and the healthy ones are what falls off the end, which is the right thing to
    /// lose: those are the ones nobody opened the panel for.
    ///
    /// THE COUNT STAYS AT THE FRONT REGARDLESS, because it is not a reading in the same sense - it
    /// is the context every other field is about ("12 MB/s" means something different under 2
    /// processes than under 40), and a line that opened on a warning would say what is wrong before
    /// saying what it is wrong about. Everything else keeps its reading order inside its group, so
    /// a card only ever reorders across the warning line, never within it.
    ///
    /// THE AGENTS ARE AN ORDINARY FIELD, warnings and all: a fan-out is a thing somebody chose to
    /// start, so however many are running it is never a condition to be alarmed about, and it is
    /// only shown while at least one is (`ProcessFootprint.agents` says what a zero means and why
    /// it is not printed).
    static func segments(_ footprint: ProcessFootprint, unit: String, agentUnit: String = "agents",
                         maxPorts: Int = 3) -> [ProcessFootprintSegment] {
        guard footprint.processes > 0 else { return [] }
        var parts = [ProcessFootprintSegment(kind: .processes,
                                             text: "\(footprint.processes) \(unit)")]
        if footprint.agents > 0 {
            parts.append(.init(kind: .agents, text: "\(footprint.agents) \(agentUnit)"))
        }
        // Decided before the CPU segment is built, because whether disk is on the line at all is
        // what decides which segment gets to carry a name.
        let disk = footprint.diskWriteBytesPerSecond.flatMap(diskRateText)
        let diskName = disk == nil ? nil : footprint.diskLeader
        // Rounded to whole points: the reading is a difference of two samples taken about two
        // seconds apart, and decimals on it would be spelling out noise.
        if let cpu = footprint.cpuPercent {
            parts.append(.init(kind: .cpu,
                               text: blamed("\(Int(cpu.rounded()))% CPU",
                                            on: diskName == nil ? footprint.cpuLeader : nil),
                               alert: footprint.alerts.cpu))
        }
        if let memory = memoryText(footprint.memoryBytes) {
            parts.append(.init(kind: .memory, text: memory, alert: footprint.alerts.memory))
        }
        if let disk {
            parts.append(.init(kind: .disk, text: blamed(disk, on: diskName),
                               alert: footprint.alerts.disk))
        }
        if !footprint.listeningPorts.isEmpty {
            let named = footprint.listeningPorts.prefix(maxPorts).map { ":\($0)" }
            let rest = footprint.listeningPorts.count - named.count
            parts.append(.init(kind: .ports,
                               text: (named + (rest > 0 ? ["+\(rest)"] : [])).joined(separator: " ")))
        }
        // Built in reading order above and reordered here in one place, so every field is written
        // where it belongs in the sentence and only one rule decides what a narrow card keeps.
        let readings = parts.dropFirst()
        return Array(parts.prefix(1)) + readings.filter(\.alert) + readings.filter { !$0.alert }
    }

    private static func blamed(_ segment: String, on name: String?) -> String {
        guard let name else { return segment }
        return "\(segment) (\(name))"
    }

    /// What the tree is holding, in the units a Mac states memory in: DECIMAL, because that is what
    /// Activity Monitor and every spec sheet the number will be compared against use. Whole
    /// megabytes below a gigabyte and one decimal above it, so the segment is four characters wide
    /// either way and a card's line does not reflow as a session grows.
    ///
    /// Under a megabyte is nothing rather than "0 MB": either the tree is a single sleeping shell,
    /// or nothing could be read at all, and neither is worth a segment.
    ///
    /// Not private, because the peak beside the trend line is the same quantity and has to be spelt
    /// the same way (`FootprintTrendMetric.peakText`): a peak reading "4200 MB" under a current
    /// value reading "3.9 GB" would look like two different measurements.
    static func memoryText(_ bytes: UInt64) -> String? {
        let megabytes = (Double(bytes) / 1_000_000).rounded()
        guard megabytes >= 1 else { return nil }
        // Decided on the rounded number, so 999.7 MB prints as 1.0 GB rather than as "1000 MB".
        guard megabytes >= 1000 else { return "\(Int(megabytes)) MB" }
        return String(format: "%.1f GB", megabytes / 1000)
    }

    /// Where writing becomes a fact about the session rather than the background noise every
    /// process makes: a megabyte a second (see `line`). The warning rules count from the same
    /// number, so "the segment is visible" and "the segment is worth watching" cannot drift apart.
    static let diskFloor: Double = 1_000_000

    /// The write rate, or nothing below the threshold the segment exists above (see `line`).
    private static func diskRateText(_ bytesPerSecond: Double) -> String? {
        guard bytesPerSecond >= diskFloor else { return nil }
        return "\(Int((bytesPerSecond / 1_000_000).rounded())) MB/s"
    }
}
