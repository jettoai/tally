import Foundation

// THE ARTIFACT PUBLISHING GUARD, spelled once for the two processes that have to agree about it.
//
// What it is for: a page published by Claude Code's `Artifact` tool is PRIVATE TO THE CLAUDE ACCOUNT
// THAT PUBLISHED IT, and which account a session runs on is decided by this app (the launcher picks
// the one with headroom, the supervisor moves a running session off a dying account). So a
// conversation happily publishes a link, `action: "list"` finds it, and the person who asked for it
// opens their browser to Page not found: they are signed in as a different account, and nothing at
// publish time said so. THE FAILURE HAPPENS AFTER THE DELIVERY AND ONLY THE USER CAN SEE IT.
//
// That is Tally's own doing, so Tally carries the fix: the user names their Artifact publishing
// account in Settings, the app registers a `PreToolUse` hook in every Claude account's settings.json
// (Tally/Stores/IntegrationsArtifactHook.swift), and the CLI answers it (TallyCLI/HookArtifact.swift)
// by denying a publish from any other account with the way out written into the refusal.
//
// A CONVENIENCE, NOT A SECURITY GATE, and that decides every fail direction below: anything this
// hook cannot judge (no setting chosen, no state file, a payload it cannot read) is left alone. The
// cost of a wrong deny is a person blocked from publishing by a guess; the cost of a wrong abstain
// is the situation they are already in today.
//
// Both targets compile this file for the reason QuotaKnockHookContract.swift gives about its own
// spellings: these are separate processes speaking through a file the user owns, so a drift between
// them fails SILENTLY in both directions. A tool name the app writes as a matcher and the CLI does
// not answer to is a hook that runs on every Artifact call and abstains; a marker the CLI answers to
// and the app never writes is a guard nobody registered.

/// The tool this guard is about, which is also the `PreToolUse` MATCHER the app registers it under.
/// One spelling for both halves: Claude Code filters by the matcher, and the CLI checks the name
/// again out of the payload, so a hook wired by hand onto every tool still only judges this one.
let artifactHookToolName = "Artifact"

/// The event it is registered on, and the event name a deny has to NAME BACK: Claude Code reads a
/// reply naming the wrong event as a reply to something else, and drops it.
let artifactHookEvent = "PreToolUse"

/// The registered command. The public path like the hooks beside it, because that is the one that
/// survives the app bundle moving (`quotaKnockCLIDeliverable` asks whether the thing at it can
/// actually run, and defaults to this same path).
let artifactHookCommand = "/usr/local/bin/tally hook-artifact"

/// The subcommand as its own word. A SUFFIX RATHER THAN A SUBSTRING, load-bearing for the reason
/// the knock hook's marker gives: a user's own `/opt/bin/my-hook-artifact` would contain this
/// string, and treating it as ours would silently replace their hook and delete it on uninstall.
let artifactHookMarker = " hook-artifact"

/// The way past the guard for a publish somebody means to make from another account: set in the
/// environment of the session doing it. Read by the CLI; named in the refusal so the way out is in
/// the same sentence as the refusal.
let artifactAnyAccountVariable = "TALLY_ARTIFACT_ANY_ACCOUNT"

/// The actions the `Artifact` tool takes that this guard has an opinion about.
///
/// PUBLISHING A NEW PAGE, AND NOTHING ELSE. Every other action names an artifact that already
/// exists (`list`, `comments`, `reply`, `resolve`, the asset verbs), so none of them can produce the
/// dead link this exists to prevent, and an update carrying a `url` is deliberately let through as
/// well: that path updates a page the user already owns, the server checks the ownership itself,
/// and denying it here would close the one route that is CORRECT when the session is on the account
/// that first published the page.
///
/// An absent action is a publish, which is the tool's own default and therefore the shape most new
/// publishes arrive in.
func artifactActionPublishes(_ action: String?) -> Bool {
    let named = action?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return named.isEmpty || named == "publish"
}
