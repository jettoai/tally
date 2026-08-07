import Foundation

// Putting the prompt hooks back when something takes them out.
//
// The hooks live in the user's settings.json, which is not ours: it is their whole harness
// configuration, it is edited by hand, and on shared setups one physical file stands behind several
// config homes. Anything that rewrites it wholesale - another tool's config sync, a restore from a
// dotfiles repo, an editor saving a stale buffer - takes our entry with it, silently. The user then
// types `/tally-account` or `/tally-model` and gets a model turn instead of a free answer, with
// nothing anywhere saying why. Until now the only repair was relaunching the app, because the sync
// runs once at launch (`autoUpdateSkill`, AppDelegate).
//
// So the app watches those files and re-runs the sync it already has. Nothing here installs
// anything new: the whole of the repair is calling `syncPromptCommands`, which is idempotent and
// already knows how to leave a user's own entries alone (IntegrationsPromptCommand.swift).
//
// TWO THINGS IT MUST NOT DO, and both are guards rather than good intentions:
//
//   - IT MUST NOT LOOP. The repair WRITES settings.json, that write is a filesystem event, and the
//     event arrives back here. The gate is "everything is already in place, so do nothing", asked
//     before anything is written, which makes the second pass a no-op and ends the cycle.
//   - IT MUST NOT UNDO AN UNINSTALL. A user who turns the integration off in Settings has said
//     something, and an app that put it back within seconds would be overriding them with a
//     watchdog. Absence of the SKILL.md is what says so: it is what the uninstall removes, and it is
//     read off the disk rather than off the manifest, which records what was installed once and not
//     what is wanted now.

/// Whether a changed path is one of the directories holding a settings file we registered in.
///
/// EXACTLY those directories, never anything below them, and that is the whole filter. FSEvents is
/// asked at directory granularity, so an event names the folder; but the folder here is a provider
/// config home, one of the busiest on the machine - every running session writes through
/// `projects/`, and `.claude.json` is rewritten constantly. Accepting a subdirectory would turn
/// ordinary typing into a stream of wake-ups for a file nobody touched.
///
/// Pure and exported so the rule is testable without a filesystem.
func settingsEventIsInteresting(path: String, watching directories: [String]) -> Bool {
    func trimmed(_ s: String) -> String {
        s.hasSuffix("/") && s.count > 1 ? String(s.dropLast()) : s
    }
    let path = trimmed(path)
    return directories.contains { trimmed($0) == path }
}

extension IntegrationsStore {
    /// Whether the hooks need putting back, given what is installed and where.
    ///
    /// Static and fully injected so both answers it has to get right are testable without touching a
    /// real config home: "nothing is missing, so do nothing" (the loop guard) and "nothing is
    /// installed here, so do nothing" (the uninstall).
    ///
    /// The order matters only for cost - the uninstall check is a file read per home, the currency
    /// check is that plus a settings parse - but the SECOND is the one that ends the write-event-
    /// write cycle, so it can never be skipped for a machine where the first passes.
    /// - Parameter binary: the helper the entries are expected to name, defaulting to this app's.
    ///   Injected so a test can state a path without owning an app bundle.
    static func hooksNeedHealing(skillFiles: [URL], population: [URL],
                                 binary: URL? = nil) -> Bool {
        let helper = binary ?? bundledCLIURL
        let ours = oursAmong(skillFiles)
        guard !ours.isEmpty else { return false }
        guard promptCommandsAreCurrent(forSkillFiles: ours, population: population) else { return true }
        // AND THE ENTRY HAS TO RUN THIS APP. Presence was the only question this asked, and an
        // entry that is present can still name a binary that is not there: a locally built Release
        // registered every hook at a path inside its build tree, which holds no bundled CLI, and
        // from then on every `/tally-account` answered "No such file or directory" and fell through
        // to a model turn. The watcher was watching, found nothing missing, and healed nothing.
        //
        // A path that is merely OLD is the same repair, and it always was: the launch sync rewrites
        // it silently whenever the app moves (`syncPromptCommands`). This only makes the watcher
        // able to see the same thing between launches.
        //
        // ASKED PER HOME WHILE THE REPAIR WRITES PER GROUP, and the two are the same question, by
        // construction rather than by luck: `settingsGroups` keys a group on the home's settings.json
        // RESOLVED path, `syncPromptCommand` writes `homes.first`'s, and `editSettings` resolves
        // before writing - so the write lands exactly at the group key, which is the physical file
        // every home in that group reads through. Homes whose settings resolve elsewhere form another
        // group with a write of its own, so no home is left unwritten. Break any of those three and
        // the second home of a shared pair asks about a file nothing writes and answers "needs
        // healing" forever, which is a write-event-write cycle with the write left out.
        //
        // EVERY registration in the file, not the first: a duplicate entry left by something else
        // rewriting settings.json still fires, so a stale copy beside a good one is damage
        // (`registeredPromptHookCommands`).
        return homesCarrying(ours, population: population).contains { home in
            let settings = home.appendingPathComponent("settings.json")
            return promptCommands.contains { command in
                let registered = registeredPromptHookCommands(settings, hook: command)
                let expected = promptHookCommand(helper, command: command)
                return registered.isEmpty || registered.contains { $0 != expected }
            }
        }
    }

    /// The physical settings files a registration was recorded in. The manifest is the right source
    /// here, unlike for the uninstall question above: it is asking WHERE to watch, and a file we
    /// once registered in is a file worth watching whether or not the entry is in it right now -
    /// which is precisely the case this feature exists for.
    static func watchedSettingsDirectories(manifest url: URL = manifestURL) -> [URL] {
        var seen = Set<String>()
        return promptCommands
            .flatMap { manifestPaths($0.hookManifest, manifest: url) }
            // BOTH PARENTS, because the file can be written in two different places and only one
            // of them is where it lives. The manifest records the path a registration was made
            // THROUGH, which on a shared setup is a symlink (`~/.claude2/settings.json` pointing at
            // `~/.claude/settings.json`), and FSEvents reports a write where the bytes land:
            //
            //   - Something rewriting the CONTENT writes through the link, so the event names the
            //     RESOLVED parent (`.claude`). Watching only the logical one was deaf to it, which
            //     is what the first fix corrected (review of 212e25d).
            //   - Something replacing the FILE writes a temporary and renames it over the path it
            //     was given - which replaces the SYMLINK, not its target - so the event names the
            //     LOGICAL parent (`.claude2`) and the resolved one never hears it. That is the
            //     ordinary atomic-save an editor or a dotfiles tool performs (review of 3af8d67).
            //
            // Neither is a special case of the other, so both are watched. Each is resolved in
            // itself, because the DIRECTORY may be a link even when the file is not, and they
            // collapse to one entry on the ordinary machine where nothing is linked at all.
            .flatMap { path -> [URL] in
                let file = URL(fileURLWithPath: path)
                return [file.deletingLastPathComponent().resolvingSymlinksInPath(),
                        file.resolvingSymlinksInPath().deletingLastPathComponent()]
            }
            .filter { seen.insert($0.path).inserted }
    }

    /// Put back whatever is missing, or do nothing. Returns whether anything on disk changed.
    @discardableResult
    func healPromptHooks() -> Bool {
        // Shared state belongs to the INSTALLED release app, the same rule `autoUpdateSkill`
        // follows: a build nobody installed - the dev variant, or any bundle running out of a build
        // products tree - must never write into the config homes.
        guard !BuildVariant.isUnshipped else { return false }
        let files = Self.installedSkillFiles()
        guard Self.hooksNeedHealing(skillFiles: files, population: Self.claudeHomes()) else {
            return false
        }
        return syncPromptCommands(forSkillFiles: Self.oursAmong(files))
    }

    /// Whether the watcher has to be rebuilt, given what it is watching and what it should be.
    ///
    /// Pure, because the failure it prevents is invisible: on a machine with nothing installed yet
    /// the manifest names no directories, so the watcher is never created - and an Install pressed
    /// in Settings then left the user with no self-heal at all until the next launch. First-time
    /// users are the ones most likely to need it and the least likely to know it is missing (review
    /// of 212e25d). A new account's config dir arriving mid-session is the same event.
    ///
    /// Compared as SETS: the manifest's order is not a promise, and rebuilding a live FSEvents
    /// stream because two paths swapped places would be churn for nothing. Nothing to watch is a
    /// real answer - it means stop, not "leave the old one running".
    static func settingsWatcherNeedsRestart(current: [URL], desired: [URL]) -> Bool {
        Set(current.map(\.path)) != Set(desired.map(\.path))
    }

    /// Watch the settings files the hooks live in, and repair one that loses them.
    ///
    /// The watcher's own gate is the heal's decision (`hooksNeedHealing`), so an event that changed
    /// nothing we care about costs a file read and stops there; `onChange` fires only once a repair
    /// has actually been made, and refreshes so the Settings row stops claiming an install that is
    /// no longer true.
    ///
    /// Fail-open at every step, like the account watcher it shares its machinery with: no manifest
    /// entries means nothing to watch and the launch-time sync behaves exactly as it did before.
    /// Called at launch AND whenever the prompt-hook manifest changes, so an install performed in a
    /// running app is watched from that moment rather than from the next launch. A no-op when the
    /// set is unchanged, which is what keeps the repair's own manifest write from rebuilding the
    /// stream that noticed the damage.
    func refreshSettingsWatcher() {
        // The same gate as the repair it exists to run (`healPromptHooks`), and it has to be the
        // same one: a watcher whose only action can never fire is an FSEvents stream over the busiest
        // directories on the machine, woken by every session write, to decide nothing. Two gates
        // spelt differently here also read as a claim that a build tree may watch but not write,
        // which is not a distinction anything wants.
        guard !BuildVariant.isUnshipped else { return }
        let directories = Self.watchedSettingsDirectories()
        guard Self.settingsWatcherNeedsRestart(current: settingsWatcherRoots,
                                               desired: directories) else { return }
        // Stop before starting: two streams over the same directories would answer every event
        // twice, and the old one's roots are by definition the wrong ones now.
        settingsWatcher?.stop()
        settingsWatcher = nil
        settingsWatcherRoots = directories
        guard !directories.isEmpty else { return }
        let paths = directories.map(\.path)
        let watcher = AccountDirWatcher(
            roots: directories,
            // Shorter than the account watcher's three seconds: a wholesale rewrite of settings.json
            // is one write, not the burst a login produces, and the wait here is time the user's
            // slash commands spend costing a turn.
            debounce: .seconds(2),
            isInteresting: { settingsEventIsInteresting(path: $0, watching: paths) },
            discoverChanged: { [weak self] in self?.healPromptHooks() ?? false },
            onChange: { [weak self] in self?.refresh() })
        watcher.start()
        settingsWatcher = watcher
    }
}
