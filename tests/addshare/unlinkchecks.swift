import Foundation

// Taking a share BACK (Tally/Core/SharedHarness.swift: unlinkSharedHarness), which is what
// `--no-share` does when an aborted login left a home behind and what Settings' Remove does.
//
// Split out of shareexistingchecks.swift (2026-08-14) when that file reached its 500-line cap. The
// seam is the direction: the file next door is about what a share MOVES, merges and renames aside,
// and every row here is about one question asked afterwards - is this link one of OURS, whatever
// spelling it was written in. That question has its own suite because it has its own history: four
// fixes in three days, each teaching the comparison one more way to spell the same path.
//
// Runs as a function main.swift calls, which owns the shared harness (`check`).

func runUnlinkChecks(root: URL) {
    let fm = FileManager.default
    // The account shapes live in harnessfixtures.swift, shared with the suite next door.
    func write(_ text: String, _ url: URL) { writeFixture(text, url) }
    func read(_ url: URL) -> String? { readFixture(url) }
    func home(_ name: String) -> URL { fixtureHome(name, in: root) }
    func mainAccount(_ name: String) -> URL { fixtureMainAccount(name, in: root) }
    // The row that has to explain a refusal, read as text: the suite next door reads the same file
    // for what it delegates, this one for what it says when the act comes to nothing.
    let rowSource = (try? String(contentsOfFile: "Tally/Stores/IntegrationsSharedHarness.swift",
                                 encoding: .utf8)) ?? ""

    // MARK: - Taking the links back, however they were written

    // Remove (Settings) and `--no-share` (the add flow) are this one function, and it has to answer
    // the same question the detectors answer: a link that RESOLVES to the main account's item is
    // shared, whether it was written as an absolute path, a relative one, or through another link.
    // Comparing the link's text instead left the row saying "Installed" with a Remove button that
    // did nothing, for good (codex, 2026-08-13).
    let unlinkMain = mainAccount("unlink-main")
    let relative = home("unlink-relative")
    // Exactly what a hand-made share looks like: `projects -> ../unlink-main/projects`.
    try? fm.createSymbolicLink(atPath: relative.appendingPathComponent("projects").path,
                               withDestinationPath: "../unlink-main/projects")
    // And one wired through a link to the home itself, which is the other way to write it.
    let unlinkAlias = root.appendingPathComponent("unlink-main-alias")
    try? fm.createSymbolicLink(at: unlinkAlias, withDestinationURL: unlinkMain)
    try? fm.createSymbolicLink(at: relative.appendingPathComponent("memory"),
                               withDestinationURL: unlinkAlias.appendingPathComponent("memory"))
    let elsewhereDir = home("unlink-elsewhere")
    try? fm.createSymbolicLink(at: relative.appendingPathComponent("skills"),
                               withDestinationURL: elsewhereDir)
    check("the premise: a relative link reads as shared on the way in",
          sharesConversations(providerID: "claude", source: unlinkMain, target: relative))
    let relativeRemoved = unlinkSharedHarness(from: unlinkMain, to: relative,
                                              items: harnessItems(for: "claude", in: unlinkMain))
    check("a relative link to the main account is one of ours, and is taken back",
          relativeRemoved.contains("projects")
              && !fm.fileExists(atPath: relative.appendingPathComponent("projects").path))
    check("…and so is one wired through another link",
          relativeRemoved.contains("memory")
              && !fm.fileExists(atPath: relative.appendingPathComponent("memory").path))
    check("…while a link aimed anywhere else is still none of our business",
          !relativeRemoved.contains("skills")
              && (try? fm.destinationOfSymbolicLink(
                  atPath: relative.appendingPathComponent("skills").path)) == elsewhereDir.path)
    check("…and what they pointed AT is untouched, because only links are ever removed",
          read(unlinkMain.appendingPathComponent("projects/proj-a/one.jsonl")) == "main one")
    // The case resolution alone cannot answer, and the reason the link's text is still read: an
    // item the main account no longer has resolves to nothing, and `--no-share` still has to be
    // able to take our link to it back.
    let danglingHome = home("unlink-dangling")
    try? fm.createSymbolicLink(at: danglingHome.appendingPathComponent("hooks"),
                               withDestinationURL: unlinkMain.appendingPathComponent("hooks"))
    check("a link to an item the main account no longer has is still ours to remove",
          !fm.fileExists(atPath: unlinkMain.appendingPathComponent("hooks").path)
              && unlinkSharedHarness(from: unlinkMain, to: danglingHome,
                                     items: sharedHarnessItems).contains("hooks"))
    // …and the same link written the way a hand-made share writes it. Comparing the text
    // LITERALLY only ever recognised the absolute spelling, so a relative link to an item the main
    // account did not have yet was left behind by both `--no-share` and Settings' Remove - and the
    // day that item appeared, the share it was supposed to have taken back came back to life on its
    // own (codex, 2026-08-14).
    let danglingRelative = home("unlink-dangling-relative")
    try? fm.createSymbolicLink(atPath: danglingRelative.appendingPathComponent("agents").path,
                               withDestinationPath: "../unlink-main/agents")
    // The other spelling of "somewhere else", so this cannot be satisfied by expanding blindly.
    try? fm.createSymbolicLink(atPath: danglingRelative.appendingPathComponent("hooks").path,
                               withDestinationPath: "../unlink-elsewhere/hooks")
    check("the premise: neither end of a relative link to a missing item exists to resolve",
          !fm.fileExists(atPath: unlinkMain.appendingPathComponent("agents").path)
              && !fm.fileExists(atPath: danglingRelative.appendingPathComponent("agents").path))
    let danglingRelativeRemoved = unlinkSharedHarness(from: unlinkMain, to: danglingRelative,
                                                      items: sharedHarnessItems)
    check("a RELATIVE link to an item the main account no longer has is ours too",
          danglingRelativeRemoved.contains("agents")
              && (try? fm.destinationOfSymbolicLink(
                  atPath: danglingRelative.appendingPathComponent("agents").path)) == nil)
    check("…while a relative link aimed elsewhere is left exactly where it is",
          !danglingRelativeRemoved.contains("hooks")
              && (try? fm.destinationOfSymbolicLink(
                  atPath: danglingRelative.appendingPathComponent("hooks").path))
                  == "../unlink-elsewhere/hooks")

    // MARK: - A link's text is WALKED, not collapsed

    // `..` means the parent of wherever the walk has ARRIVED, so a `..` that follows a symlink does
    // not cancel it out. Reading the text as if it did (which is what standardizing it, and what
    // resolving a path that does not exist, both do) gets both directions wrong, and the assertions
    // below are the kernel's own answer to the same two texts (codex, 2026-08-14).
    let walkMain = mainAccount("walk-main")
    let walkTarget = home("walk-target")
    // `walk-away -> walk-elsewhere/deep`, so `../walk-away/../walk-main` is a walk-main of the
    // user's OWN inside walk-elsewhere, and collapsing the text lands on the real one instead.
    write("not the main account",
          root.appendingPathComponent("walk-elsewhere/walk-main/agents/who.txt"))
    try? fm.createDirectory(at: root.appendingPathComponent("walk-elsewhere/deep"),
                            withIntermediateDirectories: true)
    try? fm.createSymbolicLink(atPath: root.appendingPathComponent("walk-away").path,
                               withDestinationPath: "walk-elsewhere/deep")
    try? fm.createSymbolicLink(atPath: walkTarget.appendingPathComponent("agents").path,
                               withDestinationPath: "../walk-away/../walk-main/agents")
    // The same text with nothing at the end of it. Reading the path as a whole (which is what
    // standardizing it does) walks it properly while every component EXISTS and collapses it the
    // moment one does not, so this shape - the dangling one, which is the shape this whole
    // comparison is here for - is where the collapsed reading claims a link of the user's.
    try? fm.createSymbolicLink(atPath: walkTarget.appendingPathComponent("commands").path,
                               withDestinationPath: "../walk-away/../walk-main/commands")
    // The same shape pointing the other way: `walk-hop/alias -> ../walk-main`, where the collapsed
    // text (`walk-hop/walk-main/…`) is nowhere at all and the walk lands on the main account.
    try? fm.createDirectory(at: root.appendingPathComponent("walk-hop"),
                            withIntermediateDirectories: true)
    try? fm.createSymbolicLink(atPath: root.appendingPathComponent("walk-hop/alias").path,
                               withDestinationPath: "../walk-main")
    try? fm.createSymbolicLink(atPath: walkTarget.appendingPathComponent("projects").path,
                               withDestinationPath: "../walk-hop/alias/../walk-main/projects")
    try? fm.createSymbolicLink(atPath: walkTarget.appendingPathComponent("hooks").path,
                               withDestinationPath: "../walk-hop/alias/../walk-main/hooks")
    check("the premise: the away text leads to the user's files, whatever collapsing it suggests",
          read(walkTarget.appendingPathComponent("agents/who.txt")) == "not the main account")
    check("the premise: the hop text leads to the main account's, though collapsing it leads nowhere",
          read(walkTarget.appendingPathComponent("projects/proj-a/one.jsonl")) == "main one"
              && !fm.fileExists(atPath: root.appendingPathComponent("walk-hop/walk-main").path))
    let walked = unlinkSharedHarness(from: walkMain, to: walkTarget, items: sharedHarnessItems)
    check("a link whose walk leaves the main account is the user's, and stays",
          !walked.contains("agents")
              && read(walkTarget.appendingPathComponent("agents/who.txt")) == "not the main account")
    check("…dangling included, which is where reading the path as a whole starts guessing",
          !walked.contains("commands")
              && (try? fm.destinationOfSymbolicLink(
                  atPath: walkTarget.appendingPathComponent("commands").path))
                  == "../walk-away/../walk-main/commands")
    check("…while one whose walk arrives at the main account is ours, and goes",
          walked.contains("projects")
              && !fm.fileExists(atPath: walkTarget.appendingPathComponent("projects").path))
    // Only the text can answer this one: nothing exists at either end for resolution to compare.
    check("…dangling included, which is the half only the text can answer",
          walked.contains("hooks")
              && !fm.fileExists(atPath: walkMain.appendingPathComponent("hooks").path)
              && (try? fm.destinationOfSymbolicLink(
                  atPath: walkTarget.appendingPathComponent("hooks").path)) == nil)
    check("…and what the one we kept points AT is untouched",
          read(root.appendingPathComponent("walk-elsewhere/walk-main/agents/who.txt"))
              == "not the main account")
    // A text that cannot be walked leads nowhere, which is not the same place as the main account:
    // `walk-ghost` does not exist, so where `walk-ghost/..` would go is unknown, not `root`.
    try? fm.createSymbolicLink(atPath: walkTarget.appendingPathComponent("memory").path,
                               withDestinationPath: "../walk-ghost/../walk-main/memory")
    check("a text that cannot be walked is nobody's, and is left alone",
          !unlinkSharedHarness(from: walkMain, to: walkTarget,
                               items: sharedHarnessItems).contains("memory")
              && (try? fm.destinationOfSymbolicLink(
                  atPath: walkTarget.appendingPathComponent("memory").path)) != nil)
    // MARK: - The spellings that hide the item at the end

    // `hooks/.` and `hooks/` are `hooks`. Reading the last component off the text as written makes
    // the first one `.` and the second one nothing, which buries the item itself in the part that
    // gets walked - and for a DANGLING link that part is exactly the part that cannot be walked, so
    // the link stayed behind and `--no-share` quietly meant nothing (codex, 2026-08-14).
    let dotTarget = home("walk-dot-target")
    try? fm.createSymbolicLink(atPath: dotTarget.appendingPathComponent("plugins").path,
                               withDestinationPath: "../walk-main/plugins/.")
    try? fm.createSymbolicLink(atPath: dotTarget.appendingPathComponent("commands").path,
                               withDestinationPath: "../walk-main/commands/")
    try? fm.createSymbolicLink(atPath: dotTarget.appendingPathComponent("agents").path,
                               withDestinationPath: "../walk-main/agents/././")
    // The same spelling aimed away: trimming the tail may not turn a link of the user's into ours.
    try? fm.createSymbolicLink(atPath: dotTarget.appendingPathComponent("settings.local.json").path,
                               withDestinationPath:
                                   "../walk-away/../walk-main/settings.local.json/.")
    check("the premise: the main account has neither of the dangling ones",
          !fm.fileExists(atPath: walkMain.appendingPathComponent("plugins").path)
              && !fm.fileExists(atPath: walkMain.appendingPathComponent("commands").path))
    let dotted = unlinkSharedHarness(from: walkMain, to: dotTarget, items: sharedHarnessItems)
    check("a dangling link written as `item/.` is ours, and is taken back",
          dotted.contains("plugins")
              && !fm.fileExists(atPath: dotTarget.appendingPathComponent("plugins").path))
    check("…as is one written with a trailing slash",
          dotted.contains("commands"))
    check("…and one that stacks them, which is the same item said three times",
          dotted.contains("agents"))
    check("…while the same spelling aimed elsewhere is still the user's",
          !dotted.contains("settings.local.json")
              && (try? fm.destinationOfSymbolicLink(
                  atPath: dotTarget.appendingPathComponent("settings.local.json").path))
                  == "../walk-away/../walk-main/settings.local.json/.")

    // Both ends unwalkable is the same answer twice, and must not read as agreement.
    let goneMain = root.appendingPathComponent("walk-gone-main")
    let goneTarget = home("walk-gone-target")
    try? fm.createSymbolicLink(atPath: goneTarget.appendingPathComponent("hooks").path,
                               withDestinationPath: "../walk-gone-main/hooks")
    check("a main account that is not there has nothing to take back",
          !fm.fileExists(atPath: goneMain.path)
              && unlinkSharedHarness(from: goneMain, to: goneTarget,
                                     items: sharedHarnessItems).isEmpty
              && (try? fm.destinationOfSymbolicLink(
                  atPath: goneTarget.appendingPathComponent("hooks").path)) != nil)

    // MARK: - The two homes that are one home

    // A share is undone by removing the link the TARGET holds. When the target home is a link to
    // the main home (`~/.claude2 -> ~/.claude`, which is how a machine ends up with one harness
    // under two names), every path this walks lands inside the MAIN account: what is lstat'd at
    // `target/<item>` is the main account's own entry, and it leads where the main item leads
    // because it IS the main item. Removing it deletes the main account's harness (codex,
    // 2026-08-14). Nothing is shared with itself, so the whole call is refused.
    let selfMain = mainAccount("self-main")
    // The shape that makes it reachable: an allowlisted item of the main account that is itself a
    // link, since only links are ever removed.
    let realHooks = home("self-real-hooks")
    write("hook body", realHooks.appendingPathComponent("run.sh"))
    try? fm.createSymbolicLink(at: selfMain.appendingPathComponent("hooks"),
                               withDestinationURL: realHooks)
    let selfAlias = root.appendingPathComponent("self-main-alias")
    try? fm.createSymbolicLink(at: selfAlias, withDestinationURL: selfMain)
    check("the premise: the alias's items resolve to the main account's own",
          selfAlias.appendingPathComponent("hooks").resolvingSymlinksInPath().path
              == selfMain.appendingPathComponent("hooks").resolvingSymlinksInPath().path)
    let selfRemoved = unlinkSharedHarness(from: selfMain, to: selfAlias, items: sharedHarnessItems)
    check("a home that IS the main home has nothing of ours to take back",
          selfRemoved.isEmpty)
    check("…and the main account's own link is still there, pointing where it did",
          (try? fm.destinationOfSymbolicLink(
              atPath: selfMain.appendingPathComponent("hooks").path)) == realHooks.path
              && read(selfMain.appendingPathComponent("hooks/run.sh")) == "hook body")
    check("…as is everything else it holds",
          read(selfMain.appendingPathComponent("CLAUDE.md")) == "main rules"
              && read(selfMain.appendingPathComponent("projects/proj-a/one.jsonl")) == "main one")
    // The refusal is one fact, asked by the act and by the surfaces that have to explain it. Named
    // so a Remove that does nothing can say WHY rather than looking broken.
    check("one home under two names is one home, whichever name is asked first",
          harnessHomesAreOne(selfMain, selfAlias) && harnessHomesAreOne(selfAlias, selfMain))
    check("…and two homes are still two, alias or no alias",
          !harnessHomesAreOne(selfMain, walkTarget)
              && !harnessHomesAreOne(selfMain, root.appendingPathComponent("walk-away")))

    // MARK: - Every spelling the grammar allows, one cell at a time

    // The rows above are the four bugs this comparison has had, each written the way it was found.
    // This is the same question asked from the other end: the SET of spellings POSIX allows for one
    // path, enumerated off the grammar rather than off the cases anybody thought of - because every
    // one of those four WAS a case nobody had thought of, and a fifth is free to exist for as long
    // as the population being drawn from is "the ones we came up with". Three axes cross here: what
    // leads UP to the item
    // (walked by the kernel), how the item itself is spelled at the END (the part no walk can answer
    // for a link that dangles), and whether either end exists at all. Each cell carries its
    // coordinates, so a failure names the rule of the grammar it broke rather than a fixture.
    //
    // The axes are swept one at a time against a fixed base rather than as one product. The product
    // is thousands of cells that differ from a swept one in nothing the code can see: the lead-in is
    // one stat and the leaf is one string comparison, and neither reads the other. What a product
    // would buy over this is COUPLING between axes, and the two couplings that exist are swept as
    // axes of their own below - a slash at the end meaning one thing for a directory and another for
    // a file, and which existence state decides which half of the comparison answers.

    enum Verdict { case remove, keep }
    struct Cell {
        let coord: String, item: String, text: String, rule: String
        let verdict: Verdict
    }

    let corpus = home("corpus")
    let corpusMain = mainAccount("corpus/main")
    let corpusPath = corpus.path
    // A main account of the USER'S OWN, under the same name and holding the same items: a cell that
    // keeps a link has to be keeping something real, or it only asserts that nothing exists.
    write("theirs", corpus.appendingPathComponent("elsewhere/main/skills/theirs.txt"))
    write("theirs", corpus.appendingPathComponent("elsewhere/main/agents/theirs.txt"))
    for directory in ["elsewhere/deep", "hop", "relay"] {
        try? fm.createDirectory(at: corpus.appendingPathComponent(directory),
                                withIntermediateDirectories: true)
    }
    for (name, destination) in [("away", "elsewhere/deep"), ("hop/alias", "../main"),
                                ("main-alias", "main"), ("chain", "main-alias")] {
        try? fm.createSymbolicLink(atPath: corpus.appendingPathComponent(name).path,
                                   withDestinationPath: destination)
    }
    try? fm.createSymbolicLink(at: corpus.appendingPathComponent("relay/skills"),
                               withDestinationURL: corpusMain.appendingPathComponent("skills"))
    // An allowlisted item of the MAIN account that is itself a link, since only links are ever
    // removed: this is the shape the "one home under two names" cells would destroy if the refusal
    // were not there, so it has to exist for those cells to be asserting anything.
    let corpusHooks = home("corpus/real-hooks")
    write("hook body", corpusHooks.appendingPathComponent("run.sh"))
    try? fm.createSymbolicLink(at: corpusMain.appendingPathComponent("hooks"),
                               withDestinationURL: corpusHooks)

    /// What leads up to the item, in every shape the grammar allows, written absolute (A1) or
    /// relative to the home the link sits in (A2).
    func leadIn(_ axis: String, _ form: String) -> String {
        let base = form == "A1" ? corpusPath : "../.."
        switch axis {
        case "C2": return base + "/./main"              // a `.` mid-path
        case "C3": return base + "/elsewhere/../main"   // `..` off a real directory
        case "C4": return base + "/away/../main"        // `..` off a symlink, aimed AWAY
        case "C5": return base + "/hop/alias/../main"   // `..` off a symlink, hopping BACK
        case "C6": return base + "/chain"               // a chain of links to the home
        case "C7": return base + "//main"               // a doubled separator
        case "C8": return base + "/ghost/../main"       // through a component that is not there
        case "C9": return base + "/main-alias"          // the home under another name
        default: return base + "/main"                  // C1, plain
        }
    }

    var cells: [Cell] = []
    // How the item is spelled at the end. `item/`, `item/.` and `item/././.` all NAME the item, so
    // a link written any of those ways is the same link; `item/..` and a text that strips to
    // nothing name something else entirely, and never an item on the list.
    let leafForms: [(String, String, Verdict, String)] = [
        ("B1", "", .remove, "1"), ("B2", "/", .remove, "7"), ("B3", "//", .remove, "7"),
        ("B4", "/.", .remove, "7"), ("B5", "/./", .remove, "7"), ("B6", "/././.", .remove, "7"),
        ("B8", "/..", .keep, "9"), ("B9", "-not-an-item", .keep, "10"),
    ]
    let leadInForms: [(String, Verdict, String)] = [
        ("C2", .remove, "1"), ("C3", .remove, "1"), ("C4", .keep, "3"), ("C5", .remove, "4"),
        ("C6", .remove, "1"), ("C7", .remove, "1"), ("C8", .keep, "5"), ("C9", .remove, "1"),
    ]
    for form in ["A1", "A2"] {
        for state in ["D1", "D2"] {
            // D1 the main account still HAS the item, D2 it no longer does - which is the state
            // that decides whether resolution can answer at all, or only the text can.
            let item = state == "D1" ? "skills" : "agents"
            for (leaf, tail, verdict, rule) in leafForms {
                cells.append(Cell(coord: "\(form)×\(leaf)×C1×\(state)", item: item,
                                  text: "\(leadIn("C1", form))/\(item)\(tail)", rule: rule,
                                  verdict: verdict))
            }
            // A text that strips to nothing names the root, or the directory the link sits in -
            // never an item, however the stripping is written.
            cells.append(Cell(coord: "\(form)×B7×C1×\(state)", item: item,
                              text: form == "A1" ? "/." : "./.", rule: "9", verdict: .keep))
            for (lead, verdict, rule) in leadInForms {
                cells.append(Cell(coord: "\(form)×B1×\(lead)×\(state)", item: item,
                                  text: "\(leadIn(lead, form))/\(item)", rule: rule,
                                  verdict: verdict))
            }
        }
    }
    // The coupling between the two: a trailing slash asks for a DIRECTORY, so on a file it names
    // nothing the kernel will ever open - which makes it a link nothing of ours ever wrote, whether
    // or not the main account still has the file to prove it with.
    let kindForms: [(String, String, String, Verdict, String)] = [
        ("A1×G1×C1×D1", "skills", "/", .remove, "7"),
        ("A1×G2×C1×D1", "settings.json", "/.", .keep, "8"),
        ("A1×G2×C1×D2", "settings.local.json", "/.", .keep, "8"),
        ("A1×G3×C1×D1", "settings.json", "", .remove, "1"),
        ("A1×G4×C1×D2", "settings.local.json", "", .remove, "1"),
    ]
    for (coord, item, tail, verdict, rule) in kindForms {
        cells.append(Cell(coord: coord, item: item,
                          text: "\(leadIn("C1", "A1"))/\(item)\(tail)", rule: rule,
                          verdict: verdict))
    }
    // The half only resolution can answer: a link to a LINK to the main account's item, whose text
    // names neither the main home nor anything under it.
    cells.append(Cell(coord: "A1×B1×C6′×D1", item: "skills", text: "\(corpusPath)/relay/skills",
                      rule: "12", verdict: .remove))
    var blindSpots = [
        "A1×B10×C1×D2 - a leaf spelled in another case. APFS folds case by default and other "
            + "volumes do not, so while the item exists the kernel answers this and while it does "
            + "not, the comparison keeps the link. A fixture would assert the volume the suite "
            + "happens to run on.",
        "A1×B11×C1×D2 - a leaf in another Unicode normalisation. Same reason, and no item on "
            + "either share list has a decomposable character to write one with.",
    ]
    // `/private/var/…` and `/var/…` are two spellings of one directory on macOS. Only assertable
    // where the suite's temporary directory is the one under `/var`.
    if corpusPath.hasPrefix("/var/") {
        cells.append(Cell(coord: "A1×B1×C1′×D1", item: "skills",
                          text: "/private\(corpusPath)/main/skills", rule: "16", verdict: .remove))
    } else {
        blindSpots.append("A1×B1×C1′×D1 - the `/private` spelling of the same directory: this "
                              + "machine's temporary directory is not under `/var`.")
    }

    for cell in cells {
        let target = home("corpus/t/" + cell.coord.replacingOccurrences(of: "×", with: "-")
            + "-" + cell.item)
        let link = target.appendingPathComponent(cell.item)
        try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: cell.text)
        let removed = unlinkSharedHarness(from: corpusMain, to: target, items: sharedHarnessItems)
        let survived = (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil
        let ours = cell.verdict == .remove
        check("\(cell.coord) rule \(cell.rule): `"
                  + cell.text.replacingOccurrences(of: corpusPath, with: "<root>")
                  + "` is \(ours ? "ours" : "not ours")",
              removed.contains(cell.item) == ours && survived == !ours)
    }
    check("…and the main account came through the whole sweep untouched",
          read(corpusMain.appendingPathComponent("skills/demo/SKILL.md")) == "main skill"
              && read(corpusMain.appendingPathComponent("settings.json")) == "{}"
              && (try? fm.destinationOfSymbolicLink(
                  atPath: corpusMain.appendingPathComponent("hooks").path)) == corpusHooks.path)

    // The homes axis: one home under two names, in each way a machine ends up with one. Refused
    // whole, because every path in the call then lands inside the main account - including the one
    // allowlisted item of it that is a link, which is the only thing here that COULD be removed.
    for (coord, alias) in [("E2", corpus.appendingPathComponent("main-alias")),
                           ("E3", corpusMain),
                           ("E4", corpus.appendingPathComponent("hop/alias"))] {
        let refused = unlinkSharedHarness(from: corpusMain, to: alias, items: sharedHarnessItems)
        check("\(coord) rule 11: a home that IS the main home is refused whole",
              refused.isEmpty
                  && (try? fm.destinationOfSymbolicLink(
                      atPath: corpusMain.appendingPathComponent("hooks").path)) == corpusHooks.path
                  && read(corpusMain.appendingPathComponent("CLAUDE.md")) == "main rules")
    }
    // The existence states that have no main account to compare against at all. D4, both ends
    // unwalkable, is swept above as the ghost lead-in to an item the main account no longer has.
    let goneTargetHome = home("corpus/t/D3")
    try? fm.createSymbolicLink(atPath: goneTargetHome.appendingPathComponent("hooks").path,
                               withDestinationPath: "../../gone-main/hooks")
    check("A2×B1×C1×D3 rule 13: a main account that is not there has nothing to take back",
          unlinkSharedHarness(from: corpus.appendingPathComponent("gone-main"), to: goneTargetHome,
                              items: sharedHarnessItems).isEmpty
              && (try? fm.destinationOfSymbolicLink(
                  atPath: goneTargetHome.appendingPathComponent("hooks").path)) != nil)

    // Named and left uncovered, rather than quietly missing.
    for blind in blindSpots { print("SKIP \(blind)") }

    // MARK: - A home that is not offered at all

    // One home under two names is refused by the act above, and it never reaches the act from the
    // row: an alias of the main home is that home wearing a second name, so the row's own list
    // leaves it out and a fleet of nothing but aliases gets no row at all - the rule that already
    // hides it on a one-account machine, which is what such a fleet is (2026-08-14, replacing a
    // Remove button that stayed on screen in order to explain that it could do nothing). The list
    // is asserted where it can be run, in the integrations suite; what is pinned here is that the
    // row keeps no second spelling of the question, and that the refusal it used to word is gone.
    check("the row asks the one definition of it rather than spelling a second",
          rowSource.contains("harnessHomesAreOne(")
              && !rowSource.contains("resolvingSymlinksInPath")
              && !rowSource.contains("standardizedFileURL"))
    let refusal = "These accounts share one home; there is nothing to unlink."
    check("…and words no refusal, because the press it explained cannot happen",
          !rowSource.contains("oneHome") && !rowSource.contains(refusal))
    // The CLI face of the same fact, which reports rather than translates (terminal output is
    // English by design, like every other line `tally add` prints).
    let addSource = (try? String(contentsOfFile: "TallyCLI/AddCommand.swift", encoding: .utf8)) ?? ""
    check("the add command reads the same fact off its report",
          !addSource.isEmpty && addSource.contains("prepared.sharesMainHome"))

    // Every sentence this row shows, in every language Tally ships - a string that reaches a person
    // in English on a Japanese machine is a missing translation nobody notices (the completion
    // suite's rule).
    let catalogue = (try? Data(contentsOf: URL(fileURLWithPath:
        "Tally/Resources/Localizable.xcstrings")))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    let strings = catalogue?["strings"] as? [String: Any] ?? [:]
    check("the string catalogue is readable from this suite", !strings.isEmpty)
    let shipped = ["zh-Hant", "zh-Hans", "ja", "ko"]
    for sentence in ["Manage in Integrations"] {
        let localizations = ((strings[sentence] as? [String: Any])?["localizations"]
            as? [String: Any]) ?? [:]
        check("\"\(sentence)\" is in the catalogue in every language Tally ships",
              shipped.allSatisfy { language in
                  let unit = (localizations[language] as? [String: Any])?["stringUnit"]
                      as? [String: Any]
                  return (unit?["value"] as? String)?.isEmpty == false
              })
    }
    // And the retired one is gone from all five, rather than left behind for a reader of the
    // catalogue to translate again: a sentence no code can reach is a sentence nobody can check.
    check("the refusal the row no longer makes is out of the catalogue too",
          strings[refusal] == nil)
    // The way OUT of the read-only row, which is the whole point of it: the pane cannot change what
    // it reports, so it hands over the section that can.
    let launchSource = (try? String(contentsOfFile: "Tally/Views/SettingsLaunchView.swift",
                                    encoding: .utf8)) ?? ""
    check("the sharing row offers the way to the control it has none of",
          launchSource.contains("L(\"Manage in Integrations\"), action: showIntegrations"))
    let settingsSource = (try? String(contentsOfFile: "Tally/Views/SettingsView.swift",
                                      encoding: .utf8)) ?? ""
    check("…wired to the section selection this window already has, not to a notion of its own",
          settingsSource.contains("showIntegrations: { section = .integrations }"))
}
