import Foundation

// What `tally share` reads a command line as (TallyCLI/ShareCommand.swift).
//
// The engine next door is asserted on the bytes it leaves behind; this file is about the sentence
// that starts it. Both rules here are refusals, and a refusal is the only part of this command that
// is cheap to be wrong about: everything past it writes into somebody's config home, where a
// misread word is invisible until much later.
//
// Runs as a function main.swift calls, which owns the shared harness (`check`).

func runShareCommandChecks() {
    // The two sentences this command has.
    check("a provider and an account name is one account's share",
          shareIntent(["codex", "work"]) == ShareIntent(providerID: "codex", account: "work"))
    check("a provider and --all is the fleet's",
          shareIntent(["claude", "--all"]) == ShareIntent(providerID: "claude", account: nil))
    check("…in either order, because a flag is not a position",
          shareIntent(["--all", "claude"]) == ShareIntent(providerID: "claude", account: nil))

    // THE BUG THIS LOCKS (codex review, 2026-08-13). Dash-led words were filtered out before the
    // line was read, so `tally share codex work --help` was read as `tally share codex work` - and
    // this command's answer to that is to move that account's files aside and link the main
    // account's over them. Somebody typing --help is asking what it does, not for it to happen.
    check("a request for help is never an instruction to share",
          shareIntent(["codex", "work", "--help"]) == nil
              && shareIntent(["codex", "--help"]) == nil
              && shareIntent(["codex", "-h"]) == nil)
    check("…and neither is any other flag this command does not have",
          shareIntent(["codex", "work", "--dry-run"]) == nil
              && shareIntent(["claude", "--all", "--force"]) == nil
              && shareIntent(["-x", "claude", "--all"]) == nil)
    // A bare dash is not an account either: `tally status` prints no such label, so the only thing
    // it can be is a typo of a flag.
    check("…a bare dash included", shareIntent(["codex", "-"]) == nil)

    // The rules that were already there, kept: one name or --all, never both and never neither.
    check("both together is refused rather than resolved",
          shareIntent(["codex", "work", "--all"]) == nil)
    check("neither is refused too, because this command never acts on a guess",
          shareIntent(["codex"]) == nil && shareIntent([]) == nil)
    check("two names is not a plural, it is a mistake",
          shareIntent(["codex", "work", "personal"]) == nil)
    check("and a provider this binary does not have is nothing to share",
          shareIntent(["nope", "work"]) == nil && shareIntent(["--all"]) == nil)
    // The account name is passed through as typed - the matcher, not this reading, is what decides
    // which home it means (AccountPick.swift).
    check("an account name is carried through exactly as it was typed",
          shareIntent(["claude", "Claude 4"])?.account == "Claude 4"
              && shareIntent(["claude", "--all"])?.account == nil)
}
