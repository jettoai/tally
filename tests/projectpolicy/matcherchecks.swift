import Foundation

// One matcher for every surface that resolves a NAME somebody typed: `tally claude --account`,
// `tally switch`, and what `tally project set --account` stores (AccountPick.swift). Split from
// main.swift at its size cap, the same division shellsafetychecks.swift already keeps; the shared
// harness (`check`, `snapshot`, `dormant`, `now`) lives there.
//
// The behaviour under test is an ordering: exact label, exact config-dir name, a unique substring,
// and then a refusal. It used to be the substring alone, answering with the first hit, which is a
// silent wrong answer on any fleet whose labels are prefixes of each other - and the fleet this
// repo is written for is exactly that.

func runAccountMatchChecks(setSource: String) {
    // MARK: - `accountMatching`: one matcher for `--account` and for what `project set` stores

    /// The account a hand-written name resolves to, by id, when it resolves to exactly one.
    func matchedID(_ name: String, provider: String = "claude", in snapshot: Snapshot) -> String? {
        guard case .one(let account) = accountMatching(name, provider: provider, in: snapshot) else {
            return nil
        }
        return account.id
    }
    check("an account matches on its label", matchedID("claude 2", in: snapshot) == "claude:.claude2")
    check("…and on its config-dir name", matchedID(".claude2", in: snapshot) == "claude:.claude2")
    check("matching is case-insensitive", matchedID("CLAUDE 2", in: snapshot) == "claude:.claude2")
    check("a name nobody answers to matches nothing", matchedID("zzz", in: snapshot) == nil)
    check("another provider's accounts are not candidates",
          matchedID("claude 2", provider: "codex", in: snapshot) == nil)
    check("a signed-out account is not matchable: naming it is not a way to launch it",
          matchedID("claude 2", in: dormant) == nil)

    // MARK: - Exact before substring, and a refusal instead of a guess

    // THE FIXTURE IS THE BUG. Every label here contains "Claude", the account that answers to it
    // EXACTLY is not the one listed first, and the matcher used to answer with the first substring hit:
    // `tally switch Claude` moved the session to "Claude 2" and said it had done what was asked. The
    // order below is deliberate - with the right answer first, any implementation passes.
    func lookalike(_ id: String, _ label: String) -> Snapshot.Account {
        Snapshot.Account(id: "claude:\(id)", provider: "claude", label: label,
                         launchHome: "/Users/u/\(id)", isStale: false)
    }
    let lookalikes = [lookalike(".claude2", "Claude 2"),
                      lookalike(".claude", "Claude"),
                      lookalike(".claude3", "Claude 3")]
    let fleet = Snapshot(version: 2, generatedAt: now, accounts: lookalikes)
    check("an exact label wins over a substring hit listed before it",
          matchedID("Claude", in: fleet) == "claude:.claude")
    check("…case-insensitively, which is how the label is usually typed",
          matchedID("claude", in: fleet) == "claude:.claude")
    check("an exact config-dir name wins the same way",
          matchedID(".claude", in: fleet) == "claude:.claude")
    // Substring matching still earns its keep: it is what lets a config dir stand in for a label.
    check("a substring that only one account contains still resolves",
          matchedID("claude 3", in: fleet) == "claude:.claude3"
              && matchedID("2", in: fleet) == "claude:.claude2")
    // And when it is genuinely ambiguous, nothing is chosen. Acting on the first is what the exact
    // stages above exist to stop; doing it one stage later would be the same defect in a smaller box.
    check("a substring several accounts contain resolves to nothing at all",
          matchedID("Clau", in: fleet) == nil)
    check("…and says which ones, in the order they are listed",
          accountMatching("Clau", provider: "claude", in: fleet) == .several(lookalikes))
    check("nothing at all is still distinguishable from too much",
          accountMatching("zzz", provider: "claude", in: fleet) == .none)
    // An id is neither of the two names this matcher compares (`<provider>:<config-dir name>` is
    // not the label and not the bare directory), which is why a surface holding one must not hand
    // it back here to be looked up again (`switchMenuPick`, SwitchMenu.swift).
    check("an account id is not a name this matcher accepts",
          accountMatching("claude:.claude", provider: "claude", in: fleet) == .none)

    // Two accounts really carrying the same label are indistinguishable BY LABEL, so the exact stage
    // must require uniqueness too - otherwise it hands back "the first of the identical ones", which is
    // the guess this whole ordering exists to refuse, one stage earlier.
    let twins = [lookalike(".claudeA", "Twin"), lookalike(".claudeB", "Twin")]
    let twinFleet = Snapshot(version: 2, generatedAt: now, accounts: twins)
    check("an exact label matching two accounts is refused, not taken",
          accountMatching("Twin", provider: "claude", in: twinFleet) == .several(twins))
    check("…and the config-dir name is what still tells them apart",
          matchedID(".claudeB", in: twinFleet) == "claude:.claudeB")

    // The candidate list a refusal hands back: both names, because the label alone cannot always tell
    // them apart and both are things this matcher accepts, so the list is also the set of answers to
    // retype.
    check("candidates are named by label and config dir together",
          accountMatchCandidates(lookalikes)
              == "Claude 2 (.claude2), Claude (.claude), Claude 3 (.claude3)")

    // The wording, checked at the one surface whose source this suite already holds. Every call site
    // is FORCED by the compiler to handle `.several` (the switch over it is exhaustive); what a
    // compiler cannot check is that the branch says something useful rather than repeating the
    // "no such account" sentence, which is the wrong sentence for an account that exists three
    // times over.
    check("`project set` names the candidates rather than claiming there is no such account",
          setSource.contains("accountMatchAmbiguity(account, provider: providerID")
              && setSource.contains("nothing was changed"))
    // The sentence itself, once, so every surface says the same thing about the same situation.
    check("the refusal names the count, the candidates and what to do",
          accountMatchAmbiguity("Clau", provider: "claude", candidates: lookalikes)
              == "\"Clau\" matches 3 claude accounts (Claude 2 (.claude2), Claude (.claude), "
                  + "Claude 3 (.claude3)) - name one of them exactly")
}
