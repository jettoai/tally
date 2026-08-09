import Foundation

// Assertion harness for the update feed reader and the plan built on it
// (Tally/Core/UpdateFeed.swift - Foundation-only on purpose, so it compiles alone).
//
// What is being defended: the app installs the newest version it knows about. The incident that
// wrote this file had a payload for 0.40.0 on disk, 0.41.0 on the feed, a chip reading 0.40.0 and
// a press that installed 0.40.0. So the assertions below are about the two properties that
// together forbid that outcome: the chip names the version a press installs, and a press with
// nothing staged goes and fetches the newest rather than replaying anything.

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

let sonoma = [14, 6, 0]

func release(_ build: Int, _ display: String, minimum: String? = nil) -> FeedRelease {
    FeedRelease(build: build, display: display, minimumSystemVersion: minimum)
}

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

let all = AppcastFeed.releases(from: realFeed, runningSystem: sonoma)
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
let attributed = AppcastFeed.releases(from: attributeFeed, runningSystem: sonoma)
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
let eligible = AppcastFeed.releases(from: mixedFeed, runningSystem: sonoma)
expect(eligible.map(\.build) == [700],
       "an empty channel tag, a channel this app does not subscribe to, an OS floor it does not meet and an unrankable build are all skipped")

expect(AppcastFeed.releases(from: Data(), runningSystem: sonoma).isEmpty,
       "an empty response says nothing rather than crashing")
let truncated = String(decoding: realFeed, as: UTF8.self)
    .replacingOccurrences(of: "</channel>\n</rss>", with: "")
expect(AppcastFeed.releases(from: Data(truncated.utf8), runningSystem: sonoma).count == 3,
       "a response cut short still yields the items that were complete")

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

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
