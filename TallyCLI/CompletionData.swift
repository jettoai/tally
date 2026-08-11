import Foundation

// The Swift half of `tally completion`: the subcommand that prints the script (Completion.swift),
// and the plumbing that script asks its questions through.
//
// SPLIT FROM THE SCRIPT ITSELF for size - the two together crossed this repo's 500-line limit - and
// the seam is the one that was already there: above it is text that runs in somebody else's shell,
// below it is this binary answering the questions that text asks.

/// `tally completion <shell>` - print a completion script on stdout, for eval or for fpath.
///
/// Named rather than defaulted: bare `tally completion` is a usage error rather than zsh, so the
/// day a second shell arrives nothing that was written down changes meaning. Same shape as the
/// other subcommands with a list: the text goes to stderr with exit 2, since a word this command
/// does not know is a mistake rather than a request.
func runCompletion(args: [String]) -> Int32 {
    switch args.first {
    case "zsh":
        print(tallyCompletionZsh)
        return 0
    case "data":
        return runCompletionData(args: Array(args.dropFirst()))
    default:
        warn("usage: tally completion zsh")
        return 2
    }
}

/// The names `--account` will accept for one provider's accounts, one per line: what the completion
/// script offers at the cursor.
///
/// ASKED OF THE MATCHER ITSELF rather than assembled beside it. A name is offered only when
/// `accountMatching` resolves it to exactly this account, which makes the suggestion true by
/// construction: the completion cannot offer a Codex account to `tally claude --account` (the
/// matcher filters on the provider first), and it cannot offer a label two accounts share, which
/// the matcher answers with "name one of them exactly" - the one answer a suggestion must never be.
///
/// The label is preferred and the config-dir name is the fallback, in the order a person reads them
/// off `tally status`: one name per account, and the directory appears only for the accounts whose
/// label cannot pick them out. An account neither name resolves is offered under neither, because
/// there is nothing to type that would land on it.
func completionAccountNames(_ snapshot: Snapshot?, provider: String) -> [String] {
    var names: [String] = []
    for account in snapshot?.accounts ?? [] where account.provider == provider {
        guard let home = account.launchHome else { continue }
        let candidates = [account.label, URL(fileURLWithPath: home).lastPathComponent]
        // A newline cannot be a candidate on a line-per-candidate channel, and a label is free text
        // (the rename popover accepts anything). Dropped rather than escaped: nothing could type it
        // back in anyway.
        guard let name = candidates.first(where: { candidate in
            guard !candidate.isEmpty, !candidate.contains("\n") else { return false }
            guard case .one(let match) = accountMatching(candidate, provider: provider,
                                                         in: snapshot) else { return false }
            return match.id == account.id
        }) else { continue }
        names.append(name)
    }
    return names
}

/// `tally completion data <what> [args]` - the plumbing the completion script asks its questions
/// through. Not in `tally help` and not offered at the cursor: it is one program talking to itself,
/// and a person reading the list of commands has nothing to do with it.
///
/// A SUBCOMMAND RATHER THAN A SHELL PARSE OF `status --json`. That report is pretty-printed JSON
/// carrying free text a user typed, so a shell reader has to get quoting and escaping right to hand
/// back a name that matches; here the binary that owns the matcher answers with the words that
/// resolve. Silent about every failure, including a snapshot it could not read: this runs at a
/// cursor, where the only two outcomes allowed are suggestions and no suggestions.
func runCompletionData(args: [String]) -> Int32 {
    guard args.first == "accounts", let providerID = args.dropFirst().first,
          providers.contains(where: { $0.id == providerID }) else {
        warn("usage: tally completion data accounts <\(providers.map(\.id).joined(separator: "|"))>")
        return 2
    }
    let (snapshot, _) = loadSnapshot()
    for name in completionAccountNames(snapshot, provider: providerID) { print(name) }
    return 0
}
