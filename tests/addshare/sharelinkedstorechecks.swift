import Foundation

// A conversation store reached through a LINK (jettoai/tally#9), and the two rules that keep a share
// from splitting a history: nothing moves under a running session, and a copy that is set aside is
// named to whoever asked.
//
// `projects -> /elsewhere/store` is the account's history kept somewhere else. The share used to
// rename the link aside and point `projects` at the main account's near-empty folder, so a relaunch
// could not resume and the transcripts lived in two stores. Now the store is merged INTO the main
// account's item like a real directory, the link is renamed aside (still pointing at the store, so
// whatever collided stays reachable), and the store itself is never removed.
//
// Also holds the "links that are already there" rows, split out of shareexistingchecks.swift at the
// 500-line cap. Runs as a function main.swift calls, which owns the shared harness (`check`).

func runShareLinkedStoreChecks(root: URL) {
    let fm = FileManager.default
    let day = fixtureDay, stamp = fixtureStamp
    func write(_ text: String, _ url: URL) { writeFixture(text, url) }
    func read(_ url: URL) -> String? { readFixture(url) }
    func home(_ name: String) -> URL { fixtureHome(name, in: root) }
    func mainAccount(_ name: String) -> URL { fixtureMainAccount(name, in: root) }
    func destination(_ url: URL) -> String? { try? fm.destinationOfSymbolicLink(atPath: url.path) }
    func exists(_ url: URL) -> Bool { (try? fm.attributesOfItem(atPath: url.path)) != nil }
    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
    func fileCount(_ url: URL) -> Int {
        (fm.enumerator(atPath: url.path)?.allObjects as? [String] ?? []).filter {
            (try? fm.attributesOfItem(atPath: url.appendingPathComponent($0).path))?[.type]
                as? FileAttributeType == .typeRegular
        }.count
    }
    func link(_ at: URL, to target: URL) {
        try? fm.createSymbolicLink(at: at, withDestinationURL: target)
    }
    /// A store outside every home, with the three shapes a merge has to tell apart.
    func store(_ name: String) -> URL {
        let s = root.appendingPathComponent(name)
        write("their one", s.appendingPathComponent("proj-a/one.jsonl"))
        write("their two", s.appendingPathComponent("proj-a/two.jsonl"))
        write("their new", s.appendingPathComponent("proj-z/new.jsonl"))
        return s
    }

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

    // MARK: - A link to a conversation store is the store

    let m1 = mainAccount("ls-main-1"), t1 = home("ls-target-1"), s1 = store("ls-store-1")
    link(t1.appendingPathComponent("projects"), to: s1)
    let r1 = shareExistingHarness(providerID: "claude", mainHome: m1, target: t1,
                                  items: ["projects"], now: day)
    check("a linked store is merged into the main account, the colliding file kept",
          r1.results.first?.outcome == .merged(moved: 2, kept: 1, backup: "projects.local-\(stamp)"))
    check("…its files are in the main account under their own names",
          read(m1.appendingPathComponent("projects/proj-a/two.jsonl")) == "their two"
              && read(m1.appendingPathComponent("projects/proj-z/new.jsonl")) == "their new"
              && read(m1.appendingPathComponent("projects/proj-a/one.jsonl")) == "main one")
    check("…the account's projects is now the main account's",
          destination(t1.appendingPathComponent("projects")) == m1.appendingPathComponent("projects").path)
    check("…and the old link is kept aside, still pointing at the store, with the collided file",
          destination(t1.appendingPathComponent("projects.local-\(stamp)")) == s1.path
              && read(t1.appendingPathComponent("projects.local-\(stamp)/proj-a/one.jsonl")) == "their one")

    let r1b = shareExistingHarness(providerID: "claude", mainHome: m1, target: t1,
                                   items: ["projects"], now: day)
    check("a second run changes nothing",
          !r1b.changed && r1b.alreadyShared.contains("projects")
              && !exists(t1.appendingPathComponent("projects.local-\(stamp)-2")))

    // Everything moved: the store keeps its (now empty) directories, because they are not in the
    // home being shared and nothing here may remove them through the link.
    let m3 = mainAccount("ls-main-3"), t3 = home("ls-target-3")
    let s3 = root.appendingPathComponent("ls-store-3")
    write("their two", s3.appendingPathComponent("proj-a/two.jsonl"))
    link(t3.appendingPathComponent("projects"), to: s3)
    let r3 = shareExistingHarness(providerID: "claude", mainHome: m3, target: t3,
                                  items: ["projects"], now: day)
    check("a store that is emptied is not removed or stripped of its directories",
          isDirectory(s3) && isDirectory(s3.appendingPathComponent("proj-a"))
              && read(m3.appendingPathComponent("projects/proj-a/two.jsonl")) == "their two")
    check("…and the link is still kept aside", r3.backups.contains { $0.item == "projects" })

    // Two homes whose links lead to one store.
    let m4 = mainAccount("ls-main-4"), b4 = home("ls-target-4b"), c4 = home("ls-target-4c")
    let s4 = store("ls-store-4")
    write("their y", s4.appendingPathComponent("proj-y/y.jsonl"))
    let before4 = fileCount(m4.appendingPathComponent("projects")) + fileCount(s4)
    link(b4.appendingPathComponent("projects"), to: s4)
    link(c4.appendingPathComponent("projects"), to: s4)
    _ = shareExistingHarness(providerID: "claude", mainHome: m4, target: b4,
                             items: ["projects"], now: day)
    let r4c = shareExistingHarness(providerID: "claude", mainHome: m4, target: c4,
                                   items: ["projects"], now: day)
    check("the second home finds nothing left to move and keeps its link aside too",
          r4c.results.first?.outcome == .merged(moved: 0, kept: 1, backup: "projects.local-\(stamp)"))
    let rels4 = ["proj-a/one.jsonl", "proj-a/two.jsonl", "proj-z/new.jsonl", "proj-y/y.jsonl"]
    let originals4 = ["their one", "their two", "their new", "their y"]
    check("every file of the store is still readable, from the main account or a kept link",
          zip(rels4, originals4).allSatisfy { rel, text in
              read(m4.appendingPathComponent("projects/\(rel)")) == text
                  || ["b", "c"].allSatisfy { which in
                      read(home("ls-target-4\(which)")
                          .appendingPathComponent("projects.local-\(stamp)/\(rel)")) == text }
          })
    check("…none was lost or duplicated",
          fileCount(m4.appendingPathComponent("projects")) + fileCount(s4) == before4)
    check("…and both homes now read the main account's projects",
          destination(b4.appendingPathComponent("projects")) == m4.appendingPathComponent("projects").path
              && destination(c4.appendingPathComponent("projects")) == m4.appendingPathComponent("projects").path)

    // A store on another volume: a move would be a copy and a delete.
    // The VM volume's mount point: a root-owned directory another user cannot move anything out of,
    // so even a share that wrongly followed it would change nothing on this machine.
    let otherVolume = URL(fileURLWithPath: "/System/Volumes/VM")
    let m5 = mainAccount("ls-main-5"), t5 = home("ls-target-5")
    let premise5 = isDirectory(otherVolume)
        && fileIdentity(atPath: otherVolume.path)?.device != fileIdentity(atPath: root.path)?.device
    check("premise: a directory on another volume exists to test with", premise5)
    if premise5 {
        link(t5.appendingPathComponent("projects"), to: otherVolume)
        let r5 = shareExistingHarness(providerID: "claude", mainHome: m5, target: t5,
                                      items: ["projects"], now: day)
        var failedHere = false
        if case .failed? = r5.results.first?.outcome { failedHere = true }
        check("a store on another volume is refused and nothing is changed",
              failedHere && destination(t5.appendingPathComponent("projects")) == otherVolume.path
                  && !exists(t5.appendingPathComponent("projects.local-\(stamp)"))
                  && fileCount(m5.appendingPathComponent("projects")) == 1)
    }

    // A link to the main account's own folder would move its instructions into its own history.
    let m6 = mainAccount("ls-main-6"), t6 = home("ls-target-6")
    link(t6.appendingPathComponent("projects"), to: m6)
    let r6 = shareExistingHarness(providerID: "claude", mainHome: m6, target: t6,
                                  items: ["projects"], now: day)
    var failed6 = false
    if case .failed? = r6.results.first?.outcome { failed6 = true }
    check("a link into the main account's own files is refused",
          failed6 && read(m6.appendingPathComponent("CLAUDE.md")) == "main rules"
              && !exists(m6.appendingPathComponent("projects/CLAUDE.md"))
              && destination(t6.appendingPathComponent("projects")) == m6.path)

    // Only a directory is followed, and only for the accumulating items.
    let m7 = mainAccount("ls-main-7"), t7 = home("ls-target-7")
    let file7 = root.appendingPathComponent("ls-afile")
    write("just a file", file7)
    link(t7.appendingPathComponent("projects"), to: file7)
    let r7 = shareExistingHarness(providerID: "claude", mainHome: m7, target: t7,
                                  items: ["projects"], now: day)
    check("a link to a plain file is renamed aside as before",
          r7.results.first?.outcome == .backedUp("projects.local-\(stamp)"))
    let m8 = mainAccount("ls-main-8"), t8 = home("ls-target-8")
    let dir8 = root.appendingPathComponent("ls-skills-store")
    write("their skill", dir8.appendingPathComponent("mine/SKILL.md"))
    link(t8.appendingPathComponent("skills"), to: dir8)
    write("x", root.appendingPathComponent("ls-other.json"))
    link(t8.appendingPathComponent("settings.json"), to: root.appendingPathComponent("ls-other.json"))
    let r8 = shareExistingHarness(providerID: "claude", mainHome: m8, target: t8,
                                  items: ["skills", "settings.json"], now: day)
    check("a document linked elsewhere is a document: renamed aside whole, never merged",
          r8.results.map(\.outcome) == [.backedUp("skills.local-\(stamp)"),
                                        .backedUp("settings.json.local-\(stamp)")]
              && !exists(m8.appendingPathComponent("skills/mine/SKILL.md"))
              && read(m8.appendingPathComponent("settings.json")) == "{}")

    // MARK: - Nothing is shared under a running session

    let two = [URL(fileURLWithPath: "/h/.claude2"), URL(fileURLWithPath: "/h/.claude3")]
    check("an unreadable registry is read as busy",
          shareLiveBlock(providerID: "claude", homes: two, liveCounts: nil) == .unknown)
    check("a session on one of the homes names that home",
          shareLiveBlock(providerID: "claude", homes: two, liveCounts: ["claude:.claude2": 1])
              == .live([".claude2"]))
    check("a session on another provider or another home is not in the way",
          shareLiveBlock(providerID: "claude", homes: [two[0]],
                         liveCounts: ["claude:.claude": 2, "codex:.claude2": 1]) == .clear)
    check("nothing to share is never blocked, whatever the registry says",
          shareLiveBlock(providerID: "claude", homes: [], liveCounts: nil) == .clear)

    // MARK: - What was set aside is named

    let m9 = mainAccount("ls-main-9"), t9 = home("ls-target-9")
    write("my own rules", t9.appendingPathComponent("CLAUDE.md"))
    write("their skill", t9.appendingPathComponent("skills/mine/SKILL.md"))
    write("their one", t9.appendingPathComponent("projects/proj-a/one.jsonl"))
    let r9 = shareExistingHarness(providerID: "claude", mainHome: m9, target: t9, now: day)
    let kept9 = r9.keptDocuments.map(\.item)
    check("the copies kept whole are listed, the directories merged are not",
          kept9.contains("CLAUDE.md") && kept9.contains("skills")
              && !kept9.contains("projects") && r9.backups.contains { $0.item == "projects" })

    // MARK: - Both surfaces ask

    let cliSrc = (try? String(contentsOfFile: "TallyCLI/ShareCommand.swift", encoding: .utf8)) ?? ""
    let rowSrc = (try? String(contentsOfFile: "Tally/Stores/IntegrationsSharedHarness.swift",
                              encoding: .utf8)) ?? ""
    check("the Settings row reads the registry, gates on it and names the copies kept",
          rowSrc.contains("liveSessionCounts(") && rowSrc.contains("shareLiveBlock(")
              && rowSrc.contains("keptDocuments"))
    check("the CLI gates on the same rule",
          cliSrc.contains("shareLiveBlock(") && cliSrc.contains("liveCounts()"))
    check("neither surface links or moves anything itself",
          !cliSrc.contains("createSymbolicLink") && !rowSrc.contains("createSymbolicLink")
              && !cliSrc.contains("moveItem") && !rowSrc.contains("moveItem"))
}
