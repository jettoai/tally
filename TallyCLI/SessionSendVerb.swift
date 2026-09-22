import Foundation

// `tally send <claude|codex> …`: the top-level spelling of `tally session send`, and the one thing
// it buys that the other spelling cannot.
//
// A SECOND SPELLING, NOT A SECOND SEND. Everything below turns a command line into the very
// `SessionSendIntent` the other spelling produces and hands it to the same function
// (`runSessionSend`), so the roster lookup, every refusal and every exit code are one
// implementation. This repository has paid for the other arrangement before: two ways to write one
// act, and a filter that only ever learned to recognise one of them.
//
// WHY THE PROVIDER IS A POSITION RATHER THAN A FLAG. `tally message claude --socket …` already
// spells it this way, so the shape is the one this CLI has: the word after the verb says which kind
// of session is meant. It reads as the sentence it is, and it cannot be left out, which is what
// makes the check below possible at all.
//
// AND WHAT THE POSITION BUYS: a send that names its provider can be REFUSED when the session it
// reaches is the other kind. The two providers accept different things (Codex takes no slash
// commands and no bare Return, SessionInputCommand.swift lists the rest), so a `/clear` typed at a
// session an agent believed was Claude is a line delivered to the wrong sort of conversation. The
// other spelling has nothing to compare against unless a directory was named, so this check is the
// difference between the two, and it runs for a pid and for this session as well as for a
// directory.
//
// NO SINGLE-LETTER FLAGS, and not as an oversight. Every flag Tally owns is spelled out; the
// single letters in this codebase belong to the CLIs it launches, and both of the ones this command
// types into already use `-p` for something of their own (Claude Code reads it as `--print`, Codex
// as `--profile`). Giving it a third meaning in the same terminal, on a command whose whole job is
// to put text into one of those two, is a trap for the person typing rather than a convenience.

/// What `tally send <provider> …` asks for.
struct SendVerbRequest: Equatable {
    /// The provider named in the position after the verb, which every path this send takes has to
    /// agree with.
    var provider: String
    /// The request itself, IDENTICAL to what `tally session send` builds for the same send: what
    /// travels on carries no trace of which spelling was typed.
    var intent: SessionSendIntent
}

/// What one `tally send` command line asks for, or nil when it asks for something this command
/// cannot act on (which is a usage error rather than a refusal: nothing has been looked up yet).
///
/// THE PROVIDER IS REQUIRED AND POSITIONAL. It is read off the first word and nowhere else, so
/// `tally send -- claude hi` is a usage error rather than a send: `--` ends the flags for the TEXT,
/// and a position that could be written after it would be a position that can be mistaken for
/// content.
///
/// `--provider` IS NOT A FLAG OF THIS SPELLING. The position has already said which kind of session
/// is meant, so a second answer to the same question is either a repetition or a contradiction, and
/// there is no reading of the contradiction that is safe to guess at. The grammar of everything
/// after the provider is the other spelling's, unchanged (`sessionSendIntent`), which is what makes
/// the two produce the same request for the same send.
func sendVerbRequest(_ args: [String]) -> SendVerbRequest? {
    guard let provider = args.first, sessionProviderNames.contains(provider) else { return nil }
    guard let intent = sessionSendIntent(Array(args.dropFirst())),
          intent.provider == nil else { return nil }
    // The provider is folded into the request only where there is a directory for it to narrow,
    // because that is the one place the other spelling can express it too - so the two spellings
    // produce the same value field for field, and a test can say so. Where no directory was named
    // it travels beside the request instead (`SendVerbRequest.provider`), and the check it feeds
    // happens once the address has become a session key.
    //
    // THE OTHER SPELLING'S REQUEST, AMENDED RATHER THAN REBUILT. Listing every field here would be
    // a second place that has to learn each one `SessionSendIntent` grows, and the day it forgot
    // one the spelling that is meant to be identical would be the spelling that silently drops it.
    var request = intent
    if request.project != nil { request.provider = provider }
    return SendVerbRequest(provider: provider, intent: request)
}

/// Which provider the session at that key is, in the two words `tally status --json` publishes
/// under `sessions[].provider`.
///
/// THE SAME TEST THE REPORT MAKES, deliberately: the report folds `monitoring` into exactly these
/// two words (SessionInventory.swift), and a caller that read a provider off that JSON must not be
/// judged by a second notion of what a session is - one free to disagree with the roster the name
/// came from.
func sessionProviderName(sessionKey: String, dir: URL = supervisorStateDir) -> String {
    SessionMonitoring.isMarked(pid: sessionKey, dir: dir) ? "codex" : "claude"
}

/// Why the session that was found is not the provider the caller named, or nil when it is. Pure, so
/// the wording is assertable, and worded like the other refusals here: nothing of yours was queued
/// at all, and here is the next thing to type.
func sessionProviderMismatch(wanted: String, found: String, sessionKey: String) -> String? {
    guard wanted != found else { return nil }
    return "session \(sessionKey) is a \(found) session and `tally send \(wanted)` names a "
        + "\(wanted) one, so nothing was queued. The two accept different things - Codex takes no "
        + "slash commands and no bare Return - so a line meant for one of them is not a line for "
        + "the other. Send it with `tally send \(found)` if that session is the one you meant, or "
        + "name the one you meant with --session <pid> or --project <dir>; `tally status --json` "
        + "lists every session with its provider"
}

let sendVerbUsage = """
usage: tally send <claude|codex> [<text>] [--project <dir-or-name> | --session <pid>]

Types <text> into a supervised session's own terminal and presses Return: the same act as `tally
session send`, addressed provider-first. The word after `send` is required and says which kind of
session is meant, and a session that turns out to be the other kind is refused rather than typed
into - which is the whole reason to prefer this spelling from a script.

With neither flag the target is the session this command runs in. --session <pid> names another one
by either of its pids, the provider process `tally status --json` lists under `sessions[].pid` or
the Tally supervising it. --project takes the directory a session was launched in, and also a bare
PROJECT NAME: a word with no slash, `~` or leading dot is matched against the last component of each
directory on the roster, exactly and with its case. A name two different directories answer to is
refused with both paths listed, and so is a name nothing was launched under; pass a full path to
name a checkout precisely. The two flags are alternatives, and there is no --provider flag here
because the position already answered that question.

`tally message <provider>` is the other thing and not a synonym: that one writes a message into a
native queue at an address you already hold, this one types into a terminal.

Everything else - what a Codex session accepts, the 200-byte limit, when a queued line is typed and
what the exit codes mean - is `tally session send`, which this is a spelling of. Run `tally session
send` with no valid arguments to read it.
"""

/// `tally send <claude|codex> …`: the same send as `tally session send`, addressed provider-first.
func runSend(args: [String]) -> Int32 {
    guard let request = sendVerbRequest(args) else {
        warn(sendVerbUsage)
        return 2
    }
    return runSessionSend(request.intent, requiredProvider: request.provider)
}
