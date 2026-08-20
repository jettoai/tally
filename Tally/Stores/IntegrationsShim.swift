import Foundation

// The PATH interposer: `~/.tally/bin/claude` (and the same for codex), plus the marked PATH block in
// `~/.zshenv` that puts that directory first, so a bare `claude` follows the app's launch policy.
//
// A SHIM IS A PASS-THROUGH FIRST AND A POLICY SECOND. Everything it decides happens before the real
// binary starts, and the one promise it makes to the machine is that the launch it hands over is the
// launch the user typed: the same arguments, the same environment bar the one variable it steers,
// and the same standard input. The last of those is the easiest to lose by accident and the hardest
// to notice - see the fd 3 clause in `shimScript`.
extension IntegrationsStore {
    // MARK: Paths

    /// A per-provider PATH interposer: bare `claude` / `codex` invocations follow the launch
    /// policy. Both shims share one bin dir and one PATH block.
    enum Shim: String, CaseIterable {
        case claude, codex
        var envKey: String { self == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME" }
        var scriptURL: URL { IntegrationsStore.binDirURL.appendingPathComponent(rawValue) }
        var manifestKey: String { "\(rawValue)Shim" }
    }

    /// Bump when the shim script changes; the store flags older installs for reinstall, and the
    /// launch-time upkeep rewrites them. Pinned to the script's own text by the suite, so an edit
    /// that skips the bump goes red (tests/integrations/shimscriptchecks.swift).
    nonisolated static let shimVersion = 4

    /// The header line every script this app writes carries, and the only thing that says a file in
    /// our own bin directory came from us rather than from somebody else.
    nonisolated static let shimHeader = "# tally-shim v"

    /// Whether a script on disk IS the text this build writes, asked in the two places that care:
    /// the word the row carries, and the upkeep that rewrites an older one. ONE SPELLING, because
    /// two that drifted would leave a row reading Installed over a file the upkeep rewrites at
    /// every launch. The colon is part of it, so v4 is not read out of v40.
    static func shimIsCurrent(_ script: String) -> Bool {
        script.contains("\(shimHeader)\(shimVersion):")
    }

    /// Claude Code's marker for a session it started itself, spelled here as well as in the CLI
    /// (`childSessionMarker`, TallyCLI/Snapshot.swift, which is where the mechanism is written
    /// down) because the app target does not compile that file. A drift between the two spellings
    /// would leave the shim watching a variable nothing ever sets, which looks exactly like a
    /// machine that never leaks, so the suite pins them to each other.
    nonisolated static let childSessionMarker = "CLAUDE_CODE_CHILD_SESSION"

    /// The shim itself: ask `tally launch-dir` (which honours Off/Manual/Auto), then hand off to
    /// the first real binary on PATH that isn't this file. Pure bash, no dependencies; fail open.
    ///
    /// The claude shim carries one clause the codex shim does not, and it is the same decision
    /// `tally claude` makes in `inheritedSessionEnvironment`: an exported config home is the user's
    /// own choice, UNLESS it was inherited from a session rather than typed. It has to be decided
    /// here rather than inside `tally launch-dir`, because what gives a leak away is a terminal on
    /// stdout, and that command prints into a command substitution, which never is one.
    static func shimScript(_ shim: Shim) -> String {
        let unexported = "[[ -z \"${\(shim.envKey):-}\" ]]"
        // Claude only: the marker is Claude Code's, and a codex environment says nothing by
        // carrying it.
        let claude = shim == .claude
        let precedence = claude
            ? "# An exported \(shim.envKey) wins, unless it was inherited rather than typed (below)."
            : "# An explicitly exported \(shim.envKey) always wins."
        let leakClause = claude ? """
        # A terminal started from inside a Claude Code session inherits that session's config home
        # AND its child marker, so every window opened afterwards is stuck on that one account.
        # Claude Code spawns its real children through a pipe: the marker with stdout on a PIPE is a
        # real child, which follows its parent's home on purpose, while the same marker with stdout
        # on a TERMINAL cannot be describing this process at all. Dropping the marker is what makes
        # the session save its transcript again, so it happens whether or not Tally steers as well.
        # `+x` asks whether the variable is SET, which is the question `inheritedSessionEnvironment`
        # asks of it: an entrance that read an empty value as no marker would answer differently
        # from the other one, which is the whole defect this clause exists to close.
        inherited=0
        if [[ -t 1 && -n "${\(childSessionMarker)+x}" ]]; then
          inherited=1
          unset \(childSessionMarker)
        fi

        """ : ""
        let steered = claude ? "{ \(unexported) || (( inherited )); }" : unexported
        // The account half of the same repair, and it belongs INSIDE the steering branch. `tally
        // launch-dir` is silent in two cases of its own (policy Off, no eligible account:
        // LaunchDir.swift), so the eval below produces no `export` at all - and the leaked home,
        // still in the environment, is then obeyed by the launch this branch decided to steer. The
        // CLI makes the identical repair with `unsetenv` (Snapshot.swift). Not in the leak clause,
        // which runs with no tally on PATH, where nothing may be steered anywhere.
        let dropLeaked = claude
            ? "  # Steering prints nothing when Tally is Off or has no eligible account, and the\n"
            + "  # leaked home would then be obeyed by the launch this branch chose to steer.\n"
            + "  (( inherited )) && unset \(shim.envKey)\n"
            : ""
        return """
        #!/bin/bash
        # tally-shim v\(shimVersion): route bare `\(shim.rawValue)` through the Tally launch policy.
        # Managed by Tally.app (Settings → Integrations); safe to delete.
        # Without Tally on PATH this passes straight through.
        \(precedence)
        set -u
        \(leakClause)if \(steered) && command -v tally > /dev/null 2>&1; then
        \(dropLeaked)  eval "$(tally launch-dir \(shim.rawValue) 2> /dev/null)" || true
        fi
        # THE CANDIDATE LIST ARRIVES ON FD 3, AND STDIN IS LEFT ALONE. Feeding the loop with
        # `done < <(which -a ...)` makes that pipe the standard input of the whole loop, so the
        # binary exec'd from inside it inherited an exhausted pipe where the caller's own stdin
        # should have been: `echo prompt | claude -p` read no prompt, and answered that it had been
        # given none. Every piped invocation on a machine with this shim installed was affected,
        # which is most of what scripts and hooks do with these two commands (v4).
        exec 3< <(which -a \(shim.rawValue))
        while IFS= read -r candidate <&3; do
          if [[ "$candidate" != "$HOME/.tally/bin/\(shim.rawValue)" ]]; then
            exec 3<&-
            exec "$candidate" "$@"
          fi
        done
        exec 3<&-
        echo "tally-shim: real \(shim.rawValue) not found on PATH" >&2
        exit 127
        """
    }

    // MARK: Status

    func shimStatus(_ shim: Shim) -> Status { shimStatuses[shim] ?? .notInstalled }

    /// Internal (not private) because the refresh that reads it lives in the other file.
    static func detectShim(_ shim: Shim) -> Status {
        // No script = not installed, full stop. The PATH block is SHARED between shims, so its
        // presence says nothing about THIS shim (installing codex alone must not make the claude
        // row read "broken").
        guard let script = try? String(contentsOf: shim.scriptURL, encoding: .utf8) else {
            return .notInstalled
        }
        let blockPresent = (try? String(contentsOf: zshenvURL, encoding: .utf8))?
            .contains(blockBegin) ?? false
        guard blockPresent else { return .broken(L("PATH entry is missing")) }
        return shimIsCurrent(script) ? .installed : .broken(L("Older version installed"))
    }

    // MARK: Install / remove

    func installShim(_ shim: Shim) {
        guard guardNotDev() else { return }
        lastError = nil
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Self.binDirURL, withIntermediateDirectories: true)
            try Self.shimScript(shim).write(to: shim.scriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.scriptURL.path)
            try Self.upsertBlock(in: Self.zshenvURL, body: "export PATH=\"$HOME/.tally/bin:$PATH\"")
            recordManifest(shim.manifestKey, paths: [shim.scriptURL.path, Self.zshenvURL.path])
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// Launch-time upkeep: a shim this app wrote at an older version is brought up to the current
    /// text, the same shape as `autoUpdateSkill` and `autoUpdateCompletion` (AppDelegate).
    ///
    /// IT EXISTS BECAUSE THE VERSION MARKER ON ITS OWN REACHES NOBODY. `detectShim` turns an older
    /// script into a Settings row reading Reinstall, and every launch until somebody opens that pane
    /// and presses it runs the old script - which for v3 meant handing the exec'd binary an
    /// exhausted pipe instead of the caller's stdin, on every `claude` and `codex` typed on the
    /// machine. A defect in a program that stands in front of two commands cannot wait behind a
    /// button.
    ///
    /// THE SAME RESTRAINT AS THE OTHER TWO: never an install where nothing is installed (an absent
    /// script is somebody's Remove, or a machine that never wanted this), and never a file that is
    /// not ours - a script in our own bin directory carrying no `tally-shim v` header was put there
    /// by somebody else and is left exactly as it is. The PATH block is not touched either: a
    /// missing one is the state a Reinstall press repairs, and this is upkeep rather than a press.
    func autoUpdateShims() {
        guard !BuildVariant.isUnshipped else { return }
        var rewritten = false
        for shim in Shim.allCases {
            guard let script = try? String(contentsOf: shim.scriptURL, encoding: .utf8),
                  script.contains(Self.shimHeader), !Self.shimIsCurrent(script) else { continue }
            guard (try? Self.shimScript(shim).write(to: shim.scriptURL, atomically: true,
                                                    encoding: .utf8)) != nil else { continue }
            // An atomic write is a new file, so the mode it lands with is whatever the umask allows
            // - and a shim that is not executable is a `claude` that stops working.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: shim.scriptURL.path)
            rewritten = true
        }
        if rewritten { refresh() }
    }

    func removeShim(_ shim: Shim) {
        guard guardNotDev() else { return }
        lastError = nil
        do {
            try? FileManager.default.removeItem(at: shim.scriptURL)
            // The PATH block serves every shim - strip it only when the last one is gone.
            let anyLeft = Shim.allCases.contains {
                FileManager.default.fileExists(atPath: $0.scriptURL.path)
            }
            if !anyLeft { try Self.stripBlock(in: Self.zshenvURL) }
            recordManifest(shim.manifestKey, paths: nil)
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }
}
