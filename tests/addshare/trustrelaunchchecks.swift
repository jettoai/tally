import Foundation

// The OTHER folder trust in Tally/Core/TrustSeed.swift: the one a relaunch seeds into a live state
// file (`seedFolderTrust(forDirectory:inConfigDir:)`), rather than the one a NEW account is given
// (`seedFolderTrust(from:to:)`, asserted in main.swift).
//
// The two are opposite acts on the same file and it is worth saying how, because the rules that
// keep one safe would ruin the other. The account seed writes a whole file and refuses to touch an
// existing one; this one only ever runs against a file another program owns and is signed in to, so
// its whole job is to add ONE key and give everything else back unchanged. Most of the rows below
// are that sentence: what the file still holds afterwards.
//
// It exists because of a session in /Users/albertliu/workspace/cleat on 2026-09-02, launched in a
// directory that was not a git repository yet (so Claude Code's trust walk climbed to an accepted
// ancestor and asked nothing), which then ran `git init`, and was relaunched by a self-update three
// hours later. That child's walk was bounded to the directory itself, no entry named it, and the
// trust dialog held the session for three minutes with nobody at the machine.
//
// Runs as a function main.swift calls, which owns the shared harness (`check`).

func runTrustRelaunchChecks(root: URL) {
    let fm = FileManager.default

    func home(_ name: String) -> URL {
        let dir = root.appendingPathComponent(name)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    func write(_ object: [String: Any], into dir: URL) {
        let body = try! JSONSerialization.data(withJSONObject: object)
        try! body.write(to: claudeStateFile(forConfigDir: dir))
    }
    func raw(_ dir: URL) -> Data? { try? Data(contentsOf: claudeStateFile(forConfigDir: dir)) }
    func state(_ dir: URL) -> [String: Any] {
        guard let raw = raw(dir),
              let root = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
        else { return [:] }
        return root
    }
    func projects(_ dir: URL) -> [String: Any] { state(dir)["projects"] as? [String: Any] ?? [:] }
    func entry(_ dir: URL, _ key: String) -> [String: Any] {
        projects(dir)[key] as? [String: Any] ?? [:]
    }
    func trusted(_ dir: URL, _ key: String) -> Bool {
        entry(dir, key)["hasTrustDialogAccepted"] as? Bool == true
    }
    /// A directory to be trusted, named the way the seed will key it.
    func project(_ name: String) -> (path: String, key: String) {
        let dir = root.appendingPathComponent(name)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir.path, dir.resolvingSymlinksInPath().path)
    }

    // MARK: - A home with no state file yet

    // The relaunch cannot wait for Claude Code to write one first: the file appears when a session
    // starts, and the child this seed is for has not started yet.
    do {
        let dir = home("trust-relaunch-empty")
        let (path, key) = project("trust-relaunch-empty-cwd")
        check("a seed into a home with no state file reports the write",
              seedFolderTrust(forDirectory: path, inConfigDir: dir))
        check("the file it creates carries this directory's trust", trusted(dir, key))
        check("and nothing else at all",
              state(dir).count == 1 && projects(dir).count == 1 && entry(dir, key).count == 1)
    }

    // MARK: - A live file, which is the only kind this ever meets

    // Everything around the one key is another program's, and half of it is the account's identity.
    // A seed that took the file as its own would sign the account out.
    do {
        let dir = home("trust-relaunch-live")
        let (path, key) = project("trust-relaunch-live-cwd")
        let other = "/Users/someone/workspace/elsewhere"
        write(["oauthAccount": ["emailAddress": "someone@example.com", "accountUuid": "u-1"],
               "numStartups": 41,
               "installMethod": "native",
               "projects": [other: ["hasTrustDialogAccepted": true,
                                    "lastVersionBase": "2.1.220"]]],
              into: dir)
        check("a seed into a signed-in home reports the write",
              seedFolderTrust(forDirectory: path, inConfigDir: dir))
        check("the directory is trusted afterwards", trusted(dir, key))
        check("the account's identity is given back exactly as it was",
              (state(dir)["oauthAccount"] as? NSDictionary)
                  == ["emailAddress": "someone@example.com", "accountUuid": "u-1"] as NSDictionary)
        check("so are the top-level fields around it",
              state(dir)["numStartups"] as? Int == 41
                  && state(dir)["installMethod"] as? String == "native")
        check("and so is every other project's own history",
              (projects(dir)[other] as? NSDictionary)
                  == ["hasTrustDialogAccepted": true, "lastVersionBase": "2.1.220"] as NSDictionary)
        check("the seed adds one project and no more", projects(dir).count == 2)
    }

    // MARK: - A directory Claude Code already knows, but has not been trusted in

    // The commonest shape of all: the session has been running here for hours, so the entry exists
    // and carries this project's history. Only the one key is missing.
    do {
        let dir = home("trust-relaunch-known")
        let (path, key) = project("trust-relaunch-known-cwd")
        write(["projects": [key: ["lastVersionBase": "2.1.258",
                                  "allowedTools": ["Bash(git:*)"],
                                  "hasCompletedProjectOnboarding": true]]],
              into: dir)
        check("an existing entry is a place to add the flag, not to replace",
              seedFolderTrust(forDirectory: path, inConfigDir: dir))
        check("the flag lands inside it", trusted(dir, key))
        check("and the fields it already held are still there",
              entry(dir, key)["lastVersionBase"] as? String == "2.1.258"
                  && entry(dir, key)["allowedTools"] as? [String] == ["Bash(git:*)"]
                  && entry(dir, key)["hasCompletedProjectOnboarding"] as? Bool == true)
    }

    // MARK: - An answer is already on file

    // The flag is the USER's answer, so the rule is about the field being there rather than about
    // what it says: absent means nobody has been asked, and anything else means somebody has. The
    // overwhelmingly common pass is the first row here, a relaunch in a folder the user vouched for
    // themselves, and it has to cost nothing. Reported as "no change" rather than "written", because
    // that return decides whether an audit line is left, and a log recording every relaunch would
    // say nothing about the ones that mattered.
    do {
        let dir = home("trust-relaunch-already")
        let (path, key) = project("trust-relaunch-already-cwd")
        write(["numStartups": 3, "projects": [key: ["hasTrustDialogAccepted": true]]], into: dir)
        func mtime() -> Date? {
            let attributes = try? fm.attributesOfItem(
                atPath: claudeStateFile(forConfigDir: dir).path)
            return attributes?[.modificationDate] as? Date
        }
        let before = raw(dir)
        let stampBefore = mtime()
        check("a folder that is already trusted reports no change",
              !seedFolderTrust(forDirectory: path, inConfigDir: dir))
        check("and the file is not rewritten at all", raw(dir) == before)
        check("…not even its modification date", mtime() == stampBefore && stampBefore != nil)
        check("the trust is of course still there", trusted(dir, key))
    }

    // THE ROW THIS FEATURE COULD DO REAL HARM ON. `false` is not "not yet trusted", it is the user
    // having been asked and having answered NO, and it is the one state a convenience must never
    // overturn: flipping it would grant, on Tally's own initiative, a permission its owner declined,
    // and the next relaunch would look exactly like the ones that are working correctly. The account
    // seed next door reads the same value the same way (main.swift: a declined path is not carried),
    // so this is the file's existing vocabulary rather than a reading invented here.
    do {
        let dir = home("trust-relaunch-declined")
        let (path, key) = project("trust-relaunch-declined-cwd")
        write(["projects": [key: ["hasTrustDialogAccepted": false, "lastVersionBase": "2.1.258"]]],
              into: dir)
        let before = raw(dir)
        check("a folder the user DECLINED is never flipped to trusted",
              !seedFolderTrust(forDirectory: path, inConfigDir: dir))
        check("…and their answer is still the one in the file", raw(dir) == before
                  && entry(dir, key)["hasTrustDialogAccepted"] as? Bool == false)
    }

    // And the third state the field can be in: present, and something this does not recognise. Same
    // answer as everywhere else in here, for the reason the shape guards below give: a value whose
    // meaning is unknown is a value whose meaning is not ours to overwrite.
    do {
        let dir = home("trust-relaunch-oddflag")
        let (path, key) = project("trust-relaunch-oddflag-cwd")
        write(["projects": [key: ["hasTrustDialogAccepted": "yes"]]], into: dir)
        let before = raw(dir)
        check("a flag that is present but is not a boolean is left alone",
              !seedFolderTrust(forDirectory: path, inConfigDir: dir))
        check("…so whatever it meant is still what the file says", raw(dir) == before
                  && entry(dir, key)["hasTrustDialogAccepted"] as? String == "yes")
    }

    // MARK: - Which path this is about

    // Claude Code keys by the realpath of the cwd and walks upwards from it, so a key spelled any
    // other way seeds an entry nothing ever looks at, and the dialog appears anyway. There is no
    // symptom in between: it either matches or the whole feature is silently absent.
    do {
        let dir = home("trust-relaunch-path")
        let real = root.appendingPathComponent("trust-relaunch-real")
        try? fm.createDirectory(at: real, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("trust-relaunch-alias")
        try? fm.createSymbolicLink(at: alias, withDestinationURL: real)
        check("a symlinked directory is keyed by what it points at",
              seedFolderTrust(forDirectory: alias.path, inConfigDir: dir)
                  && trusted(dir, real.resolvingSymlinksInPath().path))
        check("…and not by the link it was handed", !trusted(dir, alias.path))
        check("a trailing slash names the same directory, so there is nothing left to do",
              !seedFolderTrust(forDirectory: real.path + "/", inConfigDir: dir))
        check("…which is to say it did not add a second key",
              projects(dir).count == 1)
    }

    // MARK: - A file this does not understand

    // Someone else's document, in a shape this does not recognise: a half-written file, a newer
    // schema, a hand edit. Declining costs a trust dialog; writing a valid file of ours over it
    // costs whatever it held.
    do {
        let dir = home("trust-relaunch-garbage")
        let (path, _) = project("trust-relaunch-garbage-cwd")
        let file = claudeStateFile(forConfigDir: dir)
        try! "{\"projects\": {".write(to: file, atomically: true, encoding: .utf8)
        check("an unparseable state file is declined",
              !seedFolderTrust(forDirectory: path, inConfigDir: dir))
        check("and left exactly as it was",
              (try? String(contentsOf: file, encoding: .utf8)) == "{\"projects\": {")
    }

    // AND THE MOST EXPENSIVE READING AVAILABLE HERE: a file that is there but will not open. Read
    // as "no file yet" it becomes an empty starting point, and the atomic write below then replaces
    // a signed-in account's whole state (its identity, every project's history) with a document
    // holding one key of ours. A permission error is only the reachable example; the shape of the
    // mistake is treating a failed read as an absence.
    do {
        let dir = home("trust-relaunch-unreadable")
        let (path, key) = project("trust-relaunch-unreadable-cwd")
        let file = claudeStateFile(forConfigDir: dir)
        let body = "{\"oauthAccount\":{\"accountUuid\":\"u-9\"},\"projects\":{}}"
        try! body.write(to: file, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        let seeded = seedFolderTrust(forDirectory: path, inConfigDir: dir)
        let mode = (try? fm.attributesOfItem(atPath: file.path))?[.posixPermissions] as? NSNumber
        // Restored before anything reads it back, and unconditionally, so a red row above cannot
        // leave an unopenable file behind it for the rest of the suite or for whoever is debugging.
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        check("a state file that exists but cannot be read is not an absent one", !seeded)
        check("…so the account's own state is still there, whole",
              (try? String(contentsOf: file, encoding: .utf8)) == body)
        check("…under the mode it was found with", mode?.intValue == 0)
        check("…and nothing was written under the key this would have seeded", !trusted(dir, key))
    }

    // THE SAME MISTAKE WEARING THE OTHER HAT, and the one `fileExists(atPath:)` could not see. That
    // API follows symlinks and answers false BOTH for "nothing is there" and for "I could not find
    // out", so a `.claude.json` that is a dangling link read as absent - and the atomic write then
    // replaced the LINK ITSELF with a real file holding one key of ours. Asked with `lstat`, the
    // link is an object that is there, and a link is declined whether or not it leads anywhere.
    do {
        let dir = home("trust-relaunch-dangling")
        let (path, key) = project("trust-relaunch-dangling-cwd")
        let file = claudeStateFile(forConfigDir: dir)
        let gone = dir.appendingPathComponent("a-target-that-is-not-there.json")
        try! fm.createSymbolicLink(at: file, withDestinationURL: gone)
        let seeded = seedFolderTrust(forDirectory: path, inConfigDir: dir)
        let type = (try? fm.attributesOfItem(atPath: file.path))?[.type] as? FileAttributeType
        check("a state file that is a dangling symlink is not an absent one", !seeded)
        check("…so what stands there is still the link, not a real file of ours",
              type == .typeSymbolicLink)
        check("…still naming exactly what it always named",
              (try? fm.destinationOfSymbolicLink(atPath: file.path)) == gone.path)
        check("…and nothing was written under the key this would have seeded", !trusted(dir, key))
    }

    // AND THE LINK THAT DOES LEAD SOMEWHERE, which is the expensive one because reading it works.
    // The read follows the link; the write does not. An atomic write renames a temp file over the
    // path, so a seed through this link would leave a regular file standing where the link stood,
    // and the path and the file it used to name would be two documents from then on, each holding
    // and rewriting its own login and project state. Tally never makes this layout, which is no
    // licence to overwrite one the user made, so it is declined and the trust dialog is the cost.
    do {
        let dir = home("trust-relaunch-linked")
        let (path, key) = project("trust-relaunch-linked-cwd")
        let file = claudeStateFile(forConfigDir: dir)
        let target = dir.appendingPathComponent("real-state.json")
        let body = "{\"oauthAccount\":{\"accountUuid\":\"u-7\"},\"projects\":{}}"
        try! body.write(to: target, atomically: true, encoding: .utf8)
        try! fm.createSymbolicLink(at: file, withDestinationURL: target)
        check("a state file that is a symlink to a READABLE file is declined, not written through",
              !seedFolderTrust(forDirectory: path, inConfigDir: dir))
        check("…so what stands there is still the link, not a regular file of ours",
              ((try? fm.attributesOfItem(atPath: file.path))?[.type] as? FileAttributeType)
                  == .typeSymbolicLink)
        check("…still naming exactly what it always named",
              (try? fm.destinationOfSymbolicLink(atPath: file.path)) == target.path)
        check("…the file it leads to holding exactly what it held",
              (try? String(contentsOf: target, encoding: .utf8)) == body)
        check("…and nothing was written under the key this would have seeded", !trusted(dir, key))
    }

    // And the errno that is neither "it is there" nor ENOENT: the config dir itself is a regular
    // file, so the kernel cannot even walk to where the state file would be. An unanswered question
    // is not an absence.
    //
    // SAID PLAINLY, because a row that looks like it proves more than it does is worse than no row:
    // these two pass on the OLD `fileExists` reading as well, and they pass with the ENOENT guard
    // deleted (measured 2026-09-03, all three mutations run). On this filesystem the write fails
    // wherever the probe failed, so the function declines either way and neither row discriminates
    // against the old implementation. What they pin is the contract: an errno that is not ENOENT
    // declines. The rows that DO discriminate are the symlink ones above, which is where the harm
    // was.
    do {
        let notADir = root.appendingPathComponent("trust-relaunch-notdir")
        let body = "I am a file standing where a config dir should be"
        try! body.write(to: notADir, atomically: true, encoding: .utf8)
        let (path, _) = project("trust-relaunch-notdir-cwd")
        check("a state path the kernel cannot walk to (ENOTDIR) is declined",
              !seedFolderTrust(forDirectory: path, inConfigDir: notADir))
        check("…and the file standing in that dir's place is left as it was",
              (try? String(contentsOf: notADir, encoding: .utf8)) == body)
    }

    do {
        let dir = home("trust-relaunch-shape")
        let (path, key) = project("trust-relaunch-shape-cwd")
        write(["projects": "not an object"], into: dir)
        check("a `projects` that is not a map is declined rather than read as absent",
              !seedFolderTrust(forDirectory: path, inConfigDir: dir))
        check("so the file keeps whatever it meant by that",
              state(dir)["projects"] as? String == "not an object")

        let entryDir = home("trust-relaunch-entryshape")
        write(["projects": [key: "not an object"]], into: entryDir)
        check("and neither is an entry that is not a map overwritten",
              !seedFolderTrust(forDirectory: path, inConfigDir: entryDir)
                  && projects(entryDir)[key] as? String == "not an object")
    }

    // MARK: - The call site, which is the whole feature

    // None of the above is reachable from a test: it happens inside the supervisor's spawn loop,
    // which spawns a real `claude`. What the rules above are worth therefore rests on WHERE they are
    // called from, and the failure this would wear best is being called from nowhere: every launch
    // would work and the dialog would simply keep appearing.
    let supervisor = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift",
                                  encoding: .utf8)) ?? ""
    check("the harness really read the supervisor", supervisor.contains("spawnChild("))
    check("the supervised launch seeds this directory's trust",
          supervisor.contains("seedFolderTrust(forDirectory: cwd, inConfigDir: URL(fileURLWithPath: seedHome))"))
    // The line the whole feature turns on: on the user's own first launch nothing here has died and
    // nobody has been asked anything yet, so the trust question is Claude Code's to ask and the
    // answer is theirs to give. Every pass after it is one this supervisor decided to take.
    let leadIn = (supervisor.components(separatedBy: "seedFolderTrust(forDirectory:").first ?? "")
        .split(separator: "\n").suffix(2).joined(separator: " ")
    check("…only on a pass the supervisor itself decided on", leadIn.contains("if relaunching,"))
    // Before the spawn, or the child it is for reads the file without it.
    let spawn = supervisor.range(of: "guard let childPID = spawnChild(")
    let seed = supervisor.range(of: "seedFolderTrust(forDirectory:")
    check("…before the child that reads it is spawned",
          spawn != nil && seed != nil && seed!.upperBound <= spawn!.lowerBound)
    // Inside the loop and keyed to `seedHome`, for the reason the MCP seeding above it is: the
    // account can CHANGE between two passes, and a cap handoff onto a home that has never seen this
    // folder is exactly the case a relaunch has to survive.
    let loop = supervisor.components(separatedBy: "while true {").last ?? ""
    check("…inside the relaunch loop, so a handoff seeds the home it hands off TO",
          loop.contains("seedFolderTrust(forDirectory:"))
    // The audit line is written INSIDE the `if`, which is what makes the log a record of acts: the
    // return value it is guarded by is false whenever the file already carried the flag.
    let seeded = supervisor.components(separatedBy: "seedFolderTrust(forDirectory:").last ?? ""
    let seededBlock = seeded.components(separatedBy: "\n            }").first ?? ""
    check("an act this leaves in the shared audit log, and only when it wrote something",
          seededBlock.contains("appendHandoffLine(") && seededBlock.contains("trustSeedLine(")
              && seededBlock.contains("to: handoffLog)"))
    check("…naming the home it seeded and the session the child is about to resume",
          seededBlock.contains("home: seedHome, cwd: cwd)")
              && seededBlock.contains("flagValue(launchArgs, \"--resume\")"))
    // And the account seed next door is NOT what the supervisor calls: that one writes a whole file
    // and refuses an existing one, which against a live home would silently do nothing at all.
    check("the supervisor never reaches for the whole-file account seed",
          !supervisor.contains("seedFolderTrust(from:"))
}
