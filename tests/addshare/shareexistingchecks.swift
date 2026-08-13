import Foundation

// Sharing the harness into an account that ALREADY EXISTS (Tally/Core/ShareExisting.swift).
//
// The suite next door covers the share that happens while an account is being ADDED, whose whole
// rule is "never touch what is already there". This one is about the opposite situation, where
// everything is already there: what is moved, what is merged, what is renamed aside, and the one
// promise that has to hold over all of it - NOTHING IS DELETED. So most rows below assert on the
// bytes afterwards rather than on the report: a report saying "backed up" while the file is gone is
// exactly the failure this file exists to catch.
//
// Runs as a function main.swift calls, which owns the shared harness (`check`), the way the
// integrations suite splits its checks.

func runShareExistingChecks(root: URL) {
    let fm = FileManager.default
    // A fixed day, so the names backups are given can be asserted rather than recomputed from
    // whatever "today" is when the suite runs.
    let day = Date(timeIntervalSince1970: 1_770_000_000)
    let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
    let stamp = String(format: "%04d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)

    func write(_ text: String, _ url: URL) {
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
    func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    func home(_ name: String) -> URL {
        let url = root.appendingPathComponent(name)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    /// A main account with one of everything the rule distinguishes: two documents, one tree of
    /// documents, two accumulating directories, and a credential that is on no share list at all.
    func mainAccount(_ name: String) -> URL {
        let main = home(name)
        write("main rules", main.appendingPathComponent("CLAUDE.md"))
        write("{}", main.appendingPathComponent("settings.json"))
        write("main skill", main.appendingPathComponent("skills/demo/SKILL.md"))
        write("main index", main.appendingPathComponent("memory/MEMORY.md"))
        write("main one", main.appendingPathComponent("projects/proj-a/one.jsonl"))
        write("main note", main.appendingPathComponent("inboxes/tally/note.md"))
        write("secret", main.appendingPathComponent(".credentials.json"))
        return main
    }

    // MARK: - The name a displaced file is kept under

    check("a backup is named for the item and the day",
          harnessBackupName("CLAUDE.md", on: day) { _ in false } == "CLAUDE.md.local-\(stamp)")
    // Two shares of one account on one day. A second run reusing the first run's name would rename
    // one backup over the other, which is the single deletion this whole file exists to avoid.
    check("a name already taken is never reused",
          harnessBackupName("CLAUDE.md", on: day) { $0 == "CLAUDE.md.local-\(stamp)" }
              == "CLAUDE.md.local-\(stamp)-2")
    check("…and it keeps counting past the second",
          harnessBackupName("projects", on: day) { $0.hasSuffix(stamp) || $0.hasSuffix("-2") }
              == "projects.local-\(stamp)-3")

    // MARK: - A full account, shared

    let main = mainAccount("full-main")
    let lived = home("full-target")
    // A document of their own, which must survive as bytes somewhere.
    write("my own rules", lived.appendingPathComponent("CLAUDE.md"))
    // A tree of documents: NOT merged, because a skill of theirs and a skill of ours are two
    // authors' work and a machine picking between them writes a third thing nobody wrote.
    write("their skill", lived.appendingPathComponent("skills/mine/SKILL.md"))
    // An accumulating directory with one name that collides and two that do not.
    write("their one", lived.appendingPathComponent("projects/proj-a/one.jsonl"))
    write("their two", lived.appendingPathComponent("projects/proj-a/two.jsonl"))
    write("their three", lived.appendingPathComponent("projects/proj-b/three.jsonl"))
    // An accumulating directory where EVERY name collides: nothing moves, everything is kept.
    write("their index", lived.appendingPathComponent("memory/MEMORY.md"))

    let report = shareExistingHarness(providerID: "claude", mainHome: main, target: lived, now: day)

    check("an item the account did not have is simply linked",
          report.linked.contains("settings.json")
              && read(lived.appendingPathComponent("settings.json")) == "{}")
    check("a document of the user's own is renamed aside, not replaced",
          report.backups.contains { $0.item == "CLAUDE.md" && $0.name == "CLAUDE.md.local-\(stamp)" }
              && read(lived.appendingPathComponent("CLAUDE.md.local-\(stamp)")) == "my own rules")
    check("…and the main account's is what that name now reads",
          read(lived.appendingPathComponent("CLAUDE.md")) == "main rules")
    check("…through a link, so an edit in the main account reaches this one",
          (try? fm.destinationOfSymbolicLink(atPath: lived.appendingPathComponent("CLAUDE.md").path))
              == main.appendingPathComponent("CLAUDE.md").path)
    check("a tree of documents is moved aside whole rather than merged",
          report.backups.contains { $0.item == "skills" }
              && read(lived.appendingPathComponent("skills.local-\(stamp)/mine/SKILL.md"))
                  == "their skill")
    check("…and nothing of theirs is mixed into the main account's skills",
          !fm.fileExists(atPath: main.appendingPathComponent("skills/mine").path))

    // The merge, asserted on both sides of the move.
    var mergedProjects: (moved: Int, kept: Int, backup: String?)?
    for result in report.results {
        if result.item == "projects", case .merged(let moved, let kept, let backup) = result.outcome {
            mergedProjects = (moved, kept, backup)
        }
    }
    check("an accumulating directory reports what moved and what stayed",
          mergedProjects?.moved == 2 && mergedProjects?.kept == 1)
    check("…the files that did not collide are in the main account now",
          read(main.appendingPathComponent("projects/proj-a/two.jsonl")) == "their two"
              && read(main.appendingPathComponent("projects/proj-b/three.jsonl")) == "their three")
    check("…the main account's own file is the one that survives a collision",
          read(main.appendingPathComponent("projects/proj-a/one.jsonl")) == "main one")
    check("…and the colliding file is kept in the backup rather than dropped",
          read(lived.appendingPathComponent("projects.local-\(stamp)/proj-a/one.jsonl"))
              == "their one")
    check("…while the merged directory itself now reads through to the main account",
          read(lived.appendingPathComponent("projects/proj-a/two.jsonl")) == "their two")
    check("a directory where everything collides moves nothing and keeps everything",
          report.results.contains { $0.item == "memory" && $0.outcome == .merged(moved: 0, kept: 1,
              backup: "memory.local-\(stamp)") }
              && read(lived.appendingPathComponent("memory.local-\(stamp)/MEMORY.md"))
                  == "their index")
    check("the messages sessions leave each other are linked with the rest",
          report.linked.contains(inboxesItem)
              && read(lived.appendingPathComponent("inboxes/tally/note.md")) == "main note")
    check("the credential is on no share list, so it is never carried across",
          !fm.fileExists(atPath: lived.appendingPathComponent(".credentials.json").path))
    check("the conversation record reports as shared, which is what the privacy note is about",
          report.sharesConversations)
    check("nothing failed on a writable home", report.failed.isEmpty && report.changed)

    // Idempotence: the whole point of asking by resolution rather than by what this run did.
    let again = shareExistingHarness(providerID: "claude", mainHome: main, target: lived, now: day)
    check("a second run has nothing to do", !again.changed && again.failed.isEmpty)
    check("…and says so about every item it already shares",
          again.alreadyShared.contains("CLAUDE.md") && again.alreadyShared.contains("projects")
              && again.linked.isEmpty)
    check("…and makes no second backup",
          !fm.fileExists(atPath: lived.appendingPathComponent("CLAUDE.md.local-\(stamp)-2").path))

    // The reverse, which is the same function `--no-share` uses (SharedHarness.swift).
    let removed = unlinkSharedHarness(from: main, to: lived,
                                      items: harnessItems(for: "claude", in: main))
    check("unlinking takes the links away", removed.contains("CLAUDE.md")
              && !fm.fileExists(atPath: lived.appendingPathComponent("CLAUDE.md").path))
    check("…and leaves every backup exactly where it is",
          read(lived.appendingPathComponent("CLAUDE.md.local-\(stamp)")) == "my own rules"
              && read(lived.appendingPathComponent("projects.local-\(stamp)/proj-a/one.jsonl"))
                  == "their one")

    // MARK: - A merge with nothing in the way of it

    let cleanMain = mainAccount("clean-main")
    let clean = home("clean-target")
    write("only theirs", clean.appendingPathComponent("projects/proj-c/four.jsonl"))
    let cleanReport = shareExistingHarness(providerID: "claude", mainHome: cleanMain, target: clean,
                                           now: day)
    check("a merge that takes everything leaves no backup behind",
          cleanReport.results.contains { $0.item == "projects"
              && $0.outcome == .merged(moved: 1, kept: 0, backup: nil) }
              && !fm.fileExists(atPath: clean.appendingPathComponent("projects.local-\(stamp)").path))
    check("…and the emptied directory is a link to the main account's",
          read(cleanMain.appendingPathComponent("projects/proj-c/four.jsonl")) == "only theirs"
              && read(clean.appendingPathComponent("projects/proj-c/four.jsonl")) == "only theirs")

    // MARK: - Links that are already there

    let linkMain = mainAccount("link-main")
    let linked = home("link-target")
    // Somebody's own link, pointing somewhere else entirely: theirs, so it is moved aside like any
    // other thing of theirs rather than silently replaced.
    let elsewhere = root.appendingPathComponent("elsewhere.md")
    write("somewhere else", elsewhere)
    try? fm.createSymbolicLink(at: linked.appendingPathComponent("CLAUDE.md"),
                               withDestinationURL: elsewhere)
    // A link to nothing at all is still a thing that is there.
    try? fm.createSymbolicLink(at: linked.appendingPathComponent("settings.json"),
                               withDestinationURL: root.appendingPathComponent("gone.json"))
    // And a link already pointing at the main account, which is what an earlier share leaves.
    try? fm.createSymbolicLink(at: linked.appendingPathComponent("memory"),
                               withDestinationURL: linkMain.appendingPathComponent("memory"))
    let linkReport = shareExistingHarness(providerID: "claude", mainHome: linkMain, target: linked,
                                          now: day)
    check("a link of the user's own is moved aside, still pointing where they aimed it",
          linkReport.backups.contains { $0.item == "CLAUDE.md" }
              && (try? fm.destinationOfSymbolicLink(
                  atPath: linked.appendingPathComponent("CLAUDE.md.local-\(stamp)").path))
                  == elsewhere.path)
    check("a dangling link is something that is there, so it is kept too",
          linkReport.backups.contains { $0.item == "settings.json" })
    check("a link that already points at the main account is left alone",
          linkReport.alreadyShared.contains("memory")
              && !fm.fileExists(atPath: linked.appendingPathComponent("memory.local-\(stamp)").path))

    // MARK: - The home a share may not touch

    let selfReport = shareExistingHarness(providerID: "claude", mainHome: main, target: main,
                                          now: day)
    check("the main account cannot be shared with itself",
          selfReport.isMainHome && selfReport.results.isEmpty && !selfReport.changed)

    // MARK: - A home that cannot be written to

    let sealedMain = mainAccount("sealed-main")
    let sealed = home("sealed-target")
    write("theirs", sealed.appendingPathComponent("CLAUDE.md"))
    try? fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: sealed.path)
    let sealedReport = shareExistingHarness(providerID: "claude", mainHome: sealedMain,
                                            target: sealed, now: day)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sealed.path)
    check("a share that cannot happen is reported as one that did not",
          sealedReport.failed.contains("CLAUDE.md") && sealedReport.linked.isEmpty)
    check("…and the file it could not move is still theirs, unread and unmoved",
          read(sealed.appendingPathComponent("CLAUDE.md")) == "theirs")

    // MARK: - The codex face of the same act

    let codexMain = home("codex-main")
    write("codex instructions", codexMain.appendingPathComponent("AGENTS.md"))
    write("model = \"gpt\"", codexMain.appendingPathComponent("config.toml"))
    write("main rollout", codexMain.appendingPathComponent("sessions/2026/main.jsonl"))
    let codexTarget = home("codex-target")
    write("their instructions", codexTarget.appendingPathComponent("AGENTS.md"))
    write("their rollout", codexTarget.appendingPathComponent("sessions/2026/theirs.jsonl"))
    let codexReport = shareExistingHarness(providerID: "codex", mainHome: codexMain,
                                           target: codexTarget, now: day)
    check("codex documents are moved aside like claude's",
          codexReport.backups.contains { $0.item == "AGENTS.md" }
              && read(codexTarget.appendingPathComponent("AGENTS.md.local-\(stamp)"))
                  == "their instructions")
    check("codex config is linked where nothing was in the way",
          codexReport.linked.contains("config.toml"))
    // The conversation record is a conversation record whichever provider it belongs to: merged, so
    // that history is not shut away in a backup the app no longer reads.
    check("codex conversations merge rather than being shut away",
          read(codexMain.appendingPathComponent("sessions/2026/theirs.jsonl")) == "their rollout"
              && codexReport.results.contains { $0.item == "sessions"
                  && $0.outcome == .merged(moved: 1, kept: 0, backup: nil) })
    check("…and the codex share is only ever about codex's own names",
          !codexReport.results.contains { $0.item == inboxesItem })

    // MARK: - What the account list is asked afterwards

    let progressMain = mainAccount("progress-main")
    let untouched = home("progress-untouched")
    let full = home("progress-full")
    shareExistingHarness(providerID: "claude", mainHome: progressMain, target: full, now: day)
    let fullProgress = sharedHarnessProgress(providerID: "claude", mainHome: progressMain,
                                             target: full)
    let noneProgress = sharedHarnessProgress(providerID: "claude", mainHome: progressMain,
                                             target: untouched)
    check("a shared account counts every item the main account has",
          fullProgress.isComplete && fullProgress.total >= 5)
    check("an untouched account shares none of them",
          noneProgress.shared == 0 && noneProgress.total == fullProgress.total)
    check("the main account is not a target of its own",
          sharedHarnessProgress(providerID: "claude", mainHome: progressMain,
                                target: progressMain) == SharedHarnessProgress())
    check("a fleet where everyone shares everything is complete",
          sharedHarnessCoverage([fullProgress, fullProgress]) == .complete)
    check("a fleet where nobody shares anything is none",
          sharedHarnessCoverage([noneProgress, noneProgress]) == .none)
    check("one of each is the state worth pointing at",
          sharedHarnessCoverage([fullProgress, noneProgress]) == .partial)
    check("…as is one account that is half-way there",
          sharedHarnessCoverage([SharedHarnessProgress(shared: 3, total: 7)]) == .partial)
    check("no accounts at all is nothing to report", sharedHarnessCoverage([]) == .none)

    // MARK: - The inbox that has to exist before it can be linked

    let freshMain = home("fresh-main")
    write("rules", freshMain.appendingPathComponent("CLAUDE.md"))
    let freshTarget = home("fresh-target")
    let freshReport = shareExistingHarness(providerID: "claude", mainHome: freshMain,
                                           target: freshTarget, now: day)
    check("a main account with no inbox yet gets one, so the fleet can share it",
          freshReport.linked.contains(inboxesItem)
              && fm.fileExists(atPath: freshMain.appendingPathComponent(inboxesItem).path))

    // MARK: - Which items are merged, and which are documents

    check("the merged set is the accumulating directories and only those",
          mergeableHarnessItems.contains("projects") && mergeableHarnessItems.contains("memory")
              && mergeableHarnessItems.contains(inboxesItem)
              && mergeableHarnessItems.contains("sessions")
              && !mergeableHarnessItems.contains("skills")
              && !mergeableHarnessItems.contains("settings.json"))

    // MARK: - One implementation, three surfaces

    // The CLI, the Settings row and this suite all go through the one engine. A second copy is what
    // would let one surface share a set another does not, and no type check would see it.
    let cliSource = (try? String(contentsOfFile: "TallyCLI/ShareCommand.swift",
                                 encoding: .utf8)) ?? ""
    let rowSource = (try? String(contentsOfFile: "Tally/Stores/IntegrationsSharedHarness.swift",
                                 encoding: .utf8)) ?? ""
    check("both call sites are readable from this suite", !cliSource.isEmpty && !rowSource.isEmpty)
    check("the CLI delegates the share", cliSource.contains("shareExistingHarness("))
    check("the Settings row delegates the same one", rowSource.contains("shareExistingHarness("))
    check("neither keeps a second copy of the rule",
          !cliSource.contains("createSymbolicLink") && !rowSource.contains("createSymbolicLink")
              && !cliSource.contains("moveItem") && !rowSource.contains("moveItem"))
    check("and the reverse is the one the add flow already had",
          rowSource.contains("unlinkSharedHarness(") && !rowSource.contains("removeItem"))
}
