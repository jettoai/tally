import Foundation

/// HOW THE FOOTPRINT READS: what to call a process, which fields the card's footprint row holds, in
/// what order, and where a number stops being worth a segment at all.
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

    /// The whole footprint as one sentence: how many processes the session has started, how many
    /// agents are working under them, what they are burning, what they are holding and what they
    /// are writing.
    ///
    /// EVERY SEGMENT IS OPTIONAL AND THE SEPARATOR FOLLOWS, which is the rule the identity line one
    /// file over already follows (`SessionRow`): a tree that has not been read twice yet leaves the
    /// CPU out until it has, and a session writing nothing says nothing about disk.
    ///
    /// EXCEPT THE COUNT, WHICH IS ON EVERY LINE INCLUDING AT ZERO. It used to be the one segment
    /// that could take the whole line away with it, and that was right while it counted the
    /// session's own Claude Code - a tree with none of those left is a session that has gone home,
    /// and the store still draws no card for it (`ProcessFootprintStore`, `guard !measured.isEmpty`).
    /// Counting only what the session STARTED (`dispatched`), zero is the ordinary reading of an
    /// ordinary card, and dropping the line on it would take the CPU, the memory and the trend row
    /// off the most common card on the board.
    ///
    /// DISK APPEARS ONLY WHEN IT IS A FACT ABOUT THE SESSION. Every process writes something, and a
    /// card that carried "0 MB/s" on every session all day would be spending a fifth of its one
    /// line saying nothing. Past a megabyte a second it is the answer to a question somebody is
    /// actually asking - which of these is filling my disk - so that is where it becomes visible.
    ///
    /// TWO NAMES AT MOST, AND THEY ANSWER DIFFERENT QUESTIONS. The memory carries its holder
    /// wherever it has one (`ProcessFootprint.memoryLeader`), because since the count stopped
    /// including the session's own CLI nothing else on the card says whether those gigabytes are
    /// the body or the work it started. The two RATES share the one name left: disk takes it
    /// whenever that segment is on the line at all, being the rarer sighting - the CPU segment is
    /// on every card, a session writing megabytes a second is the anomaly somebody opened the panel
    /// to find - and the CPU takes it back when there is no disk segment. The CPU's is dropped
    /// altogether when it is the program every session on this board is led by (`worthNaming`); the
    /// memory's is not, for the reason above.
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
    ///
    /// NO PRODUCTION CALLER, AND IT IS STILL THE CONTRACT. The card draws `segments` and joins the
    /// pieces itself, because one field of the line can be a warning and a single string cannot say
    /// which (`SessionCardView.sessionFootprint`); this states the same sentence in one expression,
    /// which is what the assertions read and what the two spellings of the separator are held
    /// together by.
    ///
    /// ALWAYS A SENTENCE, never nothing: it used to return nil for a tree with no processes in it,
    /// and there is no such footprint now that the count is of what the session started (see above).
    static func line(_ footprint: ProcessFootprint, unit: String,
                     agentUnit: String = "agents") -> String {
        segments(footprint, unit: unit, agentUnit: agentUnit)
            .map(\.text).joined(separator: pickEffortSeparator)
    }

    /// The ports the session is holding, as the identity line prints them: `:3000 (next-server)`,
    /// with anything past `maxPorts` becoming a count.
    ///
    /// A FIELD OF ITS OWN ON THE LINE ABOVE, WHICH IS WHERE IT MOVED FROM the footprint sentence.
    /// Down there it was the last field of a line truncated at its tail, so the one reading on this
    /// card that a person ACTS on - the port their next `pnpm dev` is about to collide with - was
    /// the first thing a narrow card dropped (Albert, 2026-08-16). Up beside the account and the
    /// model, the identity is what gives way instead.
    ///
    /// HOW MANY NAMES FIT IS DECIDED HERE, IN POINTS, RATHER THAN BY THE LAYOUT. The card used
    /// to offer the named and the bare spelling to `ViewThatFits` and let it choose, which chose
    /// wrong on every ordinary card: that view picks by its candidates' IDEAL width, and the ideal
    /// width of a truncating identity string is the whole untruncated string - so the fit test was
    /// asking "do the full identity AND the named ports both fit", which a 22-character identity
    /// (108pt measured) and one named port (98pt) already fail on a 236pt card. The named spelling
    /// was therefore almost never chosen, and the feature this row exists for was silently off.
    ///
    /// SO THE RULE IS A BUDGET, AND THE BUDGET IS IN THE UNIT THE LAYOUT SPENDS. A 264pt card gives
    /// 236pt of content, and the identity row lays out a provider mark (11pt), three gaps of four
    /// and a gutter of at least six around these strings (`SessionCardView.sessionIdentityRow`), so
    /// 207pt of ports is where the row stops fitting the card at all - the ports are drawn at their
    /// own width (`fixedSize`) and the identity beside them has already given up everything it has.
    /// An account name truncated below about 60pt stops being a name, so what the ports may spend
    /// before the line beside them stops saying anything is about 155pt, and that is the budget
    /// (`portsBudget`), a good 50pt clear of the width that would clip.
    ///
    /// IT USED TO BE COUNTED IN CHARACTERS, and thirty of them was calibrated on lower-case ASCII
    /// program names, which run about 5.2 to 5.9 points each. The strings this actually prints do
    /// not: measured with the app's own font at 10pt (2026-08-17),
    /// `:3000 (MMMMMMMMMMMMMMM) :5173` is 29 characters and 204pt, and the same shape with fifteen
    /// full-width characters in the name is 28 characters and 214pt - both inside a
    /// thirty-character budget and both past the 207pt that clips. Tally ships in five languages,
    /// so a program named in Chinese, Japanese or Korean is an expected reading rather than an
    /// exotic one, and a capital-heavy ASCII name needs no other language at all. The unit was the
    /// defect, not the calibration (codex review of 0cd4a09).
    ///
    /// NAMES ARE ADDED FROM THE LEFT AND THE NUMBERS ARE NEVER DROPPED. The widest spelling that
    /// fits the budget wins, and a spelling with no names at all is returned even when it does not
    /// fit: a port number is the fact this row is here for, and the name is the help. Measured the
    /// same way: `:3000` is 28.8pt, `:3000 (next-server)` 95.1pt, `:3000 (next-server) :5173 +1`
    /// 142.6pt and naming both of those 177.5pt - so a card holding one named port and a second
    /// bare one prints the name, and the same card asked to name both prints neither name.
    ///
    /// - Parameters:
    ///   - maxPorts: how many are listed before the rest become `+N`. Two is what fits beside an
    ///     identity line at the panel's narrowest column.
    ///   - budget: how many points the row may spend, defaulting to the measurement above.
    ///     A parameter so the harness can state both ends of the rule without a card around it.
    ///   - width: how wide a spelling is in the font the card draws it in. Asked as a function for
    ///     the reason `held` asks for a program that way: this stays pure and the harness can state
    ///     it with no AppKit and no card around it, while the one production caller measures the
    ///     real thing (`SessionCardView.portsWidth`). No default, because a ruler nobody passed
    ///     would have to be a guess about a font this file cannot see.
    static func portsText(_ footprint: ProcessFootprint, maxPorts: Int = 2,
                          budget: Double = portsBudget,
                          width: (String) -> Double) -> String? {
        guard !footprint.listeningPorts.isEmpty else { return nil }
        let shown = Array(footprint.listeningPorts.prefix(maxPorts))
        let rest = footprint.listeningPorts.count - shown.count
        func spelled(naming: Int) -> String {
            let fields = shown.enumerated().map { index, port -> String in
                guard index < naming, let name = footprint.portNames[port] else { return ":\(port)" }
                return ":\(port) (\(name))"
            }
            return (fields + (rest > 0 ? ["+\(rest)"] : [])).joined(separator: " ")
        }
        for naming in stride(from: shown.count, through: 1, by: -1) {
            let candidate = spelled(naming: naming)
            if width(candidate) <= budget { return candidate }
        }
        return spelled(naming: 0)
    }

    /// How many points of ports an identity line may carry (see `portsText`).
    static let portsBudget: Double = 155

    /// The same line in the pieces it is drawn from, each saying what it is and whether it is a
    /// warning. `line` is these joined, and stays the sentence a reader hears.
    ///
    /// A WARNING COMES FORWARD, AND THE ORDER MOVING IS THE POINT. A card is 236pt of content at
    /// the panel's narrowest (a 264pt card less this app's own card padding; the 182pt this used to
    /// claim was the grid's minimum COLUMN less that padding, which is not the width of any card
    /// the board actually draws) and the line is truncated at its tail, so a full line does not
    /// fit: measured (2026-08-15) at 11pt, `4 procs · 100% CPU · 3.9 GB · ` alone is 165.6pt and
    /// the whole sentence with a warned disk segment is 312.9pt. Left in reading order the warning's
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
    static func segments(_ footprint: ProcessFootprint,
                         unit: String, agentUnit: String = "agents") -> [ProcessFootprintSegment] {
        var parts = [ProcessFootprintSegment(kind: .processes,
                                             text: "\(footprint.processes) \(unit)", aside: unit)]
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
            let cpuName = diskName == nil ? worthNaming(footprint.cpuLeader) : nil
            parts.append(.init(kind: .cpu,
                               text: blamed("\(Int(cpu.rounded()))% CPU", on: cpuName),
                               aside: cpuName, alert: footprint.alerts.cpu))
        }
        if let memory = memoryText(footprint.memoryBytes) {
            // Named whoever it is, unlike the CPU: see `line` for why this is the one place the
            // expected leader is worth its room.
            parts.append(.init(kind: .memory,
                               text: blamed(memory, on: footprint.memoryLeader),
                               aside: footprint.memoryLeader, alert: footprint.alerts.memory))
        }
        if let disk {
            parts.append(.init(kind: .disk, text: blamed(disk, on: diskName),
                               alert: footprint.alerts.disk))
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

    /// The culprit, unless it is the one this tree is expected to be led by.
    ///
    /// A NAME IS ONLY WORTH THE ROOM IT TAKES WHEN IT IS A SURPRISE. Every card on this board is a
    /// Claude Code session, so Claude Code itself is what is burning the CPU on almost all of them,
    /// and "(claude)" printed on every card all day is the answer to a question nobody asked. What
    /// the name exists for is the other case - `42% CPU (Google Chrome Helper)`, `34% CPU (node)` -
    /// where it is the difference between knowing to look and knowing where. So the expected leader
    /// says nothing and the unexpected one is named (Albert, 2026-08-15).
    ///
    /// The disk writer is not put through this: it is already the rarer sighting (the segment only
    /// exists past a megabyte a second), and there the question really is who.
    static func worthNaming(_ leader: String?) -> String? {
        guard let leader, leader.lowercased() != expectedLeader else { return nil }
        return leader
    }

    /// What every session on this board is running, as `displayName` spells it: the installed
    /// Claude Code is `~/.local/share/claude/versions/<version>`, whose name walks up to `claude`.
    private static let expectedLeader = "claude"

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
    ///
    /// GIGABYTES PAST A THOUSAND MEGABYTES, on exactly the terms `memoryText` states them: an NVMe
    /// drive does several gigabytes a second, and this printed `6174 MB/s` for one (measured
    /// 2026-08-15) - four digits where the other figures on the card are three, and a number a
    /// reader has to divide before it means anything. Decided on the ROUNDED megabyte like the
    /// memory's, so 999.7 MB/s prints as `1.0 GB/s` rather than as "1000 MB/s".
    private static func diskRateText(_ bytesPerSecond: Double) -> String? {
        guard bytesPerSecond >= diskFloor else { return nil }
        let megabytes = (bytesPerSecond / 1_000_000).rounded()
        guard megabytes >= 1000 else { return "\(Int(megabytes)) MB/s" }
        return String(format: "%.1f GB/s", megabytes / 1000)
    }
}
