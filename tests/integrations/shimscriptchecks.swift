import Foundation

// The PATH shim's own decision: whether a bare `claude` is steered at all (IntegrationsStore.
// shimScript).
//
// The defect (found while fixing the same leak one entrance over, 5e0fb1b): `tally claude` learned
// that an inherited config home is not a hand pin, and the shim did not. A terminal started from
// inside a Claude Code session carries that session's CLAUDE_CONFIG_DIR and its child marker, so
// typing a bare `claude` in any window opened afterwards skipped the steering entirely and pinned
// the machine to one account, with the marker still in place telling Claude Code not to save the
// transcript. The signal is the same one the CLI reads (`inheritedSessionEnvironment`, TallyCLI/
// Snapshot.swift); only the shell it is written in differs.
//
// So the assertions here EXECUTE the generated script rather than reading it, under both shells and
// under a real pty, because every question this decision turns on is a question about what the
// shell made of the text: whether `-t 1` sees a terminal, whether `unset` reaches the exec'd child,
// whether the grouping binds the way it looks like it does.
//
// Runs as a function main.swift calls, which owns the shared harness (`check`, `textFingerprint`).

/// The digest of the two shim scripts that `shimVersion` stands for. Re-pin it in the same edit
/// that bumps the version, never on its own: `detectShim` calls any script carrying the current
/// number installed, so a script edited without a bump reaches fresh installs and nobody else, and
/// the machines left behind are the ones that have had the shim the longest. (The same pairing, and
/// the same reasoning, as `pinnedSkillDigest` in skillversionchecks.swift.)
let pinnedShimDigest = "24f2771111104f52"

/// What a bare `claude` inherited, once the shim was done with it.
private struct ShimRun {
    /// The provider config home the exec'd CLI saw, empty when it was not set at all.
    let home: String
    /// Claude Code's child marker as the exec'd CLI saw it, empty when it had been dropped.
    let marker: String
    /// Whether `tally launch-dir` was consulted, which is the steering decision itself.
    let steered: Bool
}

@MainActor
func runShimScriptChecks(tmp: URL) throws {
    let fm = FileManager.default
    let root = tmp.appendingPathComponent("shim")
    let shimDir = root.appendingPathComponent("home/.tally/bin")
    let realDir = root.appendingPathComponent("bin")
    let tallyDir = root.appendingPathComponent("tallybin")
    for dir in [shimDir, realDir, tallyDir] {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    func writeExecutable(_ url: URL, _ body: String) throws {
        try body.write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    let record = root.appendingPathComponent("record")
    let consulted = root.appendingPathComponent("consulted")
    let steeredHome = "/Users/u/.claude-steered"
    let leakedHome = "/Users/u/.claude-leaked"
    let marker = IntegrationsStore.childSessionMarker

    // The fixture is the shape of the machine the shim runs on: its own script first on PATH, the
    // real CLI further along, and `$HOME/.tally/bin` pointing at the first - which is how the script
    // recognises itself, so the home is overridden for the run rather than the path hard-coded.
    for shim in IntegrationsStore.Shim.allCases {
        try writeExecutable(shimDir.appendingPathComponent(shim.rawValue),
                            IntegrationsStore.shimScript(shim))
        // The real CLI: it records the environment it was handed and exits.
        try writeExecutable(realDir.appendingPathComponent(shim.rawValue), """
        #!/bin/bash
        { printf 'home=%s\\n' "${\(shim.envKey):-}"
          printf 'marker=%s\\n' "${\(marker):-}"; } > "$TALLY_TEST_RECORD"
        """)
    }
    // Standing in for `tally`: it records having been asked (the steering decision) and answers
    // with the one export line the shim evals.
    try writeExecutable(tallyDir.appendingPathComponent("tally"), """
    #!/bin/bash
    printf '%s\\n' "$*" >> "$TALLY_TEST_CONSULTED"
    if [ "${2:-}" = codex ]; then key=CODEX_HOME; else key=CLAUDE_CONFIG_DIR; fi
    printf "export %s='%s'\\n" "$key" "\(steeredHome)"
    """)

    /// Run the generated shim for real. `tty` puts it on a pty through `script`, which is the only
    /// way to exercise `-t 1` truthfully: a captured pipe would answer no to every row.
    ///
    /// Retried while the exec'd CLI leaves no record at all, because `script` occasionally fails to
    /// hand out a pty when these rows are run back to back and then exits having run nothing. That
    /// is an empty answer rather than a wrong one, so a retry cannot turn a red row green; what it
    /// buys is a suite that says the same thing every time it is run.
    func run(_ shim: IntegrationsStore.Shim, shell: String, tty: Bool,
             environment: [String: String], tallyOnPath: Bool = true) -> ShimRun {
        var path = [shimDir.path, realDir.path]
        if tallyOnPath { path.append(tallyDir.path) }
        path += ["/usr/bin", "/bin"]
        let script = shimDir.appendingPathComponent(shim.rawValue).path
        var written = ""
        for attempt in 1 ... 3 where written.isEmpty {
            try? Data().write(to: record)
            try? Data().write(to: consulted)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tty ? "/usr/bin/script" : shell)
            process.arguments = tty ? ["-q", "/dev/null", shell, script] : [script]
            // Built from nothing rather than inherited: this suite is itself usually run from
            // inside a Claude Code session, so the ambient environment carries the leak under test.
            process.environment = environment.merging([
                "PATH": path.joined(separator: ":"),
                "HOME": root.appendingPathComponent("home").path,
                "TALLY_TEST_RECORD": record.path,
                "TALLY_TEST_CONSULTED": consulted.path,
            ]) { given, _ in given }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            // A pipe nobody writes to, and NOT the terminal this suite was started from: `script`
            // forwards its own stdin to the pty, so an inherited terminal would be read (and put in
            // raw mode) by a test, and reading one from a background process group stops the
            // process outright - which is how a row that has nothing to do with stdin fails when
            // the suite happens to be run through a pipeline.
            let stdin = Pipe()
            process.standardInput = stdin
            guard (try? process.run()) != nil else { break }
            process.waitUntilExit()
            try? stdin.fileHandleForWriting.close()
            written = (try? String(contentsOf: record, encoding: .utf8)) ?? ""
            if written.isEmpty, attempt < 3 { Thread.sleep(forTimeInterval: 0.2) }
        }
        let fields = written.components(separatedBy: "\n")
        func field(_ name: String) -> String {
            fields.first { $0.hasPrefix("\(name)=") }
                .map { String($0.dropFirst(name.count + 1)) } ?? ""
        }
        let asked = ((try? String(contentsOf: consulted, encoding: .utf8)) ?? "")
        return ShimRun(home: field("home"), marker: field("marker"),
                       steered: asked.contains("launch-dir"))
    }

    // MARK: - The four rows, executed, under both shells

    // Both, because the script is read by whichever shell runs it: bash by its shebang, zsh when a
    // curious user runs `zsh ~/.tally/bin/claude` to see what it does. The grouping and the
    // arithmetic test below are the parts that could plausibly differ.
    for (name, shell) in [("bash", "/bin/bash"), ("zsh", "/bin/zsh")] {
        // Row 1: nothing exported, so there is nothing to override - steer, as it always did.
        let fresh = run(.claude, shell: shell, tty: true, environment: [:])
        check("[\(name)] a launch with no config home is steered",
              fresh.steered && fresh.home == steeredHome)

        // Row 2: a home the user exported by hand, with nothing contradicting it. Left alone, which
        // is the whole reason the plain test is "nothing exported" rather than "always steer".
        let handPinned = run(.claude, shell: shell, tty: true,
                             environment: ["CLAUDE_CONFIG_DIR": leakedHome])
        check("[\(name)] a hand-exported home is obeyed, not steered past",
              !handPinned.steered && handPinned.home == leakedHome)

        // Row 3: THE ONE THIS MAY NOT BREAK. The same marker with stdout on a pipe is a real child
        // session, spawned by a session's own shell and routed here by this very shim; following
        // its parent's home is what stops one conversation picking a second account halfway
        // through, and the marker is its own, not a leaked one.
        let child = run(.claude, shell: shell, tty: false,
                        environment: ["CLAUDE_CONFIG_DIR": leakedHome, marker: "1"])
        check("[\(name)] a real child session keeps its parent's home",
              !child.steered && child.home == leakedHome)
        check("[\(name)] …and keeps the marker that says it is one", child.marker == "1")

        // Row 4: THE FIX. The same environment with stdout on a terminal is a leak, because Claude
        // Code spawns children through a pipe and so cannot have spawned this one.
        let leaked = run(.claude, shell: shell, tty: true,
                         environment: ["CLAUDE_CONFIG_DIR": leakedHome, marker: "1"])
        check("[\(name)] an inherited home is steered rather than obeyed",
              leaked.steered && leaked.home == steeredHome)
        check("[\(name)] …and the marker goes with it, so the session saves its transcript",
              leaked.marker.isEmpty)

        // The same row with the marker set to nothing at all. `tally claude` reads presence rather
        // than value (`environment[childSessionMarker] != nil`), so a shim testing for a non-empty
        // string would send an environment down one entrance and not the other, which is the exact
        // shape of the defect this whole clause closes.
        let emptyMarker = run(.claude, shell: shell, tty: true,
                              environment: ["CLAUDE_CONFIG_DIR": leakedHome, marker: ""])
        check("[\(name)] a marker set to nothing is still a marker, as it is to the CLI",
              emptyMarker.steered && emptyMarker.home == steeredHome)

        // The marker outliving the variable: a leaked environment whose home has since been unset
        // still starts a session Claude Code refuses to file. Steering was already going to happen
        // here (row 1); what this row is about is the marker.
        let markerOnly = run(.claude, shell: shell, tty: true, environment: [marker: "1"])
        check("[\(name)] a leaked marker with no home is dropped too",
              markerOnly.marker.isEmpty && markerOnly.steered)

        // …and dropped whether or not Tally is around to steer, because the transcript half of the
        // repair has nothing to do with which account runs. The home stays put, which is the shim's
        // standing promise that a machine without `tally` behaves as though it were never installed.
        let noTally = run(.claude, shell: shell, tty: true,
                          environment: ["CLAUDE_CONFIG_DIR": leakedHome, marker: "1"],
                          tallyOnPath: false)
        check("[\(name)] the marker is dropped even with no tally on PATH to steer",
              noTally.marker.isEmpty && !noTally.steered && noTally.home == leakedHome)

        // The provider boundary, executed rather than argued: the marker is Claude Code's, and a
        // codex environment carrying it says nothing about codex. Same row 4 inputs, opposite
        // answer, so this cannot be satisfied by a shim that simply never steers.
        let codexLeak = run(.codex, shell: shell, tty: true,
                            environment: ["CODEX_HOME": leakedHome, marker: "1"])
        check("[\(name)] codex reads nothing into a marker that was never about it",
              !codexLeak.steered && codexLeak.home == leakedHome)
        let codexFresh = run(.codex, shell: shell, tty: true, environment: [:])
        check("[\(name)] …while a bare codex launch is still steered normally",
              codexFresh.steered && codexFresh.home == steeredHome)
    }

    // MARK: - The spellings the running script cannot check for itself

    // The variable name is a contract with a program that is not ours, and the app target does not
    // compile the CLI file that also spells it. A drift leaves the shim watching a variable nothing
    // sets, which is indistinguishable from a machine that never leaks - green, and silent.
    let cli = (try? String(contentsOfFile: "TallyCLI/Snapshot.swift", encoding: .utf8)) ?? ""
    check("the harness really read the CLI's own spelling of the marker",
          cli.contains("let childSessionMarker = \""))
    check("…and the shim watches exactly that variable",
          cli.contains("let childSessionMarker = \"\(marker)\""))

    let claudeScript = IntegrationsStore.shimScript(.claude)
    let codexScript = IntegrationsStore.shimScript(.codex)
    // The version marker `detectShim` looks for, which is the only reason an install ever updates.
    check("both scripts carry the version marker the detector reads",
          [claudeScript, codexScript].allSatisfy {
              $0.contains("tally-shim v\(IntegrationsStore.shimVersion)")
          })
    check("the codex shim carries no claude marker to test",
          !codexScript.contains(marker) && !codexScript.contains("-t 1"))
    // Pinned together, for the reason written on `pinnedShimDigest`.
    let digest = textFingerprint(claudeScript + codexScript)
    check("the shim text this build ships is the text its version stands for",
          digest == pinnedShimDigest)
    if digest != pinnedShimDigest {
        print("  the shim text changed: bump shimVersion, then pin \(digest)")
    }
}
