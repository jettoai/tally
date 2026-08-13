import Foundation

// Sharing the harness into an account that ALREADY EXISTS, as opposed to one being created.
//
// SharedHarness.swift is the other half, and its rule is the opposite of this one on purpose:
// `linkSharedHarness` links what is missing and NEVER replaces what is there, which is right while
// an account is being added (the home is seconds old, so anything in it is something the user just
// put there). It is the wrong rule for an account that has been running for months, because by then
// every name on the list exists, so a share of an existing account links nothing at all and reports
// success. That gap is why this machine's own numbered homes were joined up by hand, with `mv` and
// `ln -s`, and why nobody else has a way to do it at all (2026-08-13).
//
// So the items standing in the way are moved out of it first, and NOTHING IS EVER DELETED. Two
// shapes, because two kinds of thing are in the way:
//
//   - a directory that only ever ACCUMULATES (the conversation record, the inboxes, the memory
//     notes) merges file by file into the main account: both accounts' history ends up in one tree
//     and nothing has to be chosen between. A name that exists on both sides is left alone, because
//     the file in the main account is the one every other account already reads.
//   - everything else (instructions, settings, the skills/hooks/agents trees) is a document with an
//     author, and two of them merged by a machine make a third one nobody wrote. It is renamed
//     aside, whole, and stays in the account's own home.
//
// Backup-and-link is what GNU Stow (`stow --adopt`) and chezmoi both do when a real file stands
// where a link belongs, for the reason this does: the link is the point, and the bytes in the way
// belong to somebody.
//
// Compiled into BOTH targets, like the add flow it completes: `tally share` and the Settings
// "Shared harness" row are one act from two surfaces, and a second copy would let one of them share
// a set the other does not.

/// The items a share MERGES instead of moving aside whole: directories that are only ever added to,
/// file by file, by a program rather than edited by a person.
///
/// The list is deliberately about the SHAPE of a directory, not about which provider owns it: the
/// claude conversation record (`projects`), the messages sessions leave each other (`inboxes`), the
/// notes a session writes for the next one (`memory`), and codex's two conversation directories
/// (`sessions` plus `archived_sessions`, which archiving MOVES a conversation between). What every
/// one of them has in common is that a file inside is written once under a name nothing else will
/// choose, so putting two accounts' files in one tree loses nothing.
///
/// `memory` is the interesting member: a file in it CAN be edited by hand (an index like
/// MEMORY.md), which is exactly why a name present on both sides is never merged and never
/// overwritten. What moves across is only what the main account does not already have.
let mergeableHarnessItems: Set<String> = [
    "projects", "memory", inboxesItem, "sessions", "archived_sessions",
]

/// What sharing ONE item did. Every case is an outcome rather than an intention (`AddedAccountHome`
/// says why): a link that failed on permissions has to be reportable as a share that did not happen.
enum ShareExistingOutcome: Equatable {
    /// Nothing was in the way, so the item is now a link to the main account.
    case linked
    /// It already resolved to the main account's item: this run had nothing to do, and a second run
    /// changes nothing (the whole command is safe to repeat).
    case alreadyShared
    /// An accumulating directory, merged: `moved` files went into the main account, `kept` files
    /// were already there under the same name and stayed behind in `backup`. A nil backup means
    /// nothing was left to keep.
    case merged(moved: Int, kept: Int, backup: String?)
    /// A file or directory of the user's own, renamed aside under this name and then linked.
    case backedUp(String)
    /// Nothing about this item was changed, and here is why.
    case failed(String)
}

/// One item's share, named.
struct ShareExistingResult: Equatable {
    let item: String
    let outcome: ShareExistingOutcome
}

/// What sharing one account's home did, in the words the surface that asked will report it in.
struct ShareExistingReport: Equatable {
    /// The home asked about IS the main account: there is nothing to share it with, and nothing was
    /// touched. Reported rather than treated as an error, because `--all` walks past it.
    var isMainHome = false
    var results: [ShareExistingResult] = []
    /// Whether the conversation record now resolves to the main account's - the truth behind the
    /// privacy note, and asked of the filesystem afterwards rather than assembled from the work
    /// above (this run, an earlier run, or a hand-made link all count the same).
    var sharesConversations = false

    var linked: [String] { items { $0 == .linked } }
    var alreadyShared: [String] { items { $0 == .alreadyShared } }
    var failed: [String] { items { if case .failed = $0 { return true }; return false } }

    /// The names things were renamed aside under, as "item -> backup" pairs.
    var backups: [(item: String, name: String)] {
        results.compactMap { result in
            switch result.outcome {
            case .backedUp(let name): return (result.item, name)
            case .merged(_, _, let backup): return backup.map { (result.item, $0) }
            default: return nil
            }
        }
    }

    /// How many files were carried into the main account, over every merged directory.
    var movedFiles: Int {
        results.reduce(0) { total, result in
            if case .merged(let moved, _, _) = result.outcome { return total + moved }
            return total
        }
    }

    /// Whether this run changed anything at all, which is what separates "shared" from "already
    /// was" in a report somebody reads.
    var changed: Bool { !linked.isEmpty || movedFiles > 0 || !backups.isEmpty }

    private func items(_ matching: (ShareExistingOutcome) -> Bool) -> [String] {
        results.filter { matching($0.outcome) }.map(\.item)
    }
}

/// Point `target`'s harness at `mainHome`'s, moving whatever stands in the way out of it first.
///
/// Idempotent by construction: an item that already resolves to the main account is left alone, so
/// running this twice does the work once and the second run reports nothing to do.
@discardableResult
func shareExistingHarness(providerID: String, mainHome: URL, target: URL,
                          items: [String]? = nil, now: Date = Date()) -> ShareExistingReport {
    var report = ShareExistingReport()
    guard target.standardizedFileURL.path != mainHome.standardizedFileURL.path else {
        report.isMainHome = true
        return report
    }
    let items = items ?? harnessItems(for: providerID, in: mainHome)
    // Before anything is linked, for the reason the add flow calls it: `inboxes` is Tally's own
    // concept and does not exist until the first cross-session message is left, so without this the
    // one item the fleet needs most is the one item a share skips (SharedHarness.swift).
    ensureSharedInboxes(in: mainHome, items: items)
    for item in items {
        let source = mainHome.appendingPathComponent(item)
        let dest = target.appendingPathComponent(item)
        // What the main account does not have is not shared, exactly as `linkSharedHarness` has it:
        // creating `projects` or `memory` on the provider CLI's behalf changes what it finds.
        guard FileManager.default.fileExists(atPath: source.path) else { continue }
        report.results.append(ShareExistingResult(
            item: item, outcome: shareExistingItem(item, source: source, dest: dest, now: now)))
    }
    report.sharesConversations = sharesConversations(providerID: providerID,
                                                     source: mainHome, target: target)
    return report
}

/// One item of one home: the whole decision, from what is standing there to the link that replaces
/// it.
private func shareExistingItem(_ item: String, source: URL, dest: URL,
                               now: Date) -> ShareExistingOutcome {
    let fm = FileManager.default
    /// The last act of every path that gets that far, so a link failure is reported the same way
    /// whatever was moved out of the way first: the backup keeps its name, and the outcome says the
    /// share did not happen.
    func link(_ outcome: ShareExistingOutcome) -> ShareExistingOutcome {
        do {
            try fm.createSymbolicLink(at: dest, withDestinationURL: source)
            return outcome
        } catch {
            return .failed(error.localizedDescription)
        }
    }
    // lstat, never stat (`attributesOfItem` does not traverse): a dangling link is something that
    // IS there, and reading it as absent would have the link below fail on a path that exists.
    guard let attributes = try? fm.attributesOfItem(atPath: dest.path) else { return link(.linked) }
    let type = attributes[.type] as? FileAttributeType
    // Asked by RESOLUTION rather than by the link's text, the way `sharesConversations` asks it: a
    // relative link, or one wired through another link, is sharing just as much as ours is.
    if type == .typeSymbolicLink,
       dest.resolvingSymlinksInPath().path == source.resolvingSymlinksInPath().path {
        return .alreadyShared
    }

    var mergeCounts: (moved: Int, kept: Int)?
    if type == .typeDirectory, mergeableHarnessItems.contains(item) {
        let counts = mergeHarnessDirectory(from: dest, into: source)
        mergeCounts = counts
        if counts.kept == 0 {
            // Everything moved across, so what is left is the empty shape of the directory tree.
            // Removing it is the one deletion in here, and it deletes no file: a directory that
            // still held one would have counted it as kept.
            guard (try? fm.removeItem(at: dest)) != nil else {
                return .failed("the emptied \(item) directory could not be removed")
            }
            return link(.merged(moved: counts.moved, kept: 0, backup: nil))
        }
    }

    let backup = harnessBackupName(item, on: now) {
        (try? fm.attributesOfItem(atPath: dest.deletingLastPathComponent()
            .appendingPathComponent($0).path)) != nil
    }
    do {
        try fm.moveItem(at: dest,
                        to: dest.deletingLastPathComponent().appendingPathComponent(backup))
    } catch {
        return .failed(error.localizedDescription)
    }
    if let mergeCounts {
        return link(.merged(moved: mergeCounts.moved, kept: mergeCounts.kept, backup: backup))
    }
    return link(.backedUp(backup))
}

/// The name a displaced item is kept under: its own name, the word `local`, and the day. A name
/// somebody can read in a directory listing months later and know both what it was and when it
/// stopped being used.
///
/// `taken` is asked rather than assumed, and it is asked repeatedly: two shares of the same account
/// on one day must not have the second one rename its backup over the first one, which would be the
/// single deletion this whole file exists to avoid.
func harnessBackupName(_ item: String, on date: Date, calendar: Calendar = .current,
                       taken: (String) -> Bool) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    let stamp = String(format: "%04d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    let base = "\(item).local-\(stamp)"
    guard taken(base) else { return base }
    for n in 2 ... 99 {
        let candidate = "\(base)-\(n)"
        if !taken(candidate) { return candidate }
    }
    // A hundred backups of one item in one day is not a thing that happens; a name that collides
    // anyway would be, so the last resort is a name nothing can hold already.
    return "\(base)-\(UUID().uuidString.prefix(8))"
}

/// Moves every FILE under `dir` into `main` at the same relative path, unless something of that name
/// is already there. Returns how many moved and how many stayed.
///
/// File by file rather than directory by directory, because the collisions are per file: two
/// accounts that have both been used in the same project have a `projects/<that project>` each, and
/// moving the directory as a whole would be a collision at the first level with hundreds of
/// transcripts behind it that collide with nothing.
private func mergeHarnessDirectory(from dir: URL, into main: URL) -> (moved: Int, kept: Int) {
    var moved = 0, kept = 0
    mergeHarnessEntries(from: dir, into: main, moved: &moved, kept: &kept)
    return (moved, kept)
}

private func mergeHarnessEntries(from dir: URL, into main: URL,
                                 moved: inout Int, kept: inout Int) {
    let fm = FileManager.default
    for name in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() {
        let source = dir.appendingPathComponent(name)
        let destination = main.appendingPathComponent(name)
        // lstat again: a symlink to a directory is moved as the one thing it is, rather than
        // descended into and taken apart.
        let type = (try? fm.attributesOfItem(atPath: source.path))?[.type] as? FileAttributeType
        if type == .typeDirectory {
            mergeHarnessEntries(from: source, into: destination, moved: &moved, kept: &kept)
            continue
        }
        guard (try? fm.attributesOfItem(atPath: destination.path)) == nil else {
            kept += 1
            continue
        }
        // Created only now, and only on the branch that is about to move something: a directory
        // made on the way down would leave empty folders in the main account for every subtree
        // whose files all collided.
        try? fm.createDirectory(at: main, withIntermediateDirectories: true)
        if (try? fm.moveItem(at: source, to: destination)) != nil { moved += 1 } else { kept += 1 }
    }
}

// MARK: - Reading the state back

/// How much of one account's harness resolves to the main account's: the share as a fraction, so a
/// surface can tell "all of it", "some of it" and "none of it" apart.
struct SharedHarnessProgress: Equatable {
    var shared = 0
    /// The items the MAIN account has, which is the only sensible denominator: an item nobody has
    /// says nothing about whether these two accounts share a setup.
    var total = 0
    var isComplete: Bool { shared == total }
}

/// The same comparison `HarnessSharing.report` makes for the panel's per-account facts, asked here
/// of the list a share actually links rather than of the shorter list worth showing a reader.
func sharedHarnessProgress(providerID: String, mainHome: URL, target: URL,
                           items: [String]? = nil) -> SharedHarnessProgress {
    var progress = SharedHarnessProgress()
    guard target.standardizedFileURL.path != mainHome.standardizedFileURL.path else {
        return progress
    }
    for item in items ?? harnessItems(for: providerID, in: mainHome) {
        let source = mainHome.appendingPathComponent(item)
        guard FileManager.default.fileExists(atPath: source.path) else { continue }
        progress.total += 1
        // .path rather than URL equality, for the reason HarnessSharing.swift gives: resolving a
        // link to a directory yields a trailing-slash URL and a plain directory does not.
        if target.appendingPathComponent(item).resolvingSymlinksInPath().path
            == source.resolvingSymlinksInPath().path {
            progress.shared += 1
        }
    }
    return progress
}

/// What a whole fleet's worth of that adds up to, which is what a single row in Settings has to say
/// in one word.
enum SharedHarnessCoverage: Equatable {
    /// Every account shares everything the main account has.
    case complete
    /// Some accounts, or some items, but not all: the state a half-done share leaves, and the one
    /// worth pointing at.
    case partial
    /// No account shares anything.
    case none
}

func sharedHarnessCoverage(_ progress: [SharedHarnessProgress]) -> SharedHarnessCoverage {
    guard !progress.isEmpty else { return .none }
    if progress.allSatisfy(\.isComplete) { return .complete }
    if progress.allSatisfy({ $0.shared == 0 }) { return .none }
    return .partial
}
