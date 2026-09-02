import Darwin
import Foundation

/// TELLING THE PROJECT WHAT HAPPENED IN ITS CHECKOUT.
///
/// A KILL NOBODY IS TOLD ABOUT IS INDISTINGUISHABLE FROM A CRASH. Somebody comes back to a dev
/// server that is not running and a port that is free, and the only honest reading available to them
/// is that it fell over - which is worse than the runaway, because now the machine is doing
/// something they cannot account for. So every reclaim and every tier-C candidate is written into
/// the owning project's inbox, in the format the harness's own `notify` skill defines, and read by
/// whichever session opens that project next.
///
/// THE INBOX IS ADDRESSED BY REPOSITORY, NOT BY DIRECTORY, and getting that wrong is the failure
/// mode worth naming: a key nothing reads is a dead letter, and a dead letter is silence wearing the
/// clothes of a report. Two rules do the work. The key is the repository's path relative to the
/// workspace with the separators flattened (`~/workspace/taiwanbigdata/bigdata` becomes
/// `taiwanbigdata-bigdata`), because that is the key every other writer of these inboxes uses; and a
/// PARALLEL LINE'S message goes to its repository's box with the worktree named in the first line,
/// because a worktree's own inbox exists only while somebody is working in it and this message
/// arrives precisely when nobody is.
///
/// NOTHING IN A MESSAGE COMES OFF A COMMAND LINE. The rule the rest of this app keeps
/// (`ProcessFootprint.memoryLeader`, `MachineLoadRollup.commandLine`) holds here for a stronger
/// reason: a message is a file on disk that another agent will read into its context. What is
/// written is the program's name, the checkout, the ports, the figures and what was done - each of
/// which is a fact about the machine that cannot carry a token.
enum OrphanNotice {

    /// What a message is about.
    struct Report: Equatable {
        /// The checkout the tree was working in, as the machine spells it.
        var project: String
        /// What to call the program.
        var program: String
        var pid: pid_t
        var processes: Int
        var cpuPercent: Double?
        var memoryBytes: UInt64
        var listeningPorts: [UInt16]
        var ageSeconds: TimeInterval
        /// What was done, which is the first thing a reader needs.
        var outcome: Outcome
    }

    enum Outcome: Equatable {
        /// Ended, because a dev-watch lease named it and its supervisor was gone.
        case reclaimedByLease
        /// Ended, on two rounds of evidence.
        case reclaimedBySustained
        /// Not ended: here is what is running and why this app would not touch it.
        case reported(doubts: [OrphanReclaim.Veto])
        /// Tried to end it and could not.
        case failed(reason: String)
    }

    /// WHICH REPOSITORY A DIRECTORY BELONGS TO, and whether it is a parallel line of one.
    struct Repository: Equatable {
        /// The main repository's working tree.
        var root: String
        /// The worktree the process was actually in, when that is not the root itself.
        var worktree: String?
    }

    /// What a `.git` entry turned out to be, as the caller found it.
    enum GitEntry: Equatable {
        /// A directory: this is an ordinary checkout and its parent is the root.
        case directory
        /// A file, with its contents: this is a linked worktree pointing at the real git directory.
        case file(String)
    }

    /// THE REPOSITORY ABOVE A DIRECTORY, walked upwards until a `.git` turns up.
    ///
    /// GIT IS NOT RUN, and that is a decision rather than a shortcut. `git rev-parse` is a fork and
    /// an exec per candidate, on a code path that runs while a machine is already in trouble; the
    /// two layouts that matter here are both readable directly, and the third (a submodule, a
    /// `--separate-git-dir` repo) simply falls back to the directory holding the `.git`, which is a
    /// checkout in every one of those layouts even when it is not the MAIN one. The cost of that
    /// fallback is a message in the submodule's own inbox rather than its parent's, which is a
    /// message somebody still reads.
    ///
    /// A LINKED WORKTREE'S `.git` IS A FILE reading `gitdir: <repo>/.git/worktrees/<name>`, so the
    /// repository is what sits before that suffix. The worktree itself is carried alongside rather
    /// than discarded: the message says where the process really was, because "something was running
    /// in bigdata" is the wrong sentence when it was running in a parallel line of it.
    ///
    /// - Parameter entry: what `<directory>/.git` is, or nil when there is none there.
    static func repository(of directory: String, entry: (String) -> GitEntry?) -> Repository? {
        var here = directory
        while here.count > 1 {
            switch entry(here + "/.git") {
            case .directory:
                return Repository(root: here, worktree: nil)
            case .file(let text):
                guard let root = mainRepository(gitdir: text) else {
                    return Repository(root: here, worktree: nil)
                }
                return Repository(root: root, worktree: here)
            case nil:
                guard let slash = here.lastIndex(of: "/"), slash != here.startIndex else {
                    return nil
                }
                here = String(here[here.startIndex ..< slash])
            }
        }
        return nil
    }

    /// The repository a linked worktree's `.git` file points back at.
    static func mainRepository(gitdir text: String) -> String? {
        let marker = "gitdir:"
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix(marker) })
        else { return nil }
        let path = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        guard let cut = path.range(of: "/.git/worktrees/") else { return nil }
        return String(path[path.startIndex ..< cut.lowerBound])
    }

    /// THE INBOX KEY FOR A REPOSITORY.
    ///
    /// Under the workspace, the relative path with `/` flattened to `-`, which is what the other
    /// writers of these inboxes produce. Outside it, the last component alone - which can collide
    /// with another checkout of the same name, and is still better than the alternatives: an
    /// absolute path is not a directory name, and refusing to address it at all would drop the
    /// report of a reclaim that has already happened.
    static func key(for repository: String, workspace: String) -> String {
        let inside = repository.hasPrefix(workspace + "/")
        guard inside else {
            return URL(fileURLWithPath: repository).lastPathComponent
        }
        let relative = String(repository.dropFirst(workspace.count + 1))
        return relative.replacingOccurrences(of: "/", with: "-")
    }

    /// What `<directory>/.git` is on the real filesystem, which is the one call the walk above
    /// makes. A `.git` that cannot be read is reported as an empty file rather than as absent: the
    /// walk then stops here and calls this directory the repository, which is true, instead of
    /// climbing past it into whatever encloses the checkout.
    static func gitEntry(_ path: String) -> GitEntry? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return nil
        }
        guard !isDirectory.boolValue else { return .directory }
        return .file((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
    }

    /// The inbox directory for a key.
    static func inbox(_ key: String, home: URL) -> URL {
        home.appendingPathComponent(".claude/inboxes/\(key)")
    }

    /// THE FILENAME, on the maildir rule the harness's own `notify` uses: seconds, then the writer's
    /// pid, then a random number, so two messages written in the same second cannot overwrite each
    /// other. The topic is fixed, because every message this app writes is about the same thing and
    /// a reader filtering on `orphan-reclaim` should catch all of them.
    static func filename(at instant: Date, pid: pid_t, random: UInt32) -> String {
        "\(stamp(instant))-\(pid)-\(random)-from-tally-app-orphan-reclaim.md"
    }

    /// `YYYY-MM-DD-HHMMSS` in local time, which is how the existing messages in these inboxes are
    /// named. Local rather than UTC so the filenames sort the way the reader's own day does.
    static func stamp(_ instant: Date) -> String {
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "yyyy-MM-dd-HHmmss"
        return clock.string(from: instant)
    }

    /// THE MESSAGE ITSELF.
    ///
    /// `reply: none` ON EVERY ONE OF THEM. The harness's `notify` contract has a session's stop gate
    /// chase anything marked otherwise until it is answered, and there is nobody here to answer: the
    /// writer is a menu bar app, and what it has to say is finished when it has been said. A message
    /// asking for a reply from a process that cannot receive one would leave a session holding an
    /// obligation forever, which the contract's own note calls out as the common mistake.
    static func message(_ report: Report, to key: String, worktree: String?,
                        at instant: Date) -> String {
        var lines: [String] = []
        lines.append("# \(headline(report))")
        lines.append("")
        lines.append("**from**: tally-app")
        lines.append("**to**: \(key)")
        lines.append("**ts**: \(iso(instant))")
        lines.append("**type**: notify")
        lines.append("**reply**: none")
        lines.append("**thread**: orphan-reclaim")
        lines.append("**hop**: 0")
        lines.append("")
        if let worktree {
            lines.append("Worktree: `\(worktree)` (this message goes to the main repository's inbox"
                + " because a parallel line's own inbox is read only while somebody is working in"
                + " it, and this arrives when nobody is).")
            lines.append("")
        }
        lines.append(contentsOf: body(report))
        lines.append("")
        lines.append(contentsOf: closing(report))
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func headline(_ report: Report) -> String {
        switch report.outcome {
        case .reclaimedByLease, .reclaimedBySustained:
            return "Tally ended a leftover `\(report.program)` in \(name(report.project))"
        case .reported:
            return "Tally found a leftover `\(report.program)` in \(name(report.project))"
        case .failed:
            return "Tally could not end a leftover `\(report.program)` in \(name(report.project))"
        }
    }

    /// What was running, as facts rather than as prose.
    private static func body(_ report: Report) -> [String] {
        var lines = ["- Working in: `\(report.project)`",
                     "- Program: `\(report.program)` (pid \(report.pid),"
                        + " \(report.processes) process\(report.processes == 1 ? "" : "es"))",
                     "- Running for: \(duration(report.ageSeconds))"]
        if let percent = report.cpuPercent {
            lines.append("- CPU: \(Int(percent.rounded()))% of one core")
        }
        if let held = ProcessTree.memoryText(report.memoryBytes) {
            lines.append("- Memory: \(held)")
        }
        lines.append(report.listeningPorts.isEmpty
            ? "- Listening on: nothing (no port held)"
            : "- Listening on: " + report.listeningPorts.map { ":\($0)" }.joined(separator: ", "))
        return lines
    }

    /// And what was done about it.
    private static func closing(_ report: Report) -> [String] {
        switch report.outcome {
        case .reclaimedByLease:
            return ["Ended it. A `/dev-watch` lease named this tree and the supervisor that wrote"
                        + " the lease is no longer running, so nothing was left to answer for it."
                        + " The lease files have been removed.",
                    "",
                    "If you wanted this server up, start it again with `/dev-watch`."]
        case .reclaimedBySustained:
            return ["Ended it. No live session was working in this checkout, the tree was older"
                        + " than \(Int(OrphanReclaim.minimumAge / 60)) minutes, it read the same"
                        + " way twice more than \(Int(OrphanReclaim.roundInterval / 60)) minutes"
                        + " apart, and nothing suggested anybody was using it (no terminal, no"
                        + " editor above it, nothing connected to its ports).",
                    "",
                    "If this was wanted, start it again - and if it should stay up unattended, run"
                        + " it under `/dev-watch`, whose lease says whose it is."]
        case .reported(let doubts):
            return ["Left it alone. It looks like something nobody is answering for, but this app"
                        + " will not end a process it cannot be sure about, and here it could not"
                        + " be: " + doubts.map { reason($0) }.joined(separator: "; ") + ".",
                    "",
                    "Have a look and end it yourself if it is not wanted."]
        case .failed(let reason):
            return ["Tried to end it and could not: \(reason). It is still running.",
                    "",
                    "This needs a hand."]
        }
    }

    private static func reason(_ veto: OrphanReclaim.Veto) -> String {
        switch veto {
        case .terminal: return "a terminal is attached to it"
        case .ancestor: return "it is running under an editor or a multiplexer"
        case .inUse: return "something is connected to it"
        case .unreadable: return "the machine would not state one of its fields"
        case .crossRepo: return "part of the tree is working in another checkout"
        case .unknownProgram: return "its program is not one this app recognises as development work"
        }
    }

    private static func name(_ project: String) -> String {
        "`" + URL(fileURLWithPath: project).lastPathComponent + "`"
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        guard minutes >= 60 else { return "\(minutes) min" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private static func iso(_ instant: Date) -> String {
        let clock = ISO8601DateFormatter()
        clock.timeZone = TimeZone(identifier: "UTC")
        return clock.string(from: instant)
    }

    /// WRITE ONE MESSAGE, the way a maildir is written: into `.tmp` under the inbox, then renamed
    /// into place. A reader that opens the directory at any instant sees whole files only, which is
    /// the property a half-written message would take away - and the receiving side reads these the
    /// moment it notices them.
    ///
    /// - Returns: the path it landed at, or nil when it could not be delivered.
    @discardableResult
    static func deliver(_ text: String, to inbox: URL, named filename: String) -> URL? {
        let manager = FileManager.default
        let staging = inbox.appendingPathComponent(".tmp")
        guard (try? manager.createDirectory(at: staging, withIntermediateDirectories: true)) != nil
        else { return nil }
        let temporary = staging.appendingPathComponent(filename)
        let destination = inbox.appendingPathComponent(filename)
        guard (try? text.write(to: temporary, atomically: false, encoding: .utf8)) != nil,
              (try? manager.moveItem(at: temporary, to: destination)) != nil else {
            try? manager.removeItem(at: temporary)
            return nil
        }
        return destination
    }
}
