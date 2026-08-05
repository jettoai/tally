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
