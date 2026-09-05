import Foundation

// The station that opens the app again when a silent update took it away and never brought it back
// (TallyCLI/AppRelaunch.swift). Top-level statements can only live in main.swift, so these run as
// one function it calls; the harness (`check`, `failures`) and the fixed `launch` date come from
// there.
//
// The behaviour under test is the 2026-09-05 19:23 incident: Sparkle installed v0.71.0 in the
// background, the app quit for the swap, and Sparkle's installer had already recorded the target as
// dead, so it finished the install and launched nothing. The menu bar icon was simply gone. Two
// other automatic updates the same day relaunched normally, which is why every check below that
// says "do nothing" matters as much as the one that opens the app: the station has to be silent
// through every ordinary update.

func runAppRelaunchChecks() {
    // MARK: - 26. An update took the app away and nothing brought it back

    let old = "0.70.0"
    let new = "0.71.0"

    /// One tick, fed straight to the decision. `alive` is what a walk of the process table said
    /// about the app from this supervisor's own bundle, `offset` is seconds since a fixed origin.
    func tick(_ state: inout AppRelaunchState, _ version: String?, alive: Bool,
              at offset: TimeInterval, claim: (String) -> Bool = { _ in true }) -> String? {
        appRelaunchDue(&state, observation: AppPresence(installedVersion: version, appAlive: alive,
                                                        at: launch.addingTimeInterval(offset)),
                       claim: claim)
    }

    // 26a. The incident itself: running under the old build, the bundle is swapped, the app never
    // comes back, and once the grace has passed this supervisor opens it.
    var incident = AppRelaunchState()
    check("an app running under the current build asks for nothing",
          tick(&incident, old, alive: true, at: 0) == nil)
    check("the swap alone opens nothing: Sparkle is still allowed to do it",
          tick(&incident, new, alive: false, at: 10) == nil)
    check("nor a second later, still inside the grace",
          tick(&incident, new, alive: false, at: 11) == nil)
    check("the app still missing a grace after the swap is opened",
          tick(&incident, new, alive: false, at: 25) == new)

    // 26b. Every ordinary update, where Sparkle relaunches the app itself. This is the case the
    // station must never act on, and it is the common one: two of the three automatic updates that
    // day behaved exactly like this.
    var normal = AppRelaunchState()
    _ = tick(&normal, old, alive: true, at: 0)
    _ = tick(&normal, new, alive: false, at: 10)
    check("the app coming back two seconds later ends it",
          tick(&normal, new, alive: true, at: 12) == nil)
    check("and no later tick reopens it", tick(&normal, new, alive: true, at: 40) == nil)
    check("not even one an hour on", tick(&normal, new, alive: true, at: 3600) == nil)
    check("and quitting the app after that update is the user's business, not ours",
          tick(&normal, new, alive: false, at: 4000) == nil)
    check("however long they leave it closed",
          tick(&normal, new, alive: false, at: 8000) == nil)

    // 26c. The app was already gone before the swap: the user quit it, and an update landing later
    // is not a relaunch anybody is owed.
    var quitFirst = AppRelaunchState()
    _ = tick(&quitFirst, old, alive: true, at: 0)
    _ = tick(&quitFirst, old, alive: false, at: 5)
    check("an update that lands on an app the user had already quit opens nothing",
          tick(&quitFirst, new, alive: false, at: 10) == nil)
    check("and it stays that way past the grace",
          tick(&quitFirst, new, alive: false, at: 40) == nil)

    // 26d. Nothing to compare, or nothing that moved forward. Same reading of a version as the
    // self-update takes (`isNewerBuild`), for the same reason: a build we cannot reason about is a
    // build we do not act on.
    var sameVersion = AppRelaunchState()
    _ = tick(&sameVersion, new, alive: true, at: 0)
    check("an app that simply exits under an unchanged build is left alone",
          tick(&sameVersion, new, alive: false, at: 10) == nil)
    check("however long it stays away", tick(&sameVersion, new, alive: false, at: 60) == nil)

    var downgrade = AppRelaunchState()
    _ = tick(&downgrade, new, alive: true, at: 0)
    _ = tick(&downgrade, old, alive: false, at: 10)
    check("an older build installed over the top opens nothing",
          tick(&downgrade, old, alive: false, at: 40) == nil)

    var unparseable = AppRelaunchState()
    _ = tick(&unparseable, new, alive: true, at: 0)
    _ = tick(&unparseable, "0.72.0-beta", alive: false, at: 10)
    check("a version we cannot parse is not a newer build here either",
          tick(&unparseable, "0.72.0-beta", alive: false, at: 40) == nil)

    var devBuild = AppRelaunchState()
    _ = tick(&devBuild, nil, alive: true, at: 0)
    check("a dev or standalone build reports no version and never arms",
          tick(&devBuild, nil, alive: false, at: 40) == nil)

    var midInstall = AppRelaunchState()
    _ = tick(&midInstall, old, alive: true, at: 0)
    check("a tick that reads no version mid-install says nothing",
          tick(&midInstall, nil, alive: false, at: 5) == nil)
    _ = tick(&midInstall, new, alive: false, at: 10)
    check("and the swap either side of it is still recognised",
          tick(&midInstall, new, alive: false, at: 30) == new)

    // 26e. The grace is a floor, not a rounding. Fourteen seconds is a Sparkle relaunch that is
    // merely slow.
    var justInside = AppRelaunchState()
    _ = tick(&justInside, old, alive: true, at: 0)
    _ = tick(&justInside, new, alive: false, at: 10)
    check("fourteen seconds after the swap is still Sparkle's to answer",
          tick(&justInside, new, alive: false, at: 24) == nil)
    check("fifteen is ours", tick(&justInside, new, alive: false, at: 25) == new)

    // 26f. One open per version, per process. The app may fail to start for reasons nothing here
    // can fix, and a station that asked again every fifteen seconds would say so all night.
    var once = AppRelaunchState()
    _ = tick(&once, old, alive: true, at: 0)
    _ = tick(&once, new, alive: false, at: 10)
    check("the version is opened for once", tick(&once, new, alive: false, at: 30) == new)
    check("and never again for the same version",
          tick(&once, new, alive: false, at: 60) == nil)
    check("nor an hour later", tick(&once, new, alive: false, at: 3600) == nil)
    // A later release is a new question, and gets a new answer.
    _ = tick(&once, new, alive: true, at: 4000)
    _ = tick(&once, "0.72.0", alive: false, at: 4010)
    check("but the next release the app does not come back from is opened for again",
          tick(&once, "0.72.0", alive: false, at: 4030) == "0.72.0")

    // 26g. Nine supervisors watched the same bundle the day of the incident, all reaching the same
    // conclusion within seconds of each other. Losing the claim means another one is opening it.
    var lostClaim = AppRelaunchState()
    _ = tick(&lostClaim, old, alive: true, at: 0)
    _ = tick(&lostClaim, new, alive: false, at: 10)
    check("a supervisor that loses the machine-wide claim opens nothing",
          tick(&lostClaim, new, alive: false, at: 30, claim: { _ in false }) == nil)
    check("and it stops asking, so the claim is taken at most once per supervisor",
          tick(&lostClaim, new, alive: false, at: 60, claim: { _ in true }) == nil)

    // 26h. THE READING AT THE SWAP IS NOT PROOF THE APP IS STILL THERE, and the incident's own
    // timing is why. The installer finished at .751 and the app died at .775: for those 24
    // milliseconds the bundle already carried the new version while the app was still running, and
    // the aliveness reading can be another five seconds older than that (`AppPresenceScan`). So the
    // tick that notices the swap very often reads "alive", and a station that disarmed on that
    // reading would do nothing at all in exactly the case it exists for.
    var staleReading = AppRelaunchState()
    _ = tick(&staleReading, old, alive: true, at: 0)
    check("the swap seen while the reading still says alive opens nothing yet",
          tick(&staleReading, new, alive: true, at: 10) == nil)
    check("nor does the tick that first finds the app gone",
          tick(&staleReading, new, alive: false, at: 13) == nil)
    check("nor one fourteen seconds into that absence",
          tick(&staleReading, new, alive: false, at: 27) == nil)
    check("but the app still gone a grace later is opened, stale reading and all",
          tick(&staleReading, new, alive: false, at: 28) == new)

    // The other side of that patience: an update that did NOT take the app away. Somebody drops a
    // new build over the top while the app keeps running the old code, and quits it hours later.
    // Nothing here is owed a relaunch, so the arming expires rather than waiting forever.
    var manualOverwrite = AppRelaunchState()
    _ = tick(&manualOverwrite, old, alive: true, at: 0)
    _ = tick(&manualOverwrite, new, alive: true, at: 10)
    _ = tick(&manualOverwrite, new, alive: true, at: 40)
    check("an app still running a minute after the swap was never taken away by it",
          tick(&manualOverwrite, new, alive: true, at: 100) == nil)
    check("so quitting it later opens nothing",
          tick(&manualOverwrite, new, alive: false, at: 5000) == nil)
    check("however long it then stays closed",
          tick(&manualOverwrite, new, alive: false, at: 5020) == nil)

    // And the ordinary update again, this time seen through the same stale reading: the app goes,
    // Sparkle brings it back, and the station stays silent for the rest of the session.
    var staleNormal = AppRelaunchState()
    _ = tick(&staleNormal, old, alive: true, at: 0)
    _ = tick(&staleNormal, new, alive: true, at: 10)
    _ = tick(&staleNormal, new, alive: false, at: 12)
    check("an app Sparkle brings back two seconds later ends it here too",
          tick(&staleNormal, new, alive: true, at: 14) == nil)
    check("and nothing reopens it afterwards", tick(&staleNormal, new, alive: true, at: 40) == nil)
    check("nor an hour on", tick(&staleNormal, new, alive: true, at: 3600) == nil)
    check("and the user quitting it then is their business",
          tick(&staleNormal, new, alive: false, at: 4000) == nil)

    // The window is a floor like the grace is, and asserted from both sides.
    var justArmed = AppRelaunchState()
    _ = tick(&justArmed, old, alive: true, at: 0)
    _ = tick(&justArmed, new, alive: true, at: 10)
    _ = tick(&justArmed, new, alive: true, at: 69)
    _ = tick(&justArmed, new, alive: false, at: 70)
    check("an app that goes a second inside the arming window is still ours to reopen",
          tick(&justArmed, new, alive: false, at: 85) == new)

    var justExpired = AppRelaunchState()
    _ = tick(&justExpired, old, alive: true, at: 0)
    _ = tick(&justExpired, new, alive: true, at: 10)
    _ = tick(&justExpired, new, alive: true, at: 70)
    _ = tick(&justExpired, new, alive: false, at: 71)
    check("one that goes a second outside it is not",
          tick(&justExpired, new, alive: false, at: 90) == nil)

    // MARK: - 27. The claim itself, and the process reading behind it

    let claimDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-app-relaunch-\(UUID().uuidString)")
    check("the first supervisor to ask wins the version's claim",
          claimAppRelaunch(new, dir: claimDir))
    check("every other one loses it", !claimAppRelaunch(new, dir: claimDir))
    check("a newer version is a new claim, and it is won",
          claimAppRelaunch("0.72.0", dir: claimDir))
    let held = (try? FileManager.default.contentsOfDirectory(atPath: claimDir.path)) ?? []
    check("claiming a newer version clears the ones already dealt with", held == ["0.72.0"])
    check("a version that is not a plain name is refused rather than written",
          !claimAppRelaunch("../../escape", dir: claimDir))
    check("and so is an empty one", !claimAppRelaunch("", dir: claimDir))
    try? FileManager.default.removeItem(at: claimDir)

    // The process table is walked at most every few seconds: the poll tick is far faster than that
    // and a machine can carry nine supervisors, so the reading is cached in between.
    var scan = AppPresenceScan()
    var probes = 0
    func probed(_ offset: TimeInterval) -> Bool {
        scan.alive(now: launch.addingTimeInterval(offset)) {
            probes += 1
            return true
        }
    }
    _ = probed(0)
    _ = probed(1)
    _ = probed(4)
    check("the process table is walked once inside the scan interval", probes == 1)
    _ = probed(6)
    check("and again once it has passed", probes == 2)

    // MARK: - 28. Which bundle, and which app inside it

    // The CLI is embedded at <App>.app/Contents/Helpers/tally, so the bundle to open is three
    // directories up and the app to look for is named by that bundle's own Info.plist. The Debug
    // build is called "Tally Dev", which is exactly why the name is read rather than assumed.
    let fixture = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-bundle-\(UUID().uuidString)")
    let appBundle = fixture.appendingPathComponent("Tally Dev.app")
    let contents = appBundle.appendingPathComponent("Contents")
    try? FileManager.default.createDirectory(at: contents.appendingPathComponent("Helpers"),
                                             withIntermediateDirectories: true)
    let plist = try? PropertyListSerialization.data(
        fromPropertyList: ["CFBundleExecutable": "Tally Dev",
                           "CFBundleShortVersionString": new] as [String: Any],
        format: .xml, options: 0)
    try? plist?.write(to: contents.appendingPathComponent("Info.plist"))
    let cli = contents.appendingPathComponent("Helpers").appendingPathComponent("tally")
    FileManager.default.createFile(atPath: cli.path, contents: Data())
    let paths = bundledAppPaths(cli)
    check("the bundle to open is the one this binary is embedded in",
          paths?.bundle == appBundle.path)
    check("and the app to watch for is the executable that bundle declares",
          paths?.executable == contents.appendingPathComponent("MacOS")
              .appendingPathComponent("Tally Dev").path)
    check("a binary that is not inside a bundle has nothing to watch or open",
          bundledAppPaths(fixture.appendingPathComponent("tally")) == nil)

    // MARK: - 29. One tick, end to end

    // Everything above tested in one piece: the reading, the decision, and the act.
    var wired = AppRelaunchState()
    var opened: [String] = []
    var said: [String] = []
    // The announcement is collected rather than printed: `warn` writes to the terminal these
    // assertions are printed on, and a line landing mid-print splits one of them.
    func run(_ version: String?, alive: Bool, at offset: TimeInterval,
             claim: @escaping (String) -> Bool = { _ in true }) {
        applyAppRelaunch(&wired, now: launch.addingTimeInterval(offset), installed: version,
                         bundle: paths, probe: { _ in alive }, claim: claim,
                         announce: { said.append($0) }, launch: { opened.append($0) })
    }
    run(old, alive: true, at: 0)
    run(new, alive: false, at: 10)
    check("a tick inside the grace opens nothing", opened.isEmpty)
    check("and says nothing either", said.isEmpty)
    run(new, alive: false, at: 30)
    check("the tick past it opens the bundle this supervisor lives in", opened == [appBundle.path])
    check("it says what it is about to do, naming the version that landed",
          said == ["tally updated to \(new) but the app did not come back, opening it"])
    run(new, alive: false, at: 60)
    check("and no tick after it opens anything again", opened == [appBundle.path])
    check("nor says anything again", said.count == 1)

    // The same wiring with no bundle to speak of: a dev build must not reach the process table or
    // the claim, let alone open something.
    var standalone = AppRelaunchState()
    var standaloneOpened = 0
    var standaloneProbes = 0
    for offset in [0.0, 10.0, 30.0] {
        applyAppRelaunch(&standalone, now: launch.addingTimeInterval(offset), installed: new,
                         bundle: nil, probe: { _ in standaloneProbes += 1; return false },
                         claim: { _ in true }, launch: { _ in standaloneOpened += 1 })
    }
    check("a binary outside a bundle never walks the process table", standaloneProbes == 0)
    check("and never opens anything", standaloneOpened == 0)
    try? FileManager.default.removeItem(at: fixture)

    // MARK: - 30. The station is actually wired into the poll loop

    // The decision above is worth nothing if no tick asks it, and the supervisor loop is the one
    // caller. Asserted as source rather than run, the way the self-update's own ordering is.
    let loop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("the supervisor source is readable from this suite", !loop.isEmpty)
    check("the poll loop runs this station every tick", loop.contains("applyAppRelaunch(&appRelaunch)"))
    check("and it carries the state across ticks rather than starting fresh",
          loop.contains("var appRelaunch = AppRelaunchState()"))
    let station = (try? String(contentsOfFile: "TallyCLI/AppRelaunch.swift", encoding: .utf8)) ?? ""
    check("the station source is readable from this suite", !station.isEmpty)
    check("the line it says by default is the one this suite asserted",
          station.contains("but the app did not come back, opening it"))
    check("and the default announcement is the supervisor's own terminal line",
          station.contains("announce: (String) -> Void = { warn($0) }"))
    check("it opens the app in the background, never in front of the user",
          station.contains("[\"-g\", path]"))
    check("the process table is read in-process, never by spawning pgrep per tick",
          !station.contains("/usr/bin/pgrep"))
}
