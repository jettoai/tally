import Foundation

// `tally resume` - the manual counterpart of the supervisor's auto-handoff: take the conversation
// this directory was last having and continue it on the account with the most headroom.
//
// Split out of main.swift (2026-08-13) when that file reached this repo's 500-line cap, under the
// naming every other subcommand already uses (AddCommand, ModelCommand, ShareCommand, SwitchCommand,
// UpdateCommand). main.swift keeps the launcher, the status report and the dispatch, which is the
// seam that was already there: this command is the only one of the three that MOVES something.

/// `tally resume` - hand this directory's latest Claude session to the account with the most
/// headroom and continue the SAME conversation there (the manual counterpart of auto-handoff).
///
/// Transcripts live per-account (`<home>/projects/<cwd-slug>/<session>.jsonl`); resuming on another
/// account needs the file present in that account's tree. Copy is additive only - never overwrites,
/// and a shared/symlinked projects dir (this machine's setup) needs no copy at all. Empirically
/// verified 2026-07-16: account 2 resumed account 1's session and recalled its content.
func runResume(args: [String]) -> Never {
    let provider = providers[0]   // claude only for now
    let (snapshot, problem) = loadSnapshot()
    if let problem { warn(problem) }
    guard let snapshot else { exit(1) }

    let slug = projectSlug(forCwd: FileManager.default.currentDirectoryPath)

    // Newest session for this directory across every account = the conversation to hand off.
    let claudeAccounts = snapshot.accounts.filter { $0.provider == provider.id && $0.launchHome != nil }
    var newest: (account: Snapshot.Account, file: URL, modified: Date)?
    for account in claudeAccounts {
        let dir = URL(fileURLWithPath: account.launchHome!).appendingPathComponent("projects/\(slug)")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.pathExtension == "jsonl" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if newest == nil || modified > newest!.modified {
                newest = (account, file, modified)
            }
        }
    }
    guard let newest else {
        warn("no Claude session found for this directory")
        exit(1)
    }
    let sessionID = newest.file.deletingPathExtension().lastPathComponent

    // The args this resume will RUN with: the launch defaults injected exactly as a fresh launch
    // injects them (a flag the user typed still wins), so the conversation comes back on the model
    // its project declared instead of on whatever the CLI defaults to.
    //
    // Scoring the accounts and launching the session read the SAME vector, which is the whole point
    // of building it here. They used to disagree: the pick was made for the project's model while
    // the exec passed the user's args through untouched, so a resume was placed on an account
    // chosen for opus and then ran fable on it - the one failure mode an account pick has no way to
    // recover from, because by then the session is already somewhere.
    //
    // The account pin a project may also declare is deliberately not read here: this command's
    // whole purpose is to move a conversation to a different account, and the app's own pin has
    // never been honoured here either.
    let effective = effectivePolicy(launchPolicy(provider.id), project: projectPolicy(provider.id))
    let resumeArgs = applyLaunchDefaults(args, policy: effective, providerID: provider.id)
    let primaryModel = launchPrimaryModel(resumeArgs, providerID: provider.id) ?? effective.model
    let target = snapshot.accounts
        .filter { $0.provider == provider.id && eligible($0, primaryModel: primaryModel)
            && $0.id != newest.account.id }
        .max {
            smartScore($0, primaryModel: primaryModel) < smartScore($1, primaryModel: primaryModel)
        } ?? newest.account
    if target.id == newest.account.id {
        warn("no other eligible account - resuming on \(target.label)")
    }

    // Make the transcript visible to the target (no-op when the projects tree is shared/symlinked;
    // never overwrite an existing file).
    let sourceResolved = newest.file.resolvingSymlinksInPath()
    let destDir = URL(fileURLWithPath: target.launchHome!).appendingPathComponent("projects/\(slug)")
    let dest = destDir.appendingPathComponent(newest.file.lastPathComponent)
    if dest.resolvingSymlinksInPath() != sourceResolved,
       !FileManager.default.fileExists(atPath: dest.path) {
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        do {
            try FileManager.default.copyItem(at: newest.file, to: dest)
        } catch {
            warn("cannot copy transcript to \(target.label): \(error.localizedDescription)")
            exit(1)
        }
    }

    warn("→ resuming \(sessionID.prefix(8))… from \(newest.account.label) on \(target.label) " +
         "(\(pickReason(target, primaryModel: primaryModel)))")
    exec(provider.cli, args: ["--resume", sessionID] + resumeArgs,
         env: launchEnv(provider, home: target.launchHome!))
}
