import Foundation

// THE SKILL'S MOVE BETWEEN FOLDERS, and what it does to an install already on disk.
//
// A skill folder name is not a detail of where a file sits: Claude Code registers the folder in the
// same namespace it draws the slash-command menu from, so a skill in `skills/tally` TOOK `/tally`
// off that menu. 0.44.0 shipped both halves of the same release - the two commands merged into
// `/tally`, and a skill folder still called `tally` - so the command file was written to every
// machine and offered on none of them. Nothing about the install looked wrong: the menu showed a
// `/tally-quota` entry, which is the name the skill's own frontmatter carries, and the command it
// was shadowing simply was not there.
//
// The folder is spelled the way the frontmatter is now, and this file is what carries the installs
// that are already out there across to it. The shape is the one a renamed command already had
// (`PromptCommand.formerNames`, IntegrationsPromptCommand.swift): what is in the old folder is
// OURS, it goes on shadowing the command for as long as it exists, and nothing else will ever come
// to take it away.
//
// TWO THINGS ARE DELIBERATELY NOT `skillVersion`:
//
// - The move is keyed on what is ON DISK, a former folder holding a file of ours, rather than on
//   the version marker. The installs that need it are exactly the ones ALREADY CURRENT: 0.44.0
//   wrote v16 into the wrong folder, so a bump would have rewritten that same file where it stood
//   and changed nothing the user can see. This is the grid the incident lives in, and a number
//   cannot reach it.
// - The new file is written BEFORE the old one is let go. A folder that will not delete (a
//   permission, an ACL) then costs an orphan rather than an install: nobody is left with no skill
//   at all because a removal failed.

extension IntegrationsStore {
    /// Folders the skill has lived in before, in the same spirit as the former names a renamed
    /// command answers for: an install left behind under one of these is ours to move, and ours
    /// alone to clean up.
    nonisolated static let formerSkillFolderNames = ["tally"]

    /// The paths in `file`'s own home that an older app version would have installed the skill at.
    static func formerSkillFiles(besides file: URL) -> [URL] {
        let home = claudeHome(ofSkillFile: file)
        return formerSkillFolderNames.map {
            home.appendingPathComponent("skills").appendingPathComponent($0)
                .appendingPathComponent(file.lastPathComponent)
        }
    }

    /// Whether an install of OURS is still sitting in a folder the skill has left. Asked of the
    /// disk, through the same ownership predicate as everything else here (`skillFileIsOurs`), so a
    /// skill of the user's that happens to be called `tally` is not one: we do not install there
    /// any more, which makes that name theirs.
    static func formerSkillFolderCarriesOurs(besides file: URL) -> Bool {
        !oursAmong(formerSkillFiles(besides: file)).isEmpty
    }

    /// Lets go of every former folder beside `file` that is ours, and of the folder itself once
    /// nothing else lives in it. Returns whether anything was removed.
    ///
    /// Called only once the install exists at the current path, for the reason given at the top of
    /// this file. Every candidate is tried before the first failure is rethrown, exactly as
    /// `removePromptCommandEveryName` does: one file that will not go must not shelter the next.
    @discardableResult
    static func clearFormerSkillFolders(besides file: URL) throws -> Bool {
        var failure: Error?
        var cleared = false
        for former in oursAmong(formerSkillFiles(besides: file)) {
            do {
                try removeSkill(in: former)
                cleared = true
            } catch {
                failure = failure ?? error
            }
        }
        if let failure { throw failure }
        return cleared
    }

    /// Writes the install at `file`, then lets go of the folders it has left. Returns how many
    /// changes that made on disk, which is what `autoUpdateSkills` counts.
    ///
    /// The ORDER is the safety property this exists to hold in one place: both callers write first
    /// and delete second, so a removal that fails costs an orphan rather than an install.
    static func upsertSkillClearingFormerFolders(in file: URL) throws -> Int {
        var changes = try upsertSkill(in: file) ? 1 : 0
        if try clearFormerSkillFolders(besides: file) { changes += 1 }
        return changes
    }

    /// A path the manifest recorded, read as the place that install lives TODAY.
    ///
    /// The manifest is what makes an account that logged out since install reachable at all, and on
    /// every machine that has been through 0.44.0 what it records is a path in the old folder. Read
    /// literally, an uninstall would take that file away and leave the current one behind, and the
    /// auto-update would keep the old folder up to date for ever. Read as a home, both reach the
    /// install that Claude Code actually loads, and the old folder is reached by the move.
    static func currentSkillFile(forRecordedPath file: URL) -> URL {
        let folder = file.deletingLastPathComponent().lastPathComponent
        guard formerSkillFolderNames.contains(folder) else { return file }
        return claudeSkillFile(inHome: claudeHome(ofSkillFile: file))
    }
}
