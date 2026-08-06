import Foundation

// A relaunch carries no prompt: the positional strip (`withoutPositionals`, LaunchFlags.swift),
// the arity table it reads, and the end-to-end claim that no path downstream of a relaunch can
// hand a positional to a child. Split from relaunchchecks.swift for file size.
//
// The arity of every claude flag asserted here was read out of the CLI binary (`strings` over
// ~/.local/share/claude/versions/2.1.223, which carries the commander registration verbatim),
// never by running `claude` - this repo does not probe the CLI behaviourally.

func runPositionalChecks(account movedTo: Snapshot.Account) {
    // MARK: - 20b. A relaunch carries no prompt

    // A positional handed to claude IS the initial prompt: the CLI types it in and submits it. That
    // is right on the launch the user typed and wrong on every relaunch after it, because the
    // conversation being resumed already contains it - so carrying it means submitting it again at
    // every cap handoff, switch, reload and self-update. Measured on 2026-08-06: two live sessions
    // had terminal noise in their argv from before the input drain existed (`tj3裡`, `u0v49`) and
    // had been re-typing it into every child since, across self-updates, with nothing on the TTY
    // side able to reach it.
    check("the prompt does not ride along on a relaunch",
          relaunchArgs(["--", "run", "-c", "twice"], sessionID: nil, sameAccount: false) == [])
    check("a bare positional is a prompt too, marker or no marker",
          relaunchArgs(["--model", "fable", "tj3裡"], sessionID: "abc", sameAccount: true)
          == ["--resume", "abc", "--model", "fable"])
    // The exact fossil, in the order it was found in: a value, then the stray word, then more flags.
    check("a word wedged between two option pairs goes, and only it",
          relaunchArgs(["--dangerously-skip-permissions", "--fallback-model", "opus", "tj3裡",
                        "--model", "fable", "--effort", "high"],
                       sessionID: "abc", sameAccount: true)
          == ["--resume", "abc", "--dangerously-skip-permissions", "--fallback-model", "opus",
              "--model", "fable", "--effort", "high"])
    // The lesson the old shape was written for still holds, and now holds trivially: a `-c` the
    // user SAID is not a request to continue. It used to have to survive as a word in the prompt;
    // now the prompt is not carried at all, so it cannot be read as an instruction either.
    check("a -c inside the prompt never resurrects --continue",
          relaunchArgs(["--", "-c"], sessionID: nil, sameAccount: true) == [])
    check("while a real one before the marker still is",
          relaunchArgs(["-c", "--", "-c"], sessionID: nil, sameAccount: true) == ["--continue"])
    check("a resume word in the prompt does not swallow the next one, or anything else",
          relaunchArgs(["--", "--resume", "yesterday"], sessionID: nil, sameAccount: false) == [])
    check("resuming by id rebuilds the options and leaves no prompt behind",
          relaunchArgs(["--continue", "--", "-c"], sessionID: "abc", sameAccount: true)
          == ["--resume", "abc"])

    // MARK: - 20b2. The rule itself

    // Positional-stripping, on its own, because everything above only sees it through one caller.
    check("options and their values are kept",
          withoutPositionals(["--model", "fable", "--effort", "high"])
          == ["--model", "fable", "--effort", "high"])
    check("a valueless flag does not eat the word after it",
          withoutPositionals(["--continue", "hello"]) == ["--continue"])
    check("nor does the -c spelling of it", withoutPositionals(["-c", "hello"]) == ["-c"])
    check("and neither does the permission flag Tally injects",
          withoutPositionals(["--dangerously-skip-permissions", "hello", "--model", "fable"])
          == ["--dangerously-skip-permissions", "--model", "fable"])
    check("a value that is itself a flag is not consumed as one",
          withoutPositionals(["--model", "--effort", "high"]) == ["--model", "--effort", "high"])
    check("everything past a bare -- goes, marker included",
          withoutPositionals(["--model", "fable", "--", "write", "--model", "notes"])
          == ["--model", "fable"])
    check("a vector that is nothing but a prompt comes back empty",
          withoutPositionals(["summarise", "this"]) == [])
    check("a bare - is a name, not an option", withoutPositionals(["-"]) == [])
    check("an empty vector stays empty", withoutPositionals([]) == [])
    // Order is not assumed: a prompt can sit before the flags as easily as after them.
    check("a prompt in front of the options is stripped just the same",
          withoutPositionals(["do the thing", "--model", "fable"]) == ["--model", "fable"])
    check("several strays go, and every option pair survives",
          withoutPositionals(["a", "--model", "fable", "b", "--effort", "high", "c"])
          == ["--model", "fable", "--effort", "high"])
    // The two counter-examples that retired the old "everything unknown takes one value" rule, both
    // real claude flags (arity read out of the CLI binary, 2.1.223).
    check("a zero-arity flag does not swallow the prompt behind it",
          withoutPositionals(["--verbose", "ship it"]) == ["--verbose"])
    check("…nor when the prompt sits between two of them",
          withoutPositionals(["--verbose", "ship it", "--ide", "--model", "fable"])
          == ["--verbose", "--ide", "--model", "fable"])
    check("a variadic flag keeps every value it was given",
          withoutPositionals(["--add-dir", "one", "two", "--model", "fable"])
          == ["--add-dir", "one", "two", "--model", "fable"])
    check("and keeps them at the end of the vector too",
          withoutPositionals(["--model", "fable", "--add-dir", "one", "two"])
          == ["--model", "fable", "--add-dir", "one", "two"])
    check("both spellings of a two-name variadic option are known",
          withoutPositionals(["--allowedTools", "Bash(git *)", "Edit"])
          == ["--allowedTools", "Bash(git *)", "Edit"]
              && withoutPositionals(["--allowed-tools", "Bash(git *)", "Edit"])
              == ["--allowed-tools", "Bash(git *)", "Edit"])
    check("a one-value flag still stops at one",
          withoutPositionals(["--model", "fable", "tj3裡"]) == ["--model", "fable"])
    // An optional-value flag (`-r [value]`, commander) takes the next word when it is not a flag,
    // which is what "one" means here.
    check("an optional value is taken when it is there",
          withoutPositionals(["--resume", "abc", "stray"]) == ["--resume", "abc"])
    check("and nothing is invented when it is not",
          withoutPositionals(["--resume", "--model", "fable"]) == ["--resume", "--model", "fable"])
    // A flag carrying its own value consumes nothing, so the word after it is still a prompt.
    check("a --flag=value token takes no word with it",
          withoutPositionals(["--model=fable", "ship it"]) == ["--model=fable"])
    // The residual, asserted so it is a decision rather than a surprise: a flag in neither table is
    // assumed to take one value, because the opposite guess deletes arguments.
    check("an unknown option keeps the word after it",
          withoutPositionals(["--unknown-to-tally", "value"]) == ["--unknown-to-tally", "value"])
    // The arity table itself, at the three points the parse reads it.
    check("a known boolean is zero-arity", childFlagArity("--verbose") == .zero)
    check("a known value flag is one", childFlagArity("--model") == .one)
    check("a known list flag is variadic", childFlagArity("--add-dir") == .variadic)
    check("an unknown flag falls back to one", childFlagArity("--unknown-to-tally") == .one)
    check("a self-contained --flag=value consumes nothing", childFlagArity("--model=fable") == .zero)
    // The two sets must not overlap: a flag in both would be answered by whichever test runs first,
    // which is a coin flip written as a table.
    check("no flag is claimed by both arity sets",
          zeroValueChildFlags.isDisjoint(with: variadicChildFlags))
    // Every flag Tally itself injects has to be IN the table, or the launch it builds is parsed by
    // the fallback rather than by what the CLI actually does.
    for injected in ["--dangerously-skip-permissions", "--continue", "-c", "--print", "-p"] {
        check("Tally's own \"\(injected)\" is known to take no value",
              childFlagArity(injected) == .zero)
    }
    for injected in ["--model", "--effort", "--fallback-model", "--permission-mode", "--resume"] {
        check("Tally's own \"\(injected)\" is known to take one value",
              childFlagArity(injected) == .one)
    }

    // The same boundary, for the two readers next door. `flagValue` answers with the flag the user
    // ASKED for, not one they mentioned.
    check("a model flag in the prompt is not the session's model",
          flagValue(["--model", "fable", "--", "--model", "opus"], "--model") == "fable")
    check("and a flag that only appears in the prompt is not set at all",
          flagValue(["--", "--model", "opus"], "--model") == nil)
    check("removing pairs leaves the prompt exactly as it was",
          removingFlagPairs(["--model", "fable", "--", "--model", "opus"], ["--model"])
          == ["--", "--model", "opus"])
    check("with no marker it still strips throughout",
          removingFlagPairs(["--model", "fable", "--verbose"], ["--model"]) == ["--verbose"])

    // The supervisor strips Tally's OWN flags from the vector it hands the child, and that line is
    // only reachable with a real child, so the source carries it. It is the same edit as every other
    // one here: a `--no-handoff` past the marker is a word the user wrote, not a flag to consume.
    let loopSource = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("the supervisor source is readable from the relaunch checks", !loopSource.isEmpty)
    check("the supervisor drops its own flags from the options only",
          loopSource.contains(#"removingOption(removingOption(args, "--no-handoff"), "--no-follow")"#))
    check("and does not filter the whole vector for them",
          !loopSource.contains(#"args.filter { $0 != "--no-handoff""#))

    // MARK: - 24f2. No relaunch path carries a prompt

    // The structural claim, walked end to end rather than asserted of one function: whatever a
    // poisoned session was launched with, nothing downstream of the relaunch can hand a positional
    // to a child - not the args the respawn uses, and not the argv a self-update execs into the new
    // build, which is how the two live fossils survived their upgrades in the first place.
    //
    // The fossil words are checked by NAME. A vector comparison would pass just as well, but this
    // says what the test is for, and it keeps passing when the surrounding flags are rearranged.
    let poisoned = ["--dangerously-skip-permissions", "--fallback-model", "opus", "tj3裡",
                    "--model", "fable", "--", "u0v49"]
    let cleaned = relaunchArgs(poisoned, sessionID: "abc", sameAccount: true)
    for fossil in ["tj3裡", "u0v49"] {
        check("the relaunch args drop \"\(fossil)\"", !cleaned.contains(fossil))
    }
    check("while everything the launch needs survives",
          cleaned == ["--resume", "abc", "--dangerously-skip-permissions", "--fallback-model",
                      "opus", "--model", "fable"])
    // Through a plan that rewrites the pairing and appends its own configured flags, which is the
    // one place a word can still enter after the strip above (a space-split `fallbackArgs`).
    let planned = planLaunchArgs(cleaned,
                                 plan: RelaunchPlan(target: movedTo, reason: "fallback",
                                                    countsFuse: false, model: "sonnet",
                                                    effort: "medium",
                                                    extraArgs: ["--append-system-prompt", "be",
                                                                "brief"]))
    check("a stray word in the configured fallback flags does not reach the child",
          !planned.contains("brief"))
    check("and the flag it belongs to still does",
          planned.contains("--append-system-prompt") && planned.contains("be"))
    for fossil in ["tj3裡", "u0v49"] {
        check("the planned args are still free of \"\(fossil)\"", !planned.contains(fossil))
    }
    // And across the exec, where the argv is written by one build and read by the next.
    let execArgv = selfUpdateArgv(binary: "/usr/local/bin/tally", id: "a", label: "A", home: "/h",
                                  follow: true, args: planned)
    let execChildArgs = parseResuperviseArgs(Array(execArgv.dropFirst(2))).childArgs
    check("the argv a self-update execs carries the cleaned args", execChildArgs == planned)
    for fossil in ["tj3裡", "u0v49", "brief"] {
        check("so the new build never sees \"\(fossil)\" either", !execChildArgs.contains(fossil))
    }
    // The existing-damage half: the new image strips what the OLD build handed it, so a session
    // already carrying a fossil cleans itself at its next upgrade rather than needing a human. Only
    // on a RESUMED start - a first launch's positional is the prompt the user just typed.
    check("a resumed supervisor strips the argv it inherited",
          loopSource.contains("if resumed { launchArgs = withoutPositionals(launchArgs) }"))
    check("and a first launch hands its child what the user typed",
          !loopSource.contains("launchArgs = withoutPositionals(removingOption("))
}
