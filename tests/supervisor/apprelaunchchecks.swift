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

/// An app bundle on disk in the layout this station reads: the CLI at `Contents/Helpers/tally`
/// (the one input `bundledAppPaths` takes), the app's own executable at `Contents/MacOS/<name>` and
/// runnable - what a finished swap leaves behind, and what a tick refuses to open a bundle without -
/// and an Info.plist naming that executable. The name is declared rather than assumed because the
/// Debug build is called "Tally Dev", which is the whole reason `bundledAppPaths` reads the plist.
///
/// Answers with the root to remove afterwards, the bundle whose path the checks compare against,
/// and the CLI inside it. Two fixtures in this file want exactly this, and a runnable executable is
/// now load-bearing in both, so it is built once rather than kept alike by hand.
func makeAppBundle(named name: String,
                   version: String? = nil) -> (root: URL, bundle: URL, cli: URL) {
    let manager = FileManager.default
    let root = manager.temporaryDirectory
        .appendingPathComponent("tally-bundle-\(UUID().uuidString)")
    let bundle = root.appendingPathComponent("\(name).app")
    let contents = bundle.appendingPathComponent("Contents")
    for directory in ["Helpers", "MacOS"] {
        try? manager.createDirectory(at: contents.appendingPathComponent(directory),
                                     withIntermediateDirectories: true)
    }
    var plist: [String: Any] = ["CFBundleExecutable": name]
    if let version { plist["CFBundleShortVersionString"] = version }
    try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    manager.createFile(atPath: contents.appendingPathComponent("MacOS")
        .appendingPathComponent(name).path, contents: Data(),
        attributes: [.posixPermissions: 0o755])
    let cli = contents.appendingPathComponent("Helpers").appendingPathComponent("tally")
    manager.createFile(atPath: cli.path, contents: Data())
    return (root, bundle, cli)
}

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
    //
    // THE SPACING IS PART OF THE ASSERTION since 2026-09-22, and it used to be five seconds. What
    // separates this from the incident is how long the app had been known gone when the swap was
    // noticed, and the readings that answer that are on a grid up to seven seconds coarse
    // (`appRelaunchAbsenceMemory`): a quit five seconds before a swap is inside it, and no station
    // driven by real ticks can tell it from an app the installer had just taken. So the gap here is
    // one a person would recognise as "the user quit it, and an update landed later" rather than
    // one the old boolean happened to answer correctly by phase. The sweep in section 32 asserts
    // the same case across every start phase.
    var quitFirst = AppRelaunchState()
    _ = tick(&quitFirst, old, alive: true, at: 0)
    _ = tick(&quitFirst, old, alive: false, at: 5)
    check("an update that lands on an app the user had already quit opens nothing",
          tick(&quitFirst, new, alive: false, at: 40) == nil)
    check("and it stays that way past the grace",
          tick(&quitFirst, new, alive: false, at: 70) == nil)
    check("nor does the arming the swap did not make hold an upgrade back", !quitFirst.isArmed)

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
    check("an app that goes a second inside the arming window is reopened, Sparkle or not: "
          + "the window cannot tell a manual quit apart",
          tick(&justArmed, new, alive: false, at: 85) == new)

    var justExpired = AppRelaunchState()
    _ = tick(&justExpired, old, alive: true, at: 0)
    _ = tick(&justExpired, new, alive: true, at: 10)
    _ = tick(&justExpired, new, alive: true, at: 70)
    _ = tick(&justExpired, new, alive: false, at: 71)
    check("one that goes a second outside it is not",
          tick(&justExpired, new, alive: false, at: 90) == nil)

    // 26i. WHAT THE POLL LOOP READS OFF THIS STATE. The same app update that swaps the bundle makes
    // every supervisor due for a self-update, and that `execv` takes this station's memory with it -
    // on an idle machine, which is when automatic updates land, every session would replace itself
    // on the very tick that armed. So the loop treats an armed station as a relaunch already
    // planned and lets the upgrade wait; these are the readings it takes.
    var armState = AppRelaunchState()
    check("a station that has seen nothing yet is not armed", !armState.isArmed)
    _ = tick(&armState, old, alive: true, at: 0)
    check("nor one merely watching an app that is running", !armState.isArmed)
    _ = tick(&armState, new, alive: true, at: 10)
    check("the swap arms it, even while the reading still says alive", armState.isArmed)
    _ = tick(&armState, new, alive: false, at: 13)
    check("and it stays armed while the app is away inside the grace", armState.isArmed)
    // Read left to right: the arming is asserted BEFORE the tick that settles it, so the name and
    // the assertion say the same thing.
    check("the station is still armed on the tick that opens the app",
          armState.isArmed && tick(&armState, new, alive: false, at: 28) == new)
    check("and settling it disarms, so the upgrade is free to take the next tick",
          !armState.isArmed)

    // The two ways an arming ends without opening anything disarm just the same.
    var armReturned = AppRelaunchState()
    _ = tick(&armReturned, old, alive: true, at: 0)
    _ = tick(&armReturned, new, alive: false, at: 10)
    _ = tick(&armReturned, new, alive: true, at: 12)
    check("an app Sparkle brought back leaves nothing armed", !armReturned.isArmed)
    var armExpired = AppRelaunchState()
    _ = tick(&armExpired, old, alive: true, at: 0)
    _ = tick(&armExpired, new, alive: true, at: 10)
    _ = tick(&armExpired, new, alive: true, at: 70)
    check("nor does an app that never left inside the arming window", !armExpired.isArmed)
    // A supervisor that never had a version to compare cannot hold an upgrade back either.
    var armDev = AppRelaunchState()
    _ = tick(&armDev, nil, alive: true, at: 0)
    _ = tick(&armDev, nil, alive: false, at: 10)
    check("a dev build with no version is never armed", !armDev.isArmed)

    // MARK: - 27. The claim itself, and the process reading behind it

    let claimDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-app-relaunch-\(UUID().uuidString)")
    let installed = "/Applications/Tally.app"
    let elsewhere = "/Users/someone/Downloads/Tally.app"
    check("the first supervisor to ask wins the version's claim",
          claimAppRelaunch(new, bundle: installed, dir: claimDir))
    check("every other one loses it", !claimAppRelaunch(new, bundle: installed, dir: claimDir))
    // Two copies of Tally in two places are two apps to this station, and they can carry the same
    // version. One claim shared between them would leave the second copy's supervisor silent about
    // an app that really did not come back.
    check("a second copy of the app elsewhere claims the same version for itself",
          claimAppRelaunch(new, bundle: elsewhere, dir: claimDir))
    check("and loses its own second attempt, like every other claim",
          !claimAppRelaunch(new, bundle: elsewhere, dir: claimDir))
    check("the two bundles keep their claims apart",
          appRelaunchBundleKey(installed) != appRelaunchBundleKey(elsewhere))
    check("and a bundle's key is the same string every time it is asked for",
          appRelaunchBundleKey(installed) == appRelaunchBundleKey(installed))
    check("a newer version is a new claim, and it is won",
          claimAppRelaunch("0.72.0", bundle: installed, dir: claimDir))
    let home = claimDir.appendingPathComponent(appRelaunchBundleKey(installed))
    let held = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
    check("claiming a newer version clears the ones already dealt with", held == ["0.72.0"])
    let neighbour = claimDir.appendingPathComponent(appRelaunchBundleKey(elsewhere))
    let untouched = (try? FileManager.default.contentsOfDirectory(atPath: neighbour.path)) ?? []
    check("and clears only its own, never the other bundle's", untouched == [new])
    check("a version that is not a plain name is refused rather than written",
          !claimAppRelaunch("../../escape", bundle: installed, dir: claimDir))
    check("and so is an empty one", !claimAppRelaunch("", bundle: installed, dir: claimDir))
    check("a claim with no bundle to name is refused too",
          !claimAppRelaunch(new, bundle: "", dir: claimDir))
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
    let (fixture, appBundle, cli) = makeAppBundle(named: "Tally Dev", version: new)
    let paths = bundledAppPaths(cli)
    check("the bundle to open is the one this binary is embedded in",
          paths?.bundle == appBundle.path)
    check("and the app to watch for is the executable that bundle declares",
          paths?.executable == appBundle.appendingPathComponent("Contents")
              .appendingPathComponent("MacOS").appendingPathComponent("Tally Dev").path)
    check("a binary that is not inside a bundle has nothing to watch or open",
          bundledAppPaths(fixture.appendingPathComponent("tally")) == nil)

    // MARK: - 29. One tick, end to end

    // Everything above tested in one piece: the reading, the decision, and the act.
    var wired = AppRelaunchState()
    var opened: [String] = []
    // The announcement is collected rather than printed: `warn` writes to the terminal these
    // assertions are printed on, and a line landing mid-print splits one of them.
    var said: [String] = []
    var claimed: [String] = []
    // The durable line each decision leaves is collected the same way, and for a second reason:
    // its default writes under the home directory, which no suite may touch.
    var logged: [AppRelaunchEvent] = []
    func run(_ version: String?, alive: Bool, at offset: TimeInterval) {
        applyAppRelaunch(&wired, now: launch.addingTimeInterval(offset), installed: version,
                         bundle: paths, probe: { _ in alive },
                         claim: { _, bundle in claimed.append(bundle); return true },
                         announce: { said.append($0) }, record: { event, _ in logged.append(event) },
                         launch: { opened.append($0) })
    }
    run(old, alive: true, at: 0)
    run(new, alive: false, at: 10)
    check("a tick inside the grace opens nothing", opened.isEmpty)
    check("and says nothing either", said.isEmpty)
    run(new, alive: false, at: 30)
    check("the tick past it opens the bundle this supervisor lives in", opened == [appBundle.path])
    check("it says what it is about to do, naming the version that landed",
          said == ["tally updated to \(new) but the app did not come back, opening it"])
    check("and the claim it took names the bundle it is opening, not just the version",
          claimed == [appBundle.path])
    run(new, alive: false, at: 60)
    check("and no tick after it opens anything again", opened == [appBundle.path])
    check("nor says anything again", said.count == 1)
    // EVERY DECISION LEFT A LINE, which is the half of this station a person reads after the next
    // report. The first tick says somebody is watching at all, the swap says the relaunch is owed,
    // and the open says it was paid: the three states a silent station is impossible to tell apart
    // in (2026-09-22 cost hours of `log show` reading for want of them).
    check("the tick that starts watching says so, once",
          logged.filter { $0 == .watching(old) }.count == 1)
    check("the swap that owes a relaunch is recorded as an arming", logged.contains(.armed(new)))
    check("and so is the open it led to", logged.contains(.opened(new)))
    check("nothing else is written for the ticks in between", logged.count == 3)

    // A SWAP STILL IN PROGRESS IS NOT A BUNDLE TO OPEN. The app's executable is gone for a moment
    // while the installer writes it, and this station must not hand the user a half-installed app -
    // the check `selfUpdateBinary` spends on the same fact about its own binary.
    // The timeline is the incident's own, and the station is walked INTO it: the first tick reads
    // the app alive under the old build, and only then does the executable go away. So every gate
    // BUT this one says "open it" while it is away, which is what makes these lines an assertion.
    // Driven tick by tick rather than from one loop, because a fixture whose `runnable` is false
    // from the very first tick returns early every time and asserts nothing at all about arming:
    // that is what stood here (probes=0, seenVersion=nil, armed=false) while the comment claimed
    // the opposite.
    var midSwap = AppRelaunchState()
    var midSwapOpened = 0
    var midSwapProbes = 0
    var midSwapLog: [AppRelaunchEvent] = []
    func midSwapTick(_ version: String, alive: Bool, runnable: Bool, at offset: TimeInterval) {
        applyAppRelaunch(&midSwap, now: launch.addingTimeInterval(offset), installed: version,
                         bundle: paths, probe: { _ in midSwapProbes += 1; return alive },
                         runnable: { _ in runnable }, claim: { _, _ in true },
                         record: { event, _ in midSwapLog.append(event) },
                         launch: { _ in midSwapOpened += 1 })
    }
    midSwapTick(old, alive: true, runnable: true, at: 0)
    check("the tick before the swap reads the old app as alive and starts watching",
          midSwapProbes == 1 && midSwapLog == [.watching(old)])
    midSwapTick(new, alive: false, runnable: false, at: 10)
    midSwapTick(new, alive: false, runnable: false, at: 30)
    check("a bundle whose app is not runnable yet is never opened", midSwapOpened == 0)
    check("and is not even asked about: no walk of the process table while it is away",
          midSwapProbes == 1)
    check("nor does a tick that decided nothing write a line", midSwapLog == [.watching(old)])
    check("and the station holding through it stays unarmed", !midSwap.isArmed)
    midSwapTick(new, alive: false, runnable: true, at: 40)
    check("the swap is recognised once the executable is back, against the version this station "
          + "remembered from before it",
          midSwap.isArmed && midSwapLog == [.watching(old), .armed(new)])
    check("and the arming alone still opens nothing", midSwapOpened == 0)
    midSwapTick(new, alive: false, runnable: true, at: 60)
    check("the relaunch an interrupted install owed is paid once the grace has passed",
          midSwapOpened == 1 && midSwapLog == [.watching(old), .armed(new), .opened(new)])

    // The line itself, which is the thing being read back. The bundle path is last because it is
    // the one field that can contain a space.
    let armedLine = appRelaunchLogLine(.armed(new), bundle: "/Applications/Tally.app", pid: "421",
                                       now: launch)
    check("an arming writes one line naming the version and the bundle",
          armedLine.hasSuffix(" pid=421 app-relaunch=armed reason=- version=\(new) "
                              + "bundle=/Applications/Tally.app\n"))
    check("and a disarming carries the reason in the same column",
          appRelaunchLogLine(.disarmed(new, reason: "app-returned"), bundle: "/A.app", pid: "421",
                             now: launch)
              .hasSuffix("app-relaunch=disarmed reason=app-returned version=\(new) "
                         + "bundle=/A.app\n"))
    check("the line is stamped with the moment it describes",
          armedLine.hasPrefix(ISO8601DateFormatter().string(from: launch)))

    // The same wiring with no bundle to speak of: a dev build must not reach the process table or
    // the claim, let alone open something.
    var standalone = AppRelaunchState()
    var standaloneOpened = 0
    var standaloneProbes = 0
    for offset in [0.0, 10.0, 30.0] {
        applyAppRelaunch(&standalone, now: launch.addingTimeInterval(offset), installed: new,
                         bundle: nil, probe: { _ in standaloneProbes += 1; return false },
                         claim: { _, _ in true }, launch: { _ in standaloneOpened += 1 })
    }
    check("a binary outside a bundle never walks the process table", standaloneProbes == 0)
    check("and never opens anything", standaloneOpened == 0)
    try? FileManager.default.removeItem(at: fixture)

    // MARK: - 30. The station is actually wired into the poll loop

    // The decision above is worth nothing if no tick asks it, and the supervisor loop is the one
    // caller. Asserted as source rather than run, the way the self-update's own ordering is.
    let loop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("the supervisor source is readable from this suite", !loop.isEmpty)
    check("the poll loop runs this station every tick",
          loop.contains("applyAppRelaunch(&appRelaunch, installed: installedVersion)"))
    // AND ON THE TICK'S OWN READING OF THE INSTALLED BUILD, taken once at the top rather than by
    // each station's defaulted `supervisorBuildVersion()`. This station and the two self-update
    // ones compare against that version, and `supervisorBuildVersion` resolves the bundle's plist
    // on every call: a Sparkle swap landing between two of those calls inside ONE tick had them
    // deciding about different worlds - this station seeing the app alive under the old version
    // while the self-update beside it already read the new one (P2, 2026-09-05).
    check("…from one reading of the installed build, shared by every station that compares to it",
          loop.contains("let installedVersion = supervisorBuildVersion()")
              && loop.contains("uptime: childAge, home: account.launchHome,\n"
                               + "                   installed: installedVersion)")
              && loop.contains("home: plan.target.launchHome, installed: installedVersion)"))
    // The source with its comment lines taken out, the technique `supervisorfreshnesschecks` uses
    // for the same file: every rule here is also EXPLAINED in prose beside the code, and a count
    // that could not tell the two apart would be counting sentences.
    let loopCode = loop.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
    check("…and no station takes a second reading of its own inside that tick",
          loopCode.components(separatedBy: "supervisorBuildVersion()").count - 1 == 2)

    // MARK: - 31. A bundle swapped BETWEEN two readings inside one tick

    // WHAT THE SHARED READING BUYS, driven rather than argued. A Sparkle install replaces the
    // bundle while these stations are deciding, and `supervisorBuildVersion()` resolves the plist
    // on every call - so two calls a few lines apart can straddle the swap. The fixture is a
    // version oracle that answers 0.71.1 once and 0.71.2 for ever after: exactly one swap, landing
    // between the arming station's reading and the self-update's.
    var readings = 0
    func swappingBundle() -> String? {
        readings += 1
        return readings == 1 ? "0.71.1" : "0.71.2"
    }
    /// The arming station's own decision, over an app that has just gone away. Three ticks, which
    /// is what this station takes: one to establish what was seen, one where the version CHANGES
    /// under a dead app (which arms), and one past the grace (which fires). Two ticks answer nil
    /// whatever the version is, so a fixture built from two would be green in both directions and
    /// state nothing.
    func armed(installed: String?) -> String? {
        var state = AppRelaunchState()
        _ = appRelaunchDue(&state, observation: AppPresence(installedVersion: "0.71.1",
                                                            appAlive: true, at: launch),
                           claim: { _ in true })
        _ = appRelaunchDue(&state, observation: AppPresence(installedVersion: installed,
                                                            appAlive: false,
                                                            at: launch.addingTimeInterval(10)),
                           claim: { _ in true })
        return appRelaunchDue(&state, observation: AppPresence(installedVersion: installed,
                                                               appAlive: false,
                                                               at: launch.addingTimeInterval(40)),
                              claim: { _ in true })
    }
    /// And the self-update's, over the same tick's other reading.
    func upgrade(installed: String?) -> String? {
        selfUpdateTarget(captured: "0.71.1", installed: installed, isQuiet: true,
                         relaunchPlanned: false, uptime: 3_600, attempted: nil)
    }
    // TWO READINGS: each station gets its own, and they describe different worlds. The arming
    // station is looking at the version it captured before the swap, so it sees no change and arms
    // nothing, while the self-update beside it already reads the new build and replaces the process
    // - taking the arming that would have re-opened the app with it (AppRelaunch.swift's header
    // states why that arming is what the app's absence depends on).
    readings = 0
    let splitArm = armed(installed: swappingBundle())
    let splitUpgrade = upgrade(installed: swappingBundle())
    check("two readings inside one tick can disagree about which build is installed",
          splitArm == nil && splitUpgrade == "0.71.2")
    // ONE READING: whichever side of the swap it falls on, both stations answer about the same
    // world. Both orders are asserted, because which one a tick gets is a race.
    readings = 0
    let beforeSwap = swappingBundle()
    check("one reading taken before the swap has both stations agreeing there is nothing new",
          armed(installed: beforeSwap) == nil && upgrade(installed: beforeSwap) == nil)
    readings = 1
    let afterSwap = swappingBundle()
    check("…and one taken after it has both of them acting on the same new build",
          armed(installed: afterSwap) == "0.71.2" && upgrade(installed: afterSwap) == "0.71.2")
    check("and it carries the state across ticks rather than starting fresh",
          loop.contains("var appRelaunch = AppRelaunchState()"))
    // Both places this process can replace itself read the arming, and `tally reload` is why the
    // second one matters: it is a request every supervisor answers in the same window, so a fold
    // left unguarded would exec every arming on the machine away at once.
    check("the loop's standalone self-update call reads it",
          loop.contains("relaunchPlanned: plan != nil || appRelaunch.isArmed"))
    check("and so does the folded one",
          loop.contains("appRelaunch.isArmed ? nil : selfUpdateFold("))
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

    runAppRelaunchTimelineChecks()
}

// MARK: - 32. An assumed swap timeline, driven through the tick every supervisor really runs

/// AN ASSUMED TIMELINE, and the first thing about this station that was ever driven rather than
/// argued. Everything above feeds `appRelaunchDue` by hand, one call per named moment, which skips
/// the throttle the live station reads its aliveness through (`AppPresenceScan`, five seconds) and
/// therefore skips the only thing that decides whether the station arms at all.
///
/// The 2.4 seconds between the death and the swap below are a SUPPOSITION, not a reading. Nobody
/// has measured this station against a real silent update. What 2026-09-22 actually recorded is
/// written out in `TallyCLI/AppRelaunch.swift`: the swap and the app's death landed in the same
/// second, and the app was back 3.0 seconds later because a verification script's `open -g` beat
/// this station to it.
///
/// The supposition is worth driving anyway, because the real gap was SMALLER than 2.4 seconds and
/// both fall inside one walk of the process table (five seconds), which is the property the sweep
/// below turns on: a swap landing 2.4 seconds after the death gives the phases something to
/// straddle while staying inside the same scan interval the machine was in. WHICH SIDE of that gap
/// a supervisor's cached reading falls on depends on nothing but when that supervisor happened to
/// start. Ten of them were resident that day, started at ten unrelated moments.
///
/// So the phase is swept rather than picked: 0 to 5 seconds in quarter-second steps, twenty-one
/// runs of the same timeline, and the answer is how many of them open the app. A single phase would
/// have been green or red by luck and would have stated nothing.
func runAppRelaunchTimelineChecks() {
    let old = "0.76.6"
    let new = "0.77.0"
    /// Seconds from this fixture's origin to the moment the app died, and to the moment the swap
    /// finished. The second is the first plus an assumed 2.4 seconds; the header above says why a
    /// gap nobody measured is still the one worth sweeping a start phase across.
    let death: TimeInterval = 100
    let swap = death + 2.4

    let (fixture, _, cli) = makeAppBundle(named: "Tally")
    let paths = bundledAppPaths(cli)
    check("the timeline fixture is a bundle this station recognises", paths != nil)

    /// One supervisor that started `phase` seconds into the fixture's clock, run through the whole
    /// timeline at the loop's real two-second tick (`Supervisor.swift`, `usleep(2_000_000)`), and
    /// answered with whether it ever opened the app. `appAlive` says what a walk of the process
    /// table finds at a given second, which is the only thing the three timelines below disagree
    /// about: everything else they would have said is the same run, and was three copies of it.
    func opensTheApp(startingAt phase: TimeInterval, appAlive: (TimeInterval) -> Bool) -> Bool {
        var state = AppRelaunchState()
        var opened = 0
        var now = phase
        while now <= death + 120 {
            let at = now
            applyAppRelaunch(&state, now: launch.addingTimeInterval(at),
                             installed: at >= swap ? new : old, bundle: paths,
                             probe: { _ in appAlive(at) }, claim: { _, _ in true },
                             announce: { _ in }, record: { _, _ in }, launch: { _ in opened += 1 })
            now += 2
        }
        return opened > 0
    }

    /// Every start phase the sweep covers: one scan interval in quarter-second steps.
    let phases = (0...20).map { Double($0) * 0.25 }

    /// The phases a sweep came back with, spelled the way the failure message wants them.
    func listed(_ found: [TimeInterval]) -> String {
        found.isEmpty ? "none" : found.map { String(format: "%.2f", $0) }.joined(separator: " ")
    }

    // The symptom the user reported three times: the app dies and never comes back. Every phase
    // must open it.
    let missed = phases.filter { phase in
        !opensTheApp(startingAt: phase, appAlive: { second in second < death })
    }
    check("every start phase across one scan interval reopens an app the update took away "
          + "(missed: \(listed(missed)))", missed.isEmpty)

    // The other side of the same sweep: an ordinary update, where Sparkle brings the app back two
    // seconds after the swap. No phase may open anything, or the station is simply louder rather
    // than more correct.
    let back = swap + 2
    let noisy = phases.filter { phase in
        opensTheApp(startingAt: phase, appAlive: { second in second < death || second >= back })
    }
    check("and no phase opens a second copy after Sparkle relaunched the app itself "
          + "(opened at: \(listed(noisy)))", noisy.isEmpty)

    // An app the user quit well before the update landed is still nobody's to reopen, swept the
    // same way: the memory the arming rests on is bounded, and this is the boundary it buys.
    let quit = swap - 30
    let reopened = phases.filter { phase in
        opensTheApp(startingAt: phase, appAlive: { second in second < quit })
    }
    check("nor does any phase reopen an app the user had quit half a minute earlier "
          + "(opened at: \(listed(reopened)))", reopened.isEmpty)

    try? FileManager.default.removeItem(at: fixture)
}
