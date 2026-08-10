import Foundation

// Assertion harness for the update feed reader and the plan built on it
// (Tally/Core/UpdateFeed.swift - Foundation-only on purpose, so it compiles alone).
//
// What is being defended: the app installs the newest version it knows about. The incident that
// wrote this file had a payload for 0.40.0 on disk, 0.41.0 on the feed, a chip reading 0.40.0 and
// a press that installed 0.40.0. So the assertions below are about the two properties that
// together forbid that outcome: the chip names the version a press installs, and a press with
// nothing staged goes and fetches the newest rather than replaying anything.

// MARK: - Reading the appcast

/// The shape this project's release script actually produces (child elements, newest item first).
let realFeed = """
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>Tally</title>
        <item>
            <title>0.41.0</title>
            <sparkle:version>531</sparkle:version>
            <sparkle:shortVersionString>0.41.0</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure url="https://example.invalid/Tally-0.41.0.dmg" length="1" type="application/octet-stream"/>
        </item>
        <item>
            <title>0.40.0</title>
            <sparkle:version>521</sparkle:version>
            <sparkle:shortVersionString>0.40.0</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure url="https://example.invalid/Tally-0.40.0.dmg" length="1" type="application/octet-stream"/>
        </item>
        <item>
            <title>0.39.0</title>
            <sparkle:version>510</sparkle:version>
            <sparkle:shortVersionString>0.39.0</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure url="https://example.invalid/Tally-0.39.0.dmg" length="1" type="application/octet-stream"/>
        </item>
    </channel>
</rss>
""".data(using: .utf8)!

let all = AppcastFeed.parse(realFeed, runningSystem: sonoma) ?? []
expect(all.count == 3, "every item of the feed is read")
expect(all.map(\.build) == [531, 521, 510], "items come back newest first, whatever order they sit in")
expect(all.first?.display == "0.41.0", "the display string is the short version, not the build number")

expect(AppcastFeed.newest(from: realFeed, runningSystem: sonoma, above: 510)?.build == 531,
       "the incident, in one line: running 0.39.0 with 0.40.0 also on the feed, the answer is 0.41.0")
expect(AppcastFeed.newest(from: realFeed, runningSystem: sonoma, above: 521)?.build == 531,
       "and having already downloaded 0.40.0 does not make 0.40.0 the answer")
expect(AppcastFeed.newest(from: realFeed, runningSystem: sonoma, above: 531) == nil,
       "on the newest build there is nothing to offer")
expect(AppcastFeed.newest(from: realFeed, runningSystem: sonoma, above: 999) == nil,
       "a build ahead of the whole feed is never offered a downgrade")

/// Sparkle also accepts both versions as attributes on the enclosure, and the attribute wins.
let attributeFeed = """
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel>
<item><sparkle:version>1</sparkle:version><sparkle:shortVersionString>wrong</sparkle:shortVersionString>
<enclosure url="u" sparkle:version="600" sparkle:shortVersionString="0.42.0"/></item>
</channel></rss>
""".data(using: .utf8)!
let attributed = AppcastFeed.parse(attributeFeed, runningSystem: sonoma) ?? []
expect(attributed.first?.build == 600 && attributed.first?.display == "0.42.0",
       "enclosure attributes outrank the child elements, the way SUAppcastItem reads them")

/// Items this machine must not be offered.
let mixedFeed = """
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel>
<item><sparkle:version>950</sparkle:version><sparkle:shortVersionString>2.1.0</sparkle:shortVersionString>
<sparkle:channel/><enclosure url="u"/></item>
<item><sparkle:version>900</sparkle:version><sparkle:shortVersionString>2.0.0</sparkle:shortVersionString>
<sparkle:channel>beta</sparkle:channel><enclosure url="u"/></item>
<item><sparkle:version>800</sparkle:version><sparkle:shortVersionString>1.5.0</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion><enclosure url="u"/></item>
<item><sparkle:version>not-a-number</sparkle:version><sparkle:shortVersionString>1.4.0</sparkle:shortVersionString>
<enclosure url="u"/></item>
<item><sparkle:version>700</sparkle:version><sparkle:shortVersionString>1.3.0</sparkle:shortVersionString>
<enclosure url="u"/></item>
</channel></rss>
""".data(using: .utf8)!
let eligible = AppcastFeed.parse(mixedFeed, runningSystem: sonoma) ?? []
expect(eligible.map(\.build) == [700],
       "an empty channel tag, a channel this app does not subscribe to, an OS floor it does not meet and an unrankable build are all skipped")

// The difference an optional buys, and the reason it is one: a document that is not an appcast
// must not be readable as "there is no update". Every one of these is something a CDN really
// serves, and every one of them parses to zero items.
expect(AppcastFeed.parse(Data(), runningSystem: sonoma) == nil,
       "an empty response is not an appcast saying nothing")
expect(AppcastFeed.parse(Data("<html><body>404: Not Found</body></html>".utf8), runningSystem: sonoma) == nil,
       "a 404 page is not an appcast saying nothing")
expect(AppcastFeed.parse(Data("{\"error\":\"nope\"}".utf8), runningSystem: sonoma) == nil,
       "nor is a JSON error body")
let truncated = String(decoding: realFeed, as: UTF8.self)
    .replacingOccurrences(of: "</channel>\n</rss>", with: "")
expect(AppcastFeed.parse(Data(truncated.utf8), runningSystem: sonoma)?.count == 3,
       "a response cut short IS an appcast, and yields the items that were complete")
expect(AppcastFeed.parse(Data("""
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel>
<title>Tally</title></channel></rss>
""".utf8), runningSystem: sonoma) == [],
       "a real feed with no items is an empty list, which is a different answer from nil")

// MARK: - The OS floor

expect(AppcastFeed.satisfiesMinimumSystem(nil, running: sonoma), "no floor stated, anything goes")
expect(AppcastFeed.satisfiesMinimumSystem("14", running: [14, 0, 0]), "14 and 14.0.0 are the same floor")
expect(AppcastFeed.satisfiesMinimumSystem("14.6", running: [14, 6, 0]), "the floor itself qualifies")
expect(!AppcastFeed.satisfiesMinimumSystem("14.7", running: [14, 6, 9]),
       "a later minor is not met by any patch of the earlier one")
expect(AppcastFeed.satisfiesMinimumSystem("14.6", running: [15, 0, 0]), "a later major clears it")
expect(!AppcastFeed.satisfiesMinimumSystem("15.0", running: [14, 9, 9]), "an earlier major does not")
expect(AppcastFeed.satisfiesMinimumSystem("fourteen", running: sonoma),
       "an unreadable floor is not a reason to withhold an update")

// MARK: - What the chip says and what a press does, which must be the same version

/// The whole matrix of (staged, newest) against a running build, checked for the one property
/// that the incident violated.
let cases: [(name: String, staged: FeedRelease?, newest: FeedRelease?)] = [
    ("nothing known", nil, nil),
    ("only the feed knows", nil, release(521, "0.40.0")),
    ("only a staged payload", release(521, "0.40.0"), nil),
    ("staged payload is the newest", release(521, "0.40.0"), release(521, "0.40.0")),
    ("the feed moved past the staged payload", release(521, "0.40.0"), release(531, "0.41.0")),
    ("the feed lags behind the staged payload", release(531, "0.41.0"), release(521, "0.40.0")),
    ("both are older than this build", release(400, "0.30.0"), release(400, "0.30.0")),
    ("staged is old, feed is new", release(400, "0.30.0"), release(531, "0.41.0")),
]

for item in cases {
    let chip = UpdatePlan.chip(installedBuild: 510, staged: item.staged, newest: item.newest)
    let step = UpdatePlan.step(installedBuild: 510, staged: item.staged, newest: item.newest)
    let installs = UpdatePlan.versionThatWouldInstall(step, staged: item.staged)
    // The chip is built out of the step, so this is structural rather than a coincidence anyone
    // has to keep true. It is asserted anyway, because the incident was exactly what happens when
    // the two are worked out separately and someone changes one of them.
    expect(chip?.display == installs,
           "chip and press name the same version - \(item.name)")
}

let idle = UpdatePlan.chip(installedBuild: 510, staged: nil, newest: nil)
expect(idle == nil, "no chip when there is nothing newer")
expect(UpdatePlan.step(installedBuild: 510, staged: nil, newest: nil) == .nothing,
       "and nothing to do")

expect(UpdatePlan.chip(installedBuild: 510, staged: nil, newest: release(531, "0.41.0"))
        == UpdateChip(display: "0.41.0", ready: false),
       "a release nobody has downloaded is offered, but not as a one-click restart")
expect(UpdatePlan.step(installedBuild: 510, staged: nil, newest: release(531, "0.41.0"))
        == .fetchNewest(release(531, "0.41.0")),
       "the steady state of this design: nothing staged, so a press goes and gets the newest")

expect(UpdatePlan.chip(installedBuild: 510, staged: release(531, "0.41.0"), newest: release(531, "0.41.0"))
        == UpdateChip(display: "0.41.0", ready: true),
       "the payload on disk IS the newest - green, one click, one restart")
expect(UpdatePlan.step(installedBuild: 510, staged: release(531, "0.41.0"), newest: release(531, "0.41.0"))
        == .installStaged,
       "and the press just runs it")

expect(UpdatePlan.step(installedBuild: 510, staged: release(521, "0.40.0"), newest: release(531, "0.41.0"))
        == .installStaleStaged(newest: release(531, "0.41.0")),
       "a staged payload the feed has moved past is called what it is, not quietly treated as current")

expect(UpdatePlan.chip(installedBuild: 510, staged: release(400, "0.30.0"), newest: nil) == nil,
       "a staged payload older than this build is not an update and gets no chip")
expect(UpdatePlan.step(installedBuild: 510, staged: release(400, "0.30.0"), newest: release(531, "0.41.0"))
        == .fetchNewest(release(531, "0.41.0")),
       "nor does it stop the newest release from being fetched")

// MARK: the property the incident broke, stated once on its own

let incidentChip = UpdatePlan.chip(installedBuild: 510, staged: nil, newest: release(531, "0.41.0"))
let incidentStep = UpdatePlan.step(installedBuild: 510, staged: nil, newest: release(531, "0.41.0"))
expect(incidentChip?.display == "0.41.0"
        && UpdatePlan.versionThatWouldInstall(incidentStep, staged: nil) == "0.41.0",
       "0.39.0 running, 0.41.0 published: the chip reads 0.41.0 and the press installs 0.41.0")

// MARK: - The state machine
//
// Six defects came back from review on the first cut of this feature, four of them the same shape:
// a transition written down inside one Sparkle callback, from the direction where things go well.
// They are rows in this table now. Each block below names the defect it forbids.

// MARK: P1 - an install that fails must not stop the app watching for updates

do {
    var state = fresh()
    send(&state, .feedRead(newest: v531, skippedBuild: nil))
    send(&state, .momentArrived(idle: true))
    send(&state, .installHandlerArrived(v531))
    let ran = send(&state, .momentArrived(idle: true))
    expect(ran == [.runHeldInstall], "the moment arrives and the held install runs")

    let afterFailure = send(&state, .installAttemptFailed)
    expect(afterFailure.contains(.startWatching),
           "P1: an install that failed puts the polling back - the app is still running")
    expect(!state.installing && !state.installHandlerHeld,
           "P1: and stops believing an install is under way")
    expect(state.chip != nil,
           "P1: the update is still known, so the user can still ask for it")
}

do {
    var state = fresh()
    send(&state, .feedRead(newest: v531, skippedBuild: nil))
    let leaving = send(&state, .willRelaunch)
    expect(leaving == [.teardownForRelaunch],
           "the machinery only comes down when the app is really being replaced")
    expect(send(&state, .momentArrived(idle: true)).isEmpty,
           "and nothing else is started once it is on its way out")
}

// MARK: P1 - a failed background install must not be retried every minute

do {
    var state = fresh()
    send(&state, .feedRead(newest: v531, skippedBuild: nil))
    expect(send(&state, .momentArrived(idle: true)) == [.beginSilentInstall],
           "the idle moment starts the download")
    send(&state, .sparkleStagedUpdate(v531))
    send(&state, .installAttemptFailed)
    expect(state.failedBuild == 531, "the build that failed is remembered")
    expect(send(&state, .momentArrived(idle: true)).isEmpty,
           "P1: the next tick does not start the same download again")
    expect(send(&state, .momentArrived(idle: true)).isEmpty,
           "P1: nor the one after that - this is the retry storm, not a one-off")
    expect(send(&state, .chipPressed) == [.visibleCheck],
           "P1: but a person may still ask, and gets the window that reports the error")

    // Only a genuinely different payload lifts it.
    send(&state, .feedRead(newest: release(540, "0.42.0"), skippedBuild: nil))
    expect(state.failedBuild == nil, "a newer build is a different payload, so the memory clears")
    expect(send(&state, .momentArrived(idle: true)) == [.beginSilentInstall],
           "and the idle install is allowed again")
}

// MARK: P2 - turning off automatic checks must stop the unattended install too

do {
    var state = fresh()
    send(&state, .feedRead(newest: v531, skippedBuild: nil))
    expect(state.knownSince != nil, "an offer is being timed")
    expect(send(&state, .watchingChanged(false)) == [.stopWatching], "the polling stops")
    expect(state.knownSince == nil,
           "P2: and so does the clock the idle install is driven off")
    expect(send(&state, .momentArrived(idle: true)).isEmpty,
           "P2: an idle machine no longer downloads and restarts behind the user's back")
    expect(send(&state, .chipPressed) == [.beginSilentInstall],
           "P2: pressing the chip still works - it was never the thing that was turned off")
}

// MARK: P2 - Skip This Version must be honoured

do {
    var state = fresh()
    send(&state, .feedRead(newest: v531, skippedBuild: 531))
    expect(state.chip == nil, "P2: a skipped version gets no chip")
    expect(send(&state, .momentArrived(idle: true)).isEmpty,
           "P2: and is not installed behind the user's back either")
    send(&state, .feedRead(newest: release(540, "0.42.0"), skippedBuild: 531))
    expect(state.chip?.display == "0.42.0",
           "P2: skipping one version does not skip every version after it")
}

do {
    var state = fresh()
    send(&state, .feedRead(newest: v521, skippedBuild: 531))
    expect(state.chip == nil, "a version at or below the skipped one is skipped too")
}

// MARK: P2 - a reading that failed must overwrite nothing

do {
    var state = fresh()
    send(&state, .feedRead(newest: v531, skippedBuild: nil))
    let before = state
    expect(send(&state, .feedReadFailed).isEmpty, "a failed reading asks for nothing")
    expect(state == before,
           "P2: and changes nothing - not the known update, not the clock, not the skip")
    expect(state.chip?.display == "0.41.0", "P2: so the chip survives a 404")
}

// MARK: P2 - a slow reading must not overwrite a newer one

do {
    var state = fresh()
    send(&state, .feedRead(newest: v531, skippedBuild: nil))
    send(&state, .feedRead(newest: v521, skippedBuild: nil))
    expect(state.chip?.display == "0.41.0",
           "P2: an older appcast arriving late does not walk the chip backwards")
    send(&state, .feedRead(newest: nil, skippedBuild: nil))
    expect(state.chip?.display == "0.41.0",
           "P2: nor does a reading that saw nothing at all")
    send(&state, .sparkleFoundUpdate(v521))
    expect(state.chip?.display == "0.41.0",
           "P2: and Sparkle's own reading is held to the same rule")
    send(&state, .feedRead(newest: release(540, "0.42.0"), skippedBuild: nil))
    expect(state.chip?.display == "0.42.0", "forwards is still allowed, which is the point")
}

// MARK: the ordinary paths, so the guards above cannot be satisfied by refusing to work

do {
    var state = fresh(autoInstall: false)
    send(&state, .feedRead(newest: v531, skippedBuild: nil))
    expect(send(&state, .momentArrived(idle: true)).isEmpty,
           "without the standing consent, nothing installs itself")
    expect(send(&state, .chipPressed) == [.visibleCheck],
           "and a press earns the dialog rather than a silent restart")
}

do {
    var state = fresh()
    send(&state, .feedRead(newest: v531, skippedBuild: nil))
    expect(send(&state, .momentArrived(idle: false)).isEmpty, "a busy machine is left alone")
    expect(send(&state, .momentArrived(idle: true)) == [.beginSilentInstall],
           "an idle one is not")
}

do {
    // A press that really does start a silent install is remembered for as long as that install
    // takes, and no longer. (It used to be remembered from ANY press, including ones that only
    // opened a window - see the P2a block above for what that cost.)
    var state = fresh()
    send(&state, .feedRead(newest: v531, skippedBuild: nil))
    expect(send(&state, .chipPressed) == [.beginSilentInstall], "the press starts the download")
    expect(state.requestedByUser, "the press is remembered across the download")
    let onArrival = send(&state, .installHandlerArrived(v531))
    expect(onArrival == [.runHeldInstall],
           "so the payload installs the moment it is ready, without waiting for the machine")
    expect(!state.requestedByUser, "and the request is spent, not left arming the next one")
}

do {
    var state = fresh()
    expect(send(&state, .chipPressed) == [.visibleCheck],
           "a press with nothing known is a question, and Sparkle answers questions")
}

do {
    var state = fresh()
    send(&state, .feedRead(newest: v531, skippedBuild: nil))
    send(&state, .sparkleStagedUpdate(v531))
    expect(state.chip == UpdateChip(display: "0.41.0", ready: true),
           "a staged payload that is the newest is the green one-click state")
    expect(send(&state, .momentArrived(idle: true)).isEmpty,
           "but with no handler in hand there is nothing to run yet")
}

// MARK: a question and an instruction are not the same press

do {
    var state = fresh()
    send(&state, .feedRead(newest: v531, skippedBuild: nil))
    expect(send(&state, .checkPressed) == [.visibleCheck],
           "Check Now asks, and gets a window - it must not silently restart the app")
    expect(!state.requestedByUser, "and asking is not an outstanding instruction to install")
    expect(send(&state, .chipPressed) == [.beginSilentInstall],
           "the chip instructs, and that is the one that installs")
}

do {
    var state = fresh()
    send(&state, .feedRead(newest: v531, skippedBuild: nil))
    send(&state, .installHandlerArrived(v531))
    expect(send(&state, .checkPressed) == [.runHeldInstall],
           "with a handler held Sparkle is stalled, so Check Now runs it rather than asking nothing")
}
runUserChoiceChecks()
runBusyChecks()

// MARK: P1, the half of it that lives in the controller rather than in the table above
//
// The reducer can say "put the polling back", but the defect was that the polling had been taken
// down at the wrong moment in the first place: `handler.run()` is a request, not a departure. A
// source assertion because there is no way to reach it from here, and because the failure mode is
// silent - an app that has quietly stopped watching for updates looks exactly like one with
// nothing to install.
let controllerSource = (try? String(contentsOfFile: "Tally/App/UpdaterController.swift",
                                    encoding: .utf8)) ?? ""
expect(!controllerSource.isEmpty, "the controller source was found")

func body(of function: String, in source: String) -> String {
    guard let start = source.range(of: "private func \(function)() {") else { return "" }
    let rest = source[start.upperBound...]
    guard let end = rest.range(of: "\n    }") else { return "" }
    return String(rest[..<end.lowerBound])
}

let runBody = body(of: "runHeldInstall", in: controllerSource)
let teardownBody = body(of: "teardownForRelaunch", in: controllerSource)
expect(!runBody.isEmpty && !teardownBody.isEmpty, "both functions were located")
expect(!runBody.contains("invalidate") && !runBody.contains("stopPolling"),
       "P1: handing the install to Sparkle stands nothing down - it can fail with the app alive")
expect(teardownBody.contains("invalidate") && teardownBody.contains("stopPolling"),
       "P1: the teardown happens where the app is really being replaced, and nowhere else")
expect(controllerSource.contains("case .teardownForRelaunch: teardownForRelaunch()")
        && controllerSource.contains(".willRelaunch"),
       "P1: and it is reached only from the relaunch event")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
