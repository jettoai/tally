import Foundation

// The two halves of one hole: `tally project set --model "opus; touch /tmp/x"` ran the touch on the
// next bare `claude`, because the PATH shim `eval`s every line `tally launch-dir` prints. Emission
// quoting (`shellSingleQuoted`, LaunchDir.swift, where the mechanism is written down) makes those
// lines data; the entrance check (`isLaunchAxisValue`) keeps such a value out of the file at all.
//
// Runs as functions main.swift calls, which owns the shared harness (`check`, `tmp`, `claude`).

/// The eval side: what bash makes of the lines, rather than what they look like to us.
func runShellSafetyChecks() {
    let evalScript = tmp.appendingPathComponent("exports.sh")
    // Run the lines exactly as the shim does - `eval "$(…)"` over the whole output - and ask bash
    // what it made of them. Asserting on the string alone would only pin the quoting style we
    // happened to write; this pins the property the quoting is for.
    func evaluated(_ lines: [String], reading variable: String) -> String {
        try? lines.joined(separator: "\n").write(to: evalScript, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c",
                             "eval \"$(cat '\(evalScript.path)')\"; printf %s \"${\(variable)}\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: out, encoding: .utf8) ?? ""
    }

    // Each payload is a different way to reach a shell, and the marker file is how we know none of
    // them did: a value that round-trips could still have run something on the way.
    let marker = tmp.appendingPathComponent("injected")
    for payload in ["opus; touch \(marker.path)",
                    "opus && touch \(marker.path)",
                    "opus$(touch \(marker.path))",
                    "opus`touch \(marker.path)`",
                    "opus $(touch \(marker.path))"] {
        try? FileManager.default.removeItem(at: marker)
        let lines = launchExportLines(claude, home: "/Users/u/.claude2", model: payload)
        check("a model carrying `\(payload.prefix(12))…` reaches the CLI as text",
              evaluated(lines, reading: "ANTHROPIC_MODEL") == payload)
        check("…and the shell ran none of it",
              !FileManager.default.fileExists(atPath: marker.path))
    }

    // The home is interpolated into a line of the same script, and reaches it from the account list
    // rather than from a profile - a different source, the same lack of quoting.
    try? FileManager.default.removeItem(at: marker)
    let homePayload = "/Users/u/.claude2; touch \(marker.path)"
    check("the config home is data too, not only the model",
          evaluated(launchExportLines(claude, home: homePayload), reading: "CLAUDE_CONFIG_DIR")
              == homePayload)
    check("…with nothing run on its behalf either",
          !FileManager.default.fileExists(atPath: marker.path))

    // The ordinary cases broken by the same missing quotes, which would have stayed broken had the
    // fix only escaped the characters an attack uses.
    check("a config home containing a space survives the round trip",
          evaluated(launchExportLines(claude, home: "/Users/u/My Configs/.claude2"),
                    reading: "CLAUDE_CONFIG_DIR") == "/Users/u/My Configs/.claude2")
    check("so does one containing the one character a quoted word cannot hold",
          evaluated(launchExportLines(claude, home: "/Users/o'brien/.claude2"),
                    reading: "CLAUDE_CONFIG_DIR") == "/Users/o'brien/.claude2")
    check("and a model containing it",
          evaluated(launchExportLines(claude, home: "/Users/u/.claude", model: "o'brien"),
                    reading: "ANTHROPIC_MODEL") == "o'brien")

    // Quoting the values must not have quoted the fixed lines: the status line reads the markers as
    // `1`/`0`, and the default home has to UNSET rather than export anything at all.
    let unsteered = launchExportLines(claude, home: defaultHome(claude))
    check("the default home still unsets the variable rather than exporting one",
          unsteered.contains("unset CLAUDE_CONFIG_DIR"))
    check("the Tally markers stay bare literals", unsteered.contains("export TALLY_LAUNCHED=1")
              && unsteered.contains("export TALLY_SUPERVISED=0"))
}

/// The other line the shim evals, and the only one that is not environment: the argument vector a
/// bare `codex` is handed back, carrying the permission mode Settings promised it
/// (`shimLaunchArgs`, LaunchDir.swift).
///
/// The mode had been reaching `tally codex` and nothing else. A bare `codex` goes through the PATH
/// shim, which can only be spoken to in the environment, and codex has no variable for its sandbox
/// or its approval policy - so Settings read bypass while the session came up asking for approval
/// on its first command (owner-reported 2026-09-07).
func runShimArgvChecks() {
    let evalScript = tmp.appendingPathComponent("argv.sh")
    /// What the shell's positional parameters are once it has eval'd `line`, each wrapped so an
    /// argument that was split in two is visible as two. Run the way the shim runs it, because the
    /// property under test is what bash made of the quoting, not what the string looks like to us.
    func positionals(after line: String, given argv: [String]) -> String {
        try? line.write(to: evalScript, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c",
                            "eval \"$(cat '\(evalScript.path)')\"; printf '[%s]' \"$@\"", "sh"]
            + argv
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: out, encoding: .utf8) ?? ""
    }

    // The line at all: codex, asked by a shim that said it could listen (the marker), on the factory
    // default mode. This is the row the whole exchange exists for.
    let bypass = shimLaunchArgs(codex, policy: appDefaults, arguments: ["--"])
    check("a bare codex launch is handed the permission mode Settings shows",
          bypass?.contains("--dangerously-bypass-approvals-and-sandbox") == true)
    // …and NOTHING else. The model and the effort are left to the CLI's own settings on this path
    // deliberately (`launchSteering`), and a vector carrying them would override a per-directory
    // choice the user made in codex itself.
    check("…and only that: no model, no effort rides the shim",
          bypass?.contains("-m") == false && bypass?.contains("-c") == false)

    // The three silences, each of which would be a different way to break a launch.
    check("a shim that did not say it can listen is told nothing",
          shimLaunchArgs(codex, policy: appDefaults, arguments: []) == nil)
    check("…nor is claude, whose bare launches this does not change",
          shimLaunchArgs(claude, policy: appDefaults, arguments: ["--"]) == nil)
    check("…nor a launch that typed its own sandbox",
          shimLaunchArgs(codex, policy: appDefaults,
                         arguments: ["--", "-s", "read-only"]) == nil)
    // Nothing to add is not the same as an empty answer: a vector printed here REPLACES what the
    // user typed, so a launch owed no flag is never round-tripped through our quoting at all.
    var noMode = appDefaults
    noMode.permissionMode = nil
    check("…nor a launch with no mode to apply",
          shimLaunchArgs(codex, policy: noMode, arguments: ["--", "hello"]) == nil)

    // MARK: - The spellings and the subcommands codex's own parser knows about

    // Everything below asserts the WHOLE vector, word for word, rather than searching it for a
    // flag: what is at stake is a launch coming up with a permission it was never given, and a
    // substring test cannot tell an argument that was left alone from one that was rewritten.
    //
    // Through `applyLaunchDefaults` because that is where the rule lives - the shim reaches it
    // through `shimLaunchArgs` and `tally codex` through main.swift, so both paths are this one.
    // The mode-only policy is what the shim hands over; the full `appDefaults` is what a typed
    // `tally codex` carries, and the rows that use it are the rows where the other two axes matter.
    var modeOnly = LaunchPolicy()
    modeOnly.permissionMode = "bypass"

    // ONE CHOICE, MANY SPELLINGS. clap takes three for a single flag - separated (`-s read-only`),
    // joined (`--sandbox=read-only`, `-s=read-only`) and attached (`-sread-only`) - the config
    // override says the same thing again in its own three, and naming a `--profile` says it through
    // a file. Every row below was run through codex-cli 0.153.4 and accepted by it
    // (CodexLaunchArgs.swift records the measurement and its date).
    //
    // What a missed spelling costs depends on the mode, and both halves are bad. Under the factory
    // bypass the injected flag WINS SILENTLY: `codex exec`'s own banner reports
    // `sandbox: danger-full-access` for a launch that typed `--sandbox=read-only`, so a session
    // deliberately confined to reading gets the whole machine with nothing on screen to say so.
    // Under plan or acceptEdits the same miss stops the launch dead: a second `--sandbox` is
    // `error: the argument '--sandbox <SANDBOX_MODE>' cannot be used multiple times`, and `--yolo`
    // (the bypass flag's undocumented second name) fails the same way against an injected bypass.
    for spelling in [["-s", "read-only"], ["--sandbox=read-only"], ["-sread-only"],
                     ["-s=read-only"], ["--ask-for-approval=never"], ["-anever"], ["-a=never"],
                     ["--yolo"], ["--config", "sandbox_mode=read-only"],
                     ["--config=sandbox_mode=read-only"], ["-csandbox_mode=read-only"],
                     ["-c=sandbox_mode=read-only"], ["-capproval_policy=never"],
                     // TOML's own spacing, which codex keeps: measured effective, not merely
                     // accepted - `codex doctor -c 'approval_policy = "never"'` reports
                     // `approval policy Never` against a baseline of `OnRequest`.
                     ["-c", "sandbox_mode = \"read-only\""],
                     ["--config=approval_policy = \"never\""],
                     ["-c=sandbox_mode = \"read-only\""],
                     // A quoted key, which 0.153.4 parses and then ignores (doctor stays on the
                     // baseline). Read as a choice anyway: standing down leaves codex's own config
                     // deciding, which is the safe direction and is already right for the day this
                     // spelling starts working.
                     ["-c", "\"sandbox_mode\"=\"read-only\""],
                     ["-p", "ro"], ["-pro"], ["-p=ro"], ["--profile", "ro"], ["--profile=ro"]] {
        check("`codex \(spelling.joined(separator: " "))` is left exactly as it was typed",
              applyLaunchDefaults(spelling, policy: modeOnly, providerID: "codex") == spelling)
    }
    // Per axis, not per launch: the sandbox they typed is a statement about the sandbox, and the
    // model and the effort they said nothing about are still ours to fill in.
    check("…and typing one suppresses that axis alone",
          applyLaunchDefaults(["-sread-only"], policy: appDefaults, providerID: "codex")
              == ["-sread-only", "-m", "fable", "-c", "model_reasoning_effort=\"high\""])
    // The other two axes are readable through the same option and are read the same way, so a
    // `-c model=…` is the model this launch chose and the spacing does not change the answer.
    check("a `-c model=` override is the model this launch runs",
          applyLaunchDefaults(["-c", "model=\"gpt-5.6-sol\""], policy: appDefaults,
                              providerID: "codex")
              == ["-c", "model=\"gpt-5.6-sol\"", "--dangerously-bypass-approvals-and-sandbox",
                  "-c", "model_reasoning_effort=\"high\""])
    check("…and a spaced `-c model_reasoning_effort = …` is the effort it chose",
          applyLaunchDefaults(["-c", "model_reasoning_effort = \"low\""], policy: appDefaults,
                              providerID: "codex")
              == ["-c", "model_reasoning_effort = \"low\"",
                  "--dangerously-bypass-approvals-and-sandbox", "-m", "fable"])

    // A SUBCOMMAND IS NOT A SESSION. These are the interactive session's own flags, and 25 of the
    // 33 names codex's parser matches as a subcommand exit 2 rather than ignore one, `review` and
    // `login` among them - so with the factory default of bypass, installing the shim turned a new
    // user's first `codex login` into a command that would not start. The effort still goes in:
    // `-c` is clap's global option and every subcommand takes it, including behind a nested one
    // (`codex mcp list -c …`). The rows carry an alias (`a` for apply) and a name that appears in
    // no `codex --help` output (`execpolicy`), both of which are how a table like this loses an
    // entry, and two shapes that only a real scan gets right: a subcommand behind an option's value
    // (`-C /tmp doctor`) and one behind a joined option.
    let effort = ["-c", "model_reasoning_effort=\"high\""]
    // The MODEL still reaches them, in the spelling they do take. `codex review -m gpt-5.6-sol` is
    // `error: unexpected argument '-m' found` while `codex review -c 'model="gpt-5.6-sol"'` exits
    // 0, so the axis that used to be dropped here is now said the way the effort has always been
    // said, and `tally codex review` runs the model the project declared.
    let modelOverride = ["-c", "model=\"fable\""]
    for subcommand in [["review", "--commit", "abc"], ["login"], ["mcp", "list"], ["apply"], ["a"],
                       ["agents"], ["-C", "/tmp", "doctor"]] {
        check("`codex \(subcommand.joined(separator: " "))` is handed no session flag",
              applyLaunchDefaults(subcommand, policy: appDefaults, providerID: "codex")
                  == subcommand + modelOverride + effort)
    }
    check("…while one that named its own model keeps the name it typed",
          applyLaunchDefaults(["--config=model=\"x\"", "app-server"], policy: appDefaults,
                              providerID: "codex")
              == ["--config=model=\"x\"", "app-server"] + effort)
    // …and the eight that DO take them still get them, measured with the flag where this puts it:
    // behind the subcommand's own arguments (`codex exec 'hello world' -s read-only`).
    for subcommand in [["exec", "run the tests"], ["e", "run the tests"], ["resume", "abc123"],
                       ["fork"]] {
        check("`codex \(subcommand.joined(separator: " "))` still gets the whole launch",
              applyLaunchDefaults(subcommand, policy: appDefaults, providerID: "codex")
                  == subcommand + ["--dangerously-bypass-approvals-and-sandbox", "-m", "fable"]
                      + effort)
    }
    // Accept edits reaches all eight too, which it only does because its approval half is a config
    // override. `--ask-for-approval` exists on two of these names; `codex exec`, the launch this
    // repo's own automation runs, is not one of them. Standing down there would have handed the
    // question back to codex's configuration, and a configuration set to danger-full-access is
    // WIDER than the workspace-write the Settings row claims to have applied.
    var acceptPolicy = appDefaults
    acceptPolicy.permissionMode = "acceptEdits"
    let acceptEdits = ["-s", "workspace-write", "-c", "approval_policy=\"never\""]
    check("accept edits reaches `codex exec`, which has no approval FLAG to take",
          applyLaunchDefaults(["exec", "hi"], policy: acceptPolicy, providerID: "codex")
              == ["exec", "hi"] + acceptEdits + ["-m", "fable"] + effort)
    check("…and `codex resume`, in the one spelling",
          applyLaunchDefaults(["resume", "abc123"], policy: acceptPolicy, providerID: "codex")
              == ["resume", "abc123"] + acceptEdits + ["-m", "fable"] + effort)
    // The bare session: what a shim-routed `codex` with nothing typed after it actually is, and the
    // launch the whole exchange exists for. It had been named in the row above and never built, so
    // the one shape that reaches every Tally user by default was asserted by its own title alone.
    check("…and the bare session, which types nothing at all",
          applyLaunchDefaults([], policy: acceptPolicy, providerID: "codex")
              == acceptEdits + ["-m", "fable"] + effort)
    check("…and stands down for the subcommands with no sandbox flag either",
          applyLaunchDefaults(["review"], policy: acceptPolicy, providerID: "codex")
              == ["review"] + modelOverride + effort)
    var planPolicy = appDefaults
    planPolicy.permissionMode = "plan"
    check("…while plan, which needs only the sandbox, still reaches `codex exec`",
          applyLaunchDefaults(["exec", "hi"], policy: planPolicy, providerID: "codex")
              == ["exec", "hi", "-s", "read-only", "-m", "fable"] + effort)
    // …while a PROMPT is a session, and gets everything it always got. That distinction is the
    // whole reason the table above is a table and not "anything that is not a flag".
    check("a typed prompt is still the session it always was",
          applyLaunchDefaults(["fix the flaky test"], policy: appDefaults, providerID: "codex")
              == ["fix the flaky test", "--dangerously-bypass-approvals-and-sandbox",
                  "-m", "fable"] + effort)
    // …and so is a session whose only word is an option's VALUE. `/tmp` is not a subcommand, but a
    // scan that did not know `--add-dir` takes one would offer it as the first positional, find no
    // subcommand by that name, and reach the same answer for the wrong reason - which is exactly
    // what would go on being true the day someone adds an option and forgets the table.
    check("`codex --add-dir /tmp` is a session whose option took a value",
          applyLaunchDefaults(["--add-dir", "/tmp"], policy: modeOnly, providerID: "codex")
              == ["--add-dir", "/tmp", "--dangerously-bypass-approvals-and-sandbox"])
    check("…and the scan says so in its own words, rather than by the name not matching",
          codexFirstPositional(["--add-dir", "/tmp"]) == nil)
    // And none of it reaches the other provider, whose vocabulary this is not: `review` is a word
    // in a claude prompt, and claude's own three axes go in behind it as they always have.
    check("claude reads none of codex's table",
          applyLaunchDefaults(["review", "--commit", "abc"], policy: appDefaults,
                              providerID: "claude")
              == ["review", "--commit", "abc", "--dangerously-skip-permissions", "--model",
                  "fable", "--fallback-model", "opus", "--effort", "high"])
    // The shim path says the same thing in its own words: nothing to add is not an empty answer,
    // and a `set --` line printed for a subcommand launch would replace what the user typed.
    check("so the shim prints no vector for a subcommand launch either",
          shimLaunchArgs(codex, policy: appDefaults, arguments: ["--", "review"]) == nil)

    // The words the user typed, through the line and out the other side. A prompt with a space in
    // it arriving as two arguments is a launch that runs something else; the one character a quoted
    // word cannot hold is the shape that breaks a naive quoting.
    let typed = ["fix the tally shim", "o'brien's dir", "$HOME", "a;b"]
    guard let vector = shimLaunchArgs(codex, policy: appDefaults, arguments: ["--"] + typed) else {
        return check("the typed arguments survive the line that carries the flags", false)
    }
    // The flag lands BEHIND the typed words, which is where `injectingOptions` puts it when there
    // is no bare `--` to be in front of: with no marker the whole vector is options, and codex
    // reads a flag after a positional the same way claude does on the path that has always done
    // this. What matters here is that all five words arrive as five words.
    let expected = typed.map { "[\($0)]" }.joined()
        + "[--dangerously-bypass-approvals-and-sandbox]"
    check("the typed arguments survive the line that carries the flags",
          positionals(after: launchArgvLine(vector), given: ["ignored"]) == expected)
}

/// codex's model axis in every spelling its parser takes, the images that swallow the word behind
/// them, and the three names an appended `-c` never reaches.
///
/// Split out from `runShimArgvChecks` because these are the same question asked of a DIFFERENT
/// reader: not "was a permission stated" but "was a model stated, and which one", asked once by the
/// injection and once by the account pick. Every spelling below was run through codex-cli 0.153.4
/// and accepted by it, with an unknown flag as the control (`codex --bogus --version` exits 2);
/// CodexLaunchArgs.swift records each measurement beside the table it produced.
func runCodexModelSpellingChecks() {
    var modelAxisOnly = LaunchPolicy()
    modelAxisOnly.model = "fable"

    // EVERY SPELLING, ONCE, asked of both readers below: one list rather than a list each, because
    // a list each is exactly what drifted.
    let spellings = [["-m", "gpt-5.6-sol"], ["-mgpt-5.6-sol"], ["-m=gpt-5.6-sol"],
                     ["--model", "gpt-5.6-sol"], ["--model=gpt-5.6-sol"],
                     ["-c", "model=\"gpt-5.6-sol\""], ["--config=model=gpt-5.6-sol"],
                     ["-cmodel=gpt-5.6-sol"], ["-c=model=gpt-5.6-sol"],
                     // TOML's own spacing and quoting, which codex keeps.
                     ["-c", "model = \"gpt-5.6-sol\""]]

    // ONE MODEL, MANY SPELLINGS. A second `-m` behind a typed one is `error: the argument
    // '--model <MODEL>' cannot be used multiple times`, exit 2: the launch does not start at all,
    // and the guard knew only the two separated words.
    for spelling in spellings {
        check("`codex \(spelling.joined(separator: " "))` gets no second model appended",
              applyLaunchDefaults(spelling, policy: modelAxisOnly, providerID: "codex") == spelling)
    }
    // A dangling option named the axis just as loudly, and what follows an injection is not a name.
    check("a dangling -m is still the axis being typed",
          applyLaunchDefaults(["-m"], policy: modelAxisOnly, providerID: "codex") == ["-m"])

    // THE SAME READER ANSWERS THE ACCOUNT PICK, which is the half that decides which accounts have
    // the window this launch needs. Read apart, the two lists drifted and a launch was scored for a
    // model it was not running.
    for spelling in spellings {
        check("`codex \(spelling.joined(separator: " "))` is the model the pick scores for",
              launchPrimaryModel(spelling, providerID: "codex") == "gpt-5.6-sol")
    }
    // Measured off `codex exec`'s own startup banner: `-m gpt-6-astra -c 'model="gpt-5.6-sol"'`
    // comes up `model: gpt-6-astra`, so the flag outranks the override when a launch types both.
    check("the flag outranks the override when a launch types both",
          launchPrimaryModel(["-c", "model=\"gpt-5.6-sol\"", "-m", "gpt-6-astra"],
                             providerID: "codex") == "gpt-6-astra")
    check("a dangling -m names no model, so the caller falls back to the configured one",
          launchPrimaryModel(["-m"], providerID: "codex") == nil)
    check("…and neither does one handed another flag",
          launchPrimaryModel(["-m", "--yolo"], providerID: "codex") == nil)
    check("a -m inside the prompt is a word, not a declaration",
          launchPrimaryModel(["--", "compare", "-m", "gpt-5.6-sol"], providerID: "codex") == nil)
    // And the answer for the launches that reach their model through the override: the pick reads
    // what the injection just wrote, in the spelling the injection had to use.
    check("the pick reads the model a `codex review` launch was given",
          launchPrimaryModel(applyLaunchDefaults(["review"], policy: modelAxisOnly,
                                                 providerID: "codex"),
                             providerID: "codex") == "fable")

    // IMAGES SWALLOW THE WORD BEHIND THEM. `-i, --image <FILE>...` takes every word up to the next
    // option, so the scan that skipped ONE of its values read the launch as running something else:
    // measured, `codex -i a.png doctor` is the interactive session with two images (exit 1,
    // `Error: stdin is not a terminal`) and not the doctor.
    check("`codex -i a.png review` is the session codex reads it as",
          codexSubcommand(["-i", "/tmp/a.png", "review"]) == nil)
    check("…and a second image behind the first changes nothing",
          codexSubcommand(["-i", "/tmp/a.png", "/tmp/b.png", "review"]) == nil)
    check("…a lone dash is an image value too, not the end of the list",
          codexSubcommand(["-i", "/tmp/a.png", "-", "doctor"]) == nil)
    check("…while an option ends the list, so the word after THAT is the subcommand again",
          codexSubcommand(["-i", "/tmp/a.png", "-s", "read-only", "doctor"]) == "doctor")
    check("…and the attached and joined spellings carry exactly one image",
          codexSubcommand(["-i/tmp/a.png", "doctor"]) == "doctor"
              && codexSubcommand(["--image=/tmp/a.png", "doctor"]) == "doctor")
    // Which is a launch getting the session flags it is owed, not merely a name being read right,
    // and on `appDefaults` because a typed `tally codex` states all three axes at once.
    check("`codex -i a.png review` gets the whole session it turned out to be",
          applyLaunchDefaults(["-i", "/tmp/a.png", "review"], policy: appDefaults,
                              providerID: "codex")
              == ["-i", "/tmp/a.png", "review", "--dangerously-bypass-approvals-and-sandbox",
                  "-m", "fable", "-c", "model_reasoning_effort=\"high\""])

    // THE THREE NAMES AN APPENDED `-c` NEVER REACHES. `-c` is clap's global option and 30 of the 33
    // names take one at the end of the vector, which is why the effort had no gate at all; these
    // three are about the POSITION. `codex help -c …` is `error: unrecognized subcommand '-c'`,
    // exit 2. `codex sandbox echo hi -c model_reasoning_effort="high"` prints
    // `hi -c model_reasoning_effort="high"`, so the override silently became an argument of the
    // sandboxed program. `codex execpolicy check --rules … ls` is the same shape, shown by an
    // unknown flag past the command being swallowed where `codex exec hi --bogusflag` exits 2.
    for subcommand in [["help"], ["help", "review"], ["sandbox", "echo", "hi"],
                       ["sandbox"], ["execpolicy", "check", "--rules", "r", "ls"]] {
        check("`codex \(subcommand.joined(separator: " "))` is handed nothing at all",
              applyLaunchDefaults(subcommand, policy: appDefaults, providerID: "codex")
                  == subcommand)
    }
    // …and the neighbours that DO take it still do, so the gate is three names and not a mood.
    check("…while `codex doctor` still gets both overrides at the end",
          applyLaunchDefaults(["doctor"], policy: appDefaults, providerID: "codex")
              == ["doctor", "-c", "model=\"fable\"", "-c", "model_reasoning_effort=\"high\""])
}

/// The entrance side: what `tally project set` may store as a model or an effort.
func runAxisValueChecks(setSource: String) {
    check("a plain model name is storable", isLaunchAxisValue("opus"))
    check("…so is a fully qualified one", isLaunchAxisValue("us.anthropic.claude-opus-4:1"))
    check("…and a versioned one", isLaunchAxisValue("gpt-5.6-sol"))
    check("…and an effort", isLaunchAxisValue("xhigh"))
    check("a command separator is not", !isLaunchAxisValue("opus; touch /tmp/x"))
    check("nor a substitution", !isLaunchAxisValue("opus$(touch /tmp/x)"))
    check("nor a backquote", !isLaunchAxisValue("opus`id`"))
    check("nor a space, which is how one word becomes two", !isLaunchAxisValue("opus /tmp/x"))
    check("nor a quote, the one character quoting itself has to work around",
          !isLaunchAxisValue("o'brien"))
    check("nor a newline, which ends the export line and starts a command",
          !isLaunchAxisValue("opus\ntouch /tmp/x"))
    check("nor nothing at all", !isLaunchAxisValue(""))
    // The dangling option: `optionValue` returns whatever token follows the flag, so
    // `tally project set --model --account "Claude 4"` offers `--account` as the model. The dash is
    // a legal character, so this is the only rule that catches it - and what got stored was injected
    // straight back as `--model --account`, breaking the very launch the profile was steering.
    check("a flag offered as a value is not one", !isLaunchAxisValue("--account"))
    check("…in either spelling", !isLaunchAxisValue("-m"))
    check("…and a bare dash is not a name either", !isLaunchAxisValue("-"))
    check("while a dash INSIDE a name is what half of them contain",
          isLaunchAxisValue("gpt-5.6-sol") && isLaunchAxisValue("claude-opus-4-1"))
    // ASCII only: a homoglyph reads as a letter to `isLetter` and as a different model to everyone
    // else, so accepting it stores a name that can never match anything.
    check("nor a letter that only looks like one", !isLaunchAxisValue("op\u{0445}s"))

    /// Whether `first` appears before `second` in `text` - both have to be there for the answer to
    /// mean anything, so an absent one is a failure rather than a default.
    func precedes(_ first: String, _ second: String, in text: String) -> Bool {
        guard let a = text.range(of: first), let b = text.range(of: second) else { return false }
        return a.lowerBound < b.lowerBound
    }
    check("set checks the values it was handed", setSource.contains("isLaunchAxisValue(value)"))
    check("…before it reads the file, so a refusal cannot rewrite anything",
          precedes("isLaunchAxisValue", "readProjectPoliciesForWrite", in: setSource))
    // The refusal itself, read between the check and the first thing `set` does after it. Bounded
    // that way rather than searched for across the whole function, where `return 2` from an earlier
    // guard would answer for it.
    let refusal = (setSource.components(separatedBy: "isLaunchAxisValue").last ?? "")
        .components(separatedBy: "let key = projectPolicyKey()").first ?? ""
    check("…and leaves with a usage error, saying nothing was changed",
          refusal.contains("nothing was changed") && refusal.contains("return 2"))
}
