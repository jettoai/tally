import Darwin
import Foundation

// WHICH CHANNEL THE ADVISORY KNOCK USES, and what the filed one promises (TallyCLI/QuotaKnock.swift
// chooses, TallyCLI/QuotaKnockNotice.swift holds the file). The sentence itself and the arm behind
// it are asserted next door (tests/quotaknock and quotaknockchecks.swift); this side is the fork in
// the road and the document it leaves.
//
// The two things that would be invisible in production, and are why several of these look
// repetitive: a filed knock must NOT be typed (a session mid-turn is exactly where a keystroke
// interleaves with the answer being written), and a filed knock must not outlive the news in it (it
// sits on disk until something reads it, unlike the typed one, which is gone the moment it lands).
//
// Everything here is pure or pointed at a temp directory: no `~/.tally`, no terminal, and the log
// every branch writes is given a sink of its own.

func runKnockChannelChecks() {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-knockchannel-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let state = dir.appendingPathComponent("supervisor-state")
    try? FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    let log = dir.appendingPathComponent("input.log")
    let t0 = Date(timeIntervalSince1970: 1_786_571_200)

    func acct(_ id: String, label: String, session: Double) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: "claude", label: label, launchHome: "/tmp/\(id)",
                         sessionRemaining: session, weeklyRemaining: 88, modelRemaining: 88,
                         sessionResetsAt: t0.addingTimeInterval(3 * 3600),
                         weeklyResetsAt: t0.addingTimeInterval(90 * 3600),
                         modelResetsAt: t0.addingTimeInterval(90 * 3600), modelWindowName: "fable",
                         resetCreditsAvailable: nil, isStale: false, error: nil)
    }
    let dying = acct("A", label: "Claude", session: 10)
    let healthy = acct("B", label: "Claude 2", session: 95)
    let fleet = Snapshot(version: 2, generatedAt: t0, accounts: [dying, healthy])
    /// Not a number, for the reason the knock suite gives about its own: the last check here asks
    /// whether the USER's log was written to, and a numeric pid is one a real supervisor can carry.
    let fixturePid = "kc-test-\(UInt64.random(in: 60_466_176 ..< 2_176_782_336))"
    var typed: [String] = []

    /// One tick, with every gate open by default so each check can close exactly one of them.
    func knock(_ arm: inout QuotaKnockState, account: Snapshot.Account = dying,
               filing: Bool = true, session: SupervisedState = .idle, quiet: SessionQuiet = .quiet,
               keyboardIdle: Bool = true, relaunchPlanned: Bool = false,
               loaded: @autoclosure () -> (Snapshot?, String?) = (fleet, nil),
               to notices: URL? = nil, at moment: Date = t0) -> String? {
        applyQuotaKnock(&arm, pid: fixturePid, provider: "claude", account: account,
                        primaryModel: "fable", typedAlready: false, session: session, quiet: quiet,
                        turnEnded: { false }, keyboardIdle: keyboardIdle,
                        relaunchPlanned: relaunchPlanned, draftSuspected: false,
                        filing: { filing }, counting: { _ in 2 }, loaded: loaded(), now: moment,
                        log: log, dir: notices ?? state,
                        inject: { text, _ in typed.append(text); return .done })
    }
    func filed() -> QuotaKnockNotice? { readQuotaKnockNotice(pid: fixturePid, dir: state) }
    func audit() -> String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }

    // MARK: - The fork in the road

    var filing = QuotaKnockState(forced: false)
    let answer = knock(&filing)
    check("a session whose Claude Code carries the hooks is not typed into", answer == nil
              && typed.isEmpty)
    check("…the sentence is filed for it instead", filed() != nil)
    check("…the whole sentence, the same one the other channel would have typed",
          filed()?.message.hasPrefix("[tally] account Claude is running low: session 10%") == true
              && filed()?.message.contains("Best alternative: Claude 2") == true)
    check("…stamped with the reading behind it rather than with the file's own age",
          filed()?.at == t0)
    check("…and the log says a knock was FILED, which is a different fact from one that landed",
          audit().contains("pid=\(fixturePid) input=quota-knock-filed ")
              && !audit().contains("input=quota-knock "))
    // Said once per drought whichever channel says it: the arm is spent by the filing, so a poll
    // loop running every two seconds does not fill the file with the same news.
    check("the same drought is not filed again",
          knock(&filing, at: t0.addingTimeInterval(quotaKnockInterval)) == nil)

    // The other side of the fork, unchanged: a machine with no integration installed keeps the
    // channel this feature shipped on.
    var typing = QuotaKnockState(forced: false)
    let sentence = knock(&typing, filing: false, to: dir.appendingPathComponent("unused-state"))
    check("a session without them is typed into exactly as before",
          sentence != nil && typed == [sentence ?? ""])
    check("…and nothing is filed for a channel that cannot deliver it",
          !FileManager.default.fileExists(
              atPath: dir.appendingPathComponent("unused-state")
                  .appendingPathComponent(fixturePid + quotaKnockNoticeSuffix).path))

    // MARK: - What the filed channel is FOR

    // THE HOLDS ARE ABOUT KEYSTROKES, and a file is not keystrokes. Every one of these is a session
    // the typed channel refuses (quotaknockchecks.swift asserts that it refuses them), and the
    // mid-turn one is the session this whole feature was written for: a conversation in the middle
    // of a work package is what rides an account into the wall.
    func reaches(_ name: String, _ closed: (inout QuotaKnockState) -> String?) {
        clearQuotaKnockNotice(pid: fixturePid, dir: state)
        var arm = QuotaKnockState(forced: false)
        typed = []
        check("\(name) is told anyway, because nothing is typed", closed(&arm) == nil
                  && typed.isEmpty && filed() != nil)
    }
    reaches("a conversation mid-turn") { knock(&$0, session: .working, quiet: .busy) }
    reaches("a session that reports nothing about itself") { knock(&$0, session: .unknown) }
    reaches("somebody typing in that terminal") { knock(&$0, keyboardIdle: false) }
    // WITH ONE EXCEPTION, AND IT IS NOT ONE OF THE COMPOSER'S. A tick that is about to replace the
    // child stops at the cheap gate this station opens with, before any channel is chosen: nothing
    // is read, nothing is filed, and the reading is not even marked as taken - so the next tick,
    // two seconds later, asks again and files it. Stated rather than fixed: the file would survive
    // the relaunch perfectly well, and moving the gate would mean parsing somebody's settings.json
    // ahead of the cheapest test this station has.
    clearQuotaKnockNotice(pid: fixturePid, dir: state)
    var restarting = QuotaKnockState(forced: false)
    check("a tick that is replacing the child files nothing",
          knock(&restarting, relaunchPlanned: true) == nil && filed() == nil)
    check("…and the sentence is still owed on the very next tick",
          knock(&restarting, at: t0.addingTimeInterval(2)) == nil && filed() != nil)

    // MARK: - Taking it back

    // A drought that ended is not news to deliver an hour later, and the file is the only part of
    // this feature that outlives the reading that made it: an idle session has no next turn, so
    // nothing may claim what the account has since recovered from.
    clearQuotaKnockNotice(pid: fixturePid, dir: state)
    var rearming = QuotaKnockState(forced: false)
    _ = knock(&rearming)
    check("a filed sentence waits on disk for the session to come and get it", filed() != nil)
    let recovered = acct("A", label: "Claude", session: 95)
    _ = knock(&rearming, account: recovered,
              loaded: (Snapshot(version: 2, generatedAt: t0, accounts: [recovered, healthy]), nil),
              at: t0.addingTimeInterval(quotaKnockInterval))
    check("…and a window that climbed back over the re-arm line takes it away again", filed() == nil)
    // The account axis of the same rule: a session handed to a sibling must not be told about the
    // account it has left.
    clearQuotaKnockNotice(pid: fixturePid, dir: state)
    var handed = QuotaKnockState(forced: false)
    _ = knock(&handed)
    let sibling = acct("B2", label: "Claude 5", session: 10)
    _ = knock(&handed, account: sibling,
              loaded: (Snapshot(version: 2, generatedAt: t0, accounts: [dying, sibling, healthy]),
                       nil),
              at: t0.addingTimeInterval(quotaKnockInterval))
    check("the account a session moves to re-files, and never leaves the old sentence standing",
          filed()?.message.contains("account Claude 5 is") == true)

    // AND THE ONE WAY THE FILE OUTLIVES EVERY RE-ARM: a self-update `execv`s over this process and
    // KEEPS THE PID, so the dead-pid sweep sees a live session and the new image's arm starts empty
    // - `fired` is false, so the re-arm transition above can never fire, and a sentence about a
    // drought that has since ended waits on disk for the session's next prompt.
    //
    // ASSERTED AS THE PAIR IT IS. The first half is the seam itself, stated so nobody has to
    // rediscover why the start-up act exists; the second is the act. A fix that instead made the
    // reading discard unconditionally would flip the first and keep the second, which is the
    // conversation to have then rather than a check that quietly passes either way.
    clearQuotaKnockNotice(pid: fixturePid, dir: state)
    var filedBefore = QuotaKnockState(forced: false)
    _ = knock(&filedBefore)
    var replacedImage = QuotaKnockState(forced: false)   // what an execv leaves behind: a fresh arm
    _ = knock(&replacedImage, account: recovered,
              loaded: (Snapshot(version: 2, generatedAt: t0, accounts: [recovered, healthy]), nil))
    check("an image that has announced nothing cannot re-arm, so the reading alone leaves it",
          filed() != nil)
    discardCarriedQuotaKnockNotice(pid: fixturePid, dir: state)
    check("…which is why a starting supervisor discards whatever is under its own pid", filed() == nil)

    // MARK: - The file itself

    // Filed once more, because the section above ends with the file deliberately gone.
    var measured = QuotaKnockState(forced: false)
    _ = knock(&measured)
    check("a filed knock is readable by its owner and by nobody else",
          (try? FileManager.default.attributesOfItem(
              atPath: quotaKnockNoticeFile(pid: fixturePid, dir: state).path))?[.posixPermissions]
              as? Int == 0o600)
    // The equality the record's own comment promises: this is the request channel's content rule,
    // spelled twice so the file stays dependency-light, and pinned so the two cannot drift.
    check("…at the same mode the request channel keeps its content at",
          quotaKnockNoticeMode == sessionInputFileMode && quotaKnockNoticeMode == sessionInputLogMode)
    // A DEAD SESSION'S COPY HAS TO BE SWEEPABLE, which is what the suffix list is for: a supervisor
    // that never came back leaves this file behind, and a suffix nothing recognises is a file
    // nothing ever removes (PendingNotice.swift states the rule).
    check("the suffix is registered, so a dead supervisor's copy is swept with the rest",
          supervisorStateSuffixes.contains(quotaKnockNoticeSuffix)
              && supervisorStatePid(ofFile: "4321" + quotaKnockNoticeSuffix) == 4321)

    // A write that cannot happen is recorded rather than retried, on the same terms the refused
    // ioctl is: the drought is spent, because a state directory that refuses one write refuses the
    // next one two seconds later.
    let blocked = dir.appendingPathComponent("not-a-directory")
    FileManager.default.createFile(atPath: blocked.path, contents: Data("x".utf8))
    var refused = QuotaKnockState(forced: false)
    let refusal = knock(&refused, to: blocked.appendingPathComponent("state"))
    check("a filing that could not be written types nothing and says so with an errno",
          refusal == nil && audit().contains("pid=\(fixturePid) input=quota-knock-file-failed errno="))
    check("…and the drought is not re-filed every two seconds afterwards",
          knock(&refused, to: blocked.appendingPathComponent("state"),
                at: t0.addingTimeInterval(quotaKnockInterval)) == nil)

    // MARK: - Which sessions get the filed channel at all

    // Both events or neither: a half-registration would tell a busy session about a drought whenever
    // it next happens to submit a prompt, which can be an hour after the account ran dry.
    func settings(_ events: [String]) -> [String: Any] {
        ["hooks": Dictionary(uniqueKeysWithValues: events.map {
            ($0, [["hooks": [["type": "command", "command": quotaKnockHookCommand($0)]]]]) })]
    }
    check("a home with both hooks registered can be filed for",
          quotaKnockHookRegistered(settings: settings(quotaKnockHookEvents)))
    check("…one with only one of them cannot, and goes back to being typed into",
          quotaKnockHookEvents.allSatisfy { !quotaKnockHookRegistered(settings: settings([$0])) })
    check("…nor can one with none, or with a harness this build cannot read",
          !quotaKnockHookRegistered(settings: [:])
              && !quotaKnockHookRegistered(settings: ["hooks": "not an object"]))
    // A user's own hook on the same event is not ours, on the suffix rule the surgery is under.
    check("a program whose name merely contains ours does not count as our registration",
          !quotaKnockHookRegistered(settings: ["hooks": Dictionary(
              uniqueKeysWithValues: quotaKnockHookEvents.map {
                  ($0, [["hooks": [["type": "command",
                                    "command": "/opt/bin/my-hook-knocker \($0)"]]]])
              })]))
    // The reading is a parse of somebody's whole harness configuration, and the tick that asks runs
    // every two seconds, so it is asked once per home and remembered.
    var asked: [String?] = []
    var channel = QuotaKnockChannel()
    func probe(_ home: String?) -> Bool { asked.append(home); return home == "/homes/one" }
    check("the channel reading answers for the home it was asked about",
          channel.hookInstalled(home: "/homes/one", probe: probe)
              && !channel.hookInstalled(home: "/homes/two", probe: probe))
    _ = channel.hookInstalled(home: "/homes/one", probe: probe)
    _ = channel.hookInstalled(home: "/homes/two", probe: probe)
    check("…and having answered once, it does not read the file again",
          asked == ["/homes/one", "/homes/two"])
    check("an account with no launch home is asked and never remembered",
          !channel.hookInstalled(home: nil, probe: probe) && asked.count == 3)

    // MARK: - The wiring, which no fixture above can reach

    let loop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("the supervisor source is readable from the channel checks", !loop.isEmpty)
    if let start = loop.range(of: "applyQuotaKnock("),
       let execution = loop.range(of: "\n            if let plan {") {
        let call = String(loop[start.lowerBound ..< execution.lowerBound])
        // ASKED OF THE HOME THIS SESSION IS ON RIGHT NOW rather than of the one the loop was
        // launched holding: the hooks are registered per Claude account, so a handoff changes the
        // answer, and the account in this call is the one the snapshot named this tick.
        check("the tick asks the channel about the account's own config home",
              call.contains("filing:") && call.contains("hookInstalled(home: account.launchHome)"))
    } else {
        check("the knock's channel argument was found in the tick", false)
    }
    // THE START-UP DISCARD, which no fixture can reach: it happens once, in a function that spawns
    // children, before the loop this suite can only read. Pinned on all three of the things that
    // make it work - that it is called at all, that it is called BEFORE the loop (a discard inside
    // the loop would take down the file this very tick filed), and that it is NOT inside the
    // `resumed` branch beside it (the self-update is the case that needs it, and a normal launch is
    // the case that must not be special).
    if let discard = loop.range(of: "discardCarriedQuotaKnockNotice(pid: supervisorPID)"),
       let childLoop = loop.range(of: "\n    while true {"),
       let adoption = loop.range(of: "    if resumed {") {
        check("a starting supervisor discards a knock the image before it left under this pid",
              discard.lowerBound < childLoop.lowerBound)
        check("…outside the branch that ADOPTS the other document, so a normal launch discards too",
              loop[adoption.upperBound ..< discard.lowerBound].contains("\n    }"))
    } else {
        check("the start-up discard was found in the supervisor", false)
    }
    // The memo outlives the child for the same reason the arm does: a relaunch is the same session,
    // and re-reading somebody's settings.json on every restart buys nothing.
    if let declaration = loop.range(of: "var quotaKnockChannel = QuotaKnockChannel()"),
       let childLoop = loop.range(of: "\n    while true {") {
        check("the channel reading outlives the child, because the conversation does",
              declaration.lowerBound < childLoop.lowerBound)
    } else {
        check("the channel reading was found in the supervisor", false)
    }

    // Nothing in this suite may have touched the user's own log.
    check("the filed knock wrote only to the sink it was given",
          (try? String(contentsOf: sessionInputLog, encoding: .utf8))?
              .contains(fixturePid) != true)
    try? FileManager.default.removeItem(at: dir)
}
