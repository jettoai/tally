import Foundation

// What the three `tally model` surfaces PRINT and OFFER: the three-layer reading they all lead with
// (ModelHook.swift), the zero-turn hook's decision, the two-stage picker (ModelMenu.swift), and
// where the model badge sits among everything else a session can be waiting on.

func runModelSurfaceChecks() {
    // MARK: - 34a. Which layer decides each axis

    var fleet = LaunchPolicy()
    fleet.model = "fable"
    fleet.effort = "high"
    let project = ProjectPolicy(model: "opus", effort: nil, accountID: nil)

    let plain = modelStatus(session: SessionModelPin(), project: ProjectPolicy(),
                            projectKey: "/repo", fleet: fleet)
    check("with nothing above it, the fleet default decides both axes",
          plain.pair == SessionModelPin(model: "fable", effort: "high")
              && plain.modelSource == modelLayerFleet && plain.effortSource == modelLayerFleet)
    let overlaid = modelStatus(session: SessionModelPin(), project: project, projectKey: "/repo",
                               fleet: fleet)
    check("a project profile takes the axis it names, and only that one",
          overlaid.pair == SessionModelPin(model: "opus", effort: "high")
              && overlaid.modelSource == modelLayerProject
              && overlaid.effortSource == modelLayerFleet)
    // PER AXIS, not per layer, and that is the whole reason the sources are two fields: `tally model
    // opus` pins the model and deliberately leaves the effort where it was, so a session really can
    // run this session's model at the fleet's effort.
    let pinnedModelOnly = modelStatus(session: SessionModelPin(model: "haiku"), project: project,
                                      projectKey: "/repo", fleet: fleet)
    check("the session's pin takes only the axis IT names",
          pinnedModelOnly.pair == SessionModelPin(model: "haiku", effort: "high")
              && pinnedModelOnly.modelSource == modelLayerSession
              && pinnedModelOnly.effortSource == modelLayerFleet)
    check("a session pinning both outranks everything below",
          modelStatus(session: SessionModelPin(model: "haiku", effort: "low"), project: project,
                      projectKey: "/repo", fleet: fleet).effortSource == modelLayerSession)
    check("an axis nobody names says so rather than inventing one",
          modelStatus(session: SessionModelPin(), project: ProjectPolicy(), projectKey: "/repo",
                      fleet: LaunchPolicy()).modelSource == modelLayerNone)

    // MARK: - 34b. The listing, which is what a bare command answers with for free

    // WHAT IS RUNNING, READ RATHER THAN DERIVED. The first line is the one a user acts on, and
    // until this was fixed it reported the LAYER RESOLUTION in the indicative: a session a quota
    // fallback had already moved was told it was running the fleet default, at exactly the moment
    // someone would type this command to find out (smoke-tested against the real binary,
    // 2026-08-07). The layers still answer their own question - where `auto` lands - one line down.
    let running = modelStatus(session: SessionModelPin(), project: project, projectKey: "/repo",
                              fleet: fleet, running: SessionModelPin(model: "opus", effort: "high"))
    let lines = modelStatusLines(running, efforts: ["low", "high"])
    check("it leads with what the session is RUNNING",
          lines.first == "this session runs opus/high")
    check("…and the layers keep their own heading below it",
          lines.contains("what the layers say:"))
    check("…each axis still named with the layer that decided it",
          lines.contains { $0.contains("opus") && $0.contains(modelLayerProject) }
              && lines.contains { $0.contains("high") && $0.contains(modelLayerFleet) })
    check("…lists the layers underneath, so a release is predictable rather than a surprise",
          lines.contains { $0.hasPrefix("\(modelLayerProject) (/repo):") }
              && lines.contains { $0.hasPrefix("\(modelLayerFleet):") })
    check("…closes with what may be typed, including the closed set of efforts",
          lines[lines.count - 2].contains("/tally-model <model> [effort]")
              && lines.last == "efforts: low, high")
    // Running something the layers do not resolve to is the case worth a sentence: it means
    // something moved the session, and a reader comparing the two halves would otherwise conclude
    // one of them is wrong.
    let moved = modelStatusLines(modelStatus(session: SessionModelPin(), project: project,
                                             projectKey: "/repo", fleet: fleet,
                                             running: SessionModelPin(model: "sonnet",
                                                                      effort: "high")))
    check("running a pair the layers do not resolve to says the running one first",
          moved.first == "this session runs sonnet/high")
    check("…and says the layers disagree, without guessing at who moved it",
          moved.contains { $0.contains("the layers below resolve to opus/high") })
    check("agreement raises no such line",
          !lines.contains { $0.contains("the layers below resolve to") })
    // Nothing published is a real state, and the layers are NOT a substitute for a reading: a
    // command whose job is to report what a session runs may not answer in the indicative when it
    // cannot read it.
    let unread = modelStatusLines(overlaid)
    check("with nothing published, it says so rather than reporting the layers as fact",
          unread.first?.contains("nothing published yet") == true
              && unread.first?.contains("runs opus/high") != true)
    check("…and raises no divergence line, having nothing to compare",
          !unread.contains { $0.contains("the layers below resolve to") })
    check("…while the layers themselves are still listed, which is what it CAN answer",
          unread.contains("what the layers say:")
              && unread.contains { $0.contains("opus") && $0.contains(modelLayerProject) })
    check("a project that declares nothing is not listed as a layer",
          !modelStatusLines(plain).contains { $0.hasPrefix("\(modelLayerProject) (") })
    // A request written moments ago has not been served yet, and a reading that ignored it would
    // report the old pair as though the command had done nothing. The four readings below differ
    // only in the request, what the session is running, and what it had pinned, so that is all each
    // one spells out.
    func queuedLines(_ request: ModelRequest, session: SessionModelPin = SessionModelPin(),
                     running: SessionModelPin? = nil) -> [String] {
        modelStatusLines(modelStatus(session: session, project: ProjectPolicy(),
                                     projectKey: "/repo", fleet: fleet, pending: request,
                                     running: running))
    }
    check("a request not yet served is shown as queued",
          queuedLines(ModelRequest(epoch: 1, model: "opus", effort: "xhigh"))
              .contains { $0.contains("queued: opus/xhigh") })
    // A MODEL-ONLY REQUEST MUST NOT PROMISE AN EFFORT RESET. `tally model opus` in a session running
    // `--effort xhigh` keeps that effort (`sessionModelPair`), and reading the request's own pin
    // here printed `queued: opus/default` - a reset the mechanism was never going to perform
    // (raised in review, 2026-08-07).
    let partial = queuedLines(ModelRequest(epoch: 1, model: "opus", effort: nil),
                              running: SessionModelPin(model: "fable", effort: "xhigh"))
    check("a model-only request shows the effort it will actually keep",
          partial.contains { $0.contains("queued: opus/xhigh") })
    check("…never the word default, which would promise a reset",
          !partial.contains { $0.contains("queued: opus/default") })
    // With nothing published there is no effort to fill it with, and inventing one would be the same
    // lie in a new place: the axis is reported as untouched instead.
    check("with no running reading, the untouched axis is named as untouched",
          queuedLines(ModelRequest(epoch: 1, model: "opus", effort: nil))
              .contains { $0.contains("queued: opus, effort unchanged") })
    check("…and a queued release says what it is going back to",
          queuedLines(ModelRequest(epoch: 1, model: modelAutoRequest, effort: nil),
                      session: SessionModelPin(model: "opus"))
              .contains { $0.contains("queued: going back to the layers below") })

    // MARK: - 34b2. The two readings behind that listing

    // The comparison behind the divergence line: an alias and the full id it names are the same
    // model, so a note raised over a spelling difference would be worse than none.
    check("an alias agrees with the id a rewrite put on the command line",
          sessionModelMatchesLayers(running: SessionModelPin(model: "claude-opus-4-8",
                                                            effort: "high"),
                                    layers: SessionModelPin(model: "opus", effort: "high")))
    check("…and the effort is compared case-insensitively",
          sessionModelMatchesLayers(running: SessionModelPin(model: "opus", effort: "XHigh"),
                                    layers: SessionModelPin(model: "opus", effort: "xhigh")))
    check("a different model does not agree",
          !sessionModelMatchesLayers(running: SessionModelPin(model: "sonnet"),
                                     layers: SessionModelPin(model: "opus")))
    check("naming nothing on both sides agrees; on one side it does not",
          sessionModelMatchesLayers(running: SessionModelPin(), layers: SessionModelPin())
              && !sessionModelMatchesLayers(running: SessionModelPin(model: "opus"),
                                            layers: SessionModelPin()))
    check("a matching model with a different effort is still a divergence",
          !sessionModelMatchesLayers(running: SessionModelPin(model: "opus", effort: "low"),
                                     layers: SessionModelPin(model: "opus", effort: "high")))

    // What the supervisor publishes: the running pair comes off the LAUNCH ARGS, never off the pin.
    // The pin is empty for most sessions while the command line is the truth of whoever wrote it
    // last - the launcher's injection, a typed flag, a quota fallback, a safeguard restore.
    let published = publishedSessionAxes(pin: SessionModelPin(model: "opus"),
                                         launchArgs: ["--model", "sonnet", "--effort", "low"])
    check("the published running pair is read off the args",
          published.runningModel == "sonnet" && published.runningEffort == "low")
    check("…and the pinned pair is still the pin, unchanged by it",
          published.pinnedModel == "opus" && published.pinnedEffort == nil)
    check("args carrying no pair publish none, rather than borrowing the pin's",
          publishedSessionAxes(pin: SessionModelPin(model: "opus", effort: "xhigh"),
                               launchArgs: ["--continue"]).runningModel == nil)

    // MARK: - 34c. The hook: always an answer, never a turn

    func payload(_ fields: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
    }
    check("a pair is queued, from the real payload shape",
          hookModelAction(payload(["hook_event_name": "UserPromptExpansion",
                                   "command_name": "tally-model",
                                   "command_args": "opus xhigh"]))
              == .queue(["opus", "xhigh"]))
    check("one word is a model on its own", hookModelAction(payload(["command_args": "opus"]))
              == .queue(["opus"]))
    check("extra whitespace is not an extra word",
          hookModelAction(payload(["command_args": "  opus   xhigh  "]))
              == .queue(["opus", "xhigh"]))
    // Bare: the user wants to KNOW, and knowing is answered here, from disk, for nothing. An escape
    // hatch may not depend on the thing it exists to escape - and the reason to reach for this
    // command is usually that the model this session runs is the problem.
    check("nothing named is answered with the layers, not with a model turn",
          hookModelAction(payload(["command_args": ""])) == .list)
    check("…and so is whitespace", hookModelAction(payload(["command_args": " \n\t "])) == .list)
    check("a payload without the field lists too",
          hookModelAction(payload(["command_name": "tally-model"])) == .list)
    check("a field of the wrong type lists too",
          hookModelAction(payload(["command_args": 42])) == .list)
    check("stdin that is not JSON lists too", hookModelAction("not json at all") == .list)
    check("empty stdin lists too", hookModelAction("") == .list)
    check("JSON that is not an object lists too", hookModelAction("[\"opus\"]") == .list)

    // MARK: - 34d. The two-stage picker

    let menuStatus = modelStatus(session: SessionModelPin(model: "haiku"), project: project,
                                 projectKey: "/repo", fleet: fleet)
    let frame = modelMenuFrame(models: ["fable", "opus", "haiku"], status: menuStatus)
    check("one row per model, in the order they were offered",
          frame.rows.map(\.branch) == ["fable", "opus", "haiku"])
    check("the model running now says so, and where it came from",
          frame.rows[2].age == "running now, from \(modelLayerSession)")
    check("…and the layers underneath are marked, so a pick's effect is visible before making it",
          frame.rows[0].age == modelLayerFleet && frame.rows[1].age == modelLayerProject)
    // The release is the ACTION LINE, not a row: it is not one more model to run, it is the
    // instruction to stop naming one.
    check("the release is the action line rather than a model row",
          frame.action?.contains("auto") == true
              && !frame.rows.contains { $0.branch.contains("auto") })
    check("nothing here is ever dirty, so the yellow marker never appears",
          frame.rows.allSatisfy { !$0.dirty })

    let efforts = effortMenuFrame(levels: ["low", "high", "xhigh"], current: "high")
    check("the effort menu leads with leaving it alone",
          efforts.rows.first?.branch == effortMenuKeepRow)
    check("…which names what that would keep", efforts.rows[0].age == "still high")
    check("…and the level running now is marked", efforts.rows[2].age == "running now")
    check("the effort menu has no action line of its own", efforts.action == nil)
    check("with no effort set at all, keeping it says so",
          effortMenuFrame(levels: ["low"], current: nil).rows[0].age == "none set")

    // The composition, including the off-by-one the keep row introduces.
    check("row 0 of the effort menu means no effort was named",
          modelMenuPick(models: ["fable", "opus"], modelIndex: 1, levels: ["low", "high"],
                        effortIndex: 0) == .pin(model: "opus", effort: nil))
    check("row 1 is the FIRST level, not the second",
          modelMenuPick(models: ["fable", "opus"], modelIndex: 1, levels: ["low", "high"],
                        effortIndex: 1) == .pin(model: "opus", effort: "low"))
    check("…and the last row is the last level",
          modelMenuPick(models: ["fable", "opus"], modelIndex: 0, levels: ["low", "high"],
                        effortIndex: 2) == .pin(model: "fable", effort: "high"))
    // Out of range is no effort rather than a guess at one, and no model at all rather than a pick
    // nobody pointed at.
    check("an effort row that is not there names no effort",
          modelMenuPick(models: ["opus"], modelIndex: 0, levels: ["low"], effortIndex: 9)
              == .pin(model: "opus", effort: nil))
    check("a model row that is not there is no instruction",
          modelMenuPick(models: ["opus"], modelIndex: 5, levels: ["low"], effortIndex: 1) == nil)
    // The aliases the picker offers are the ones the app's own picker offers: one list, two targets.
    check("the picker offers the shared alias list",
          claudeModelAliases.contains("opus") && claudeModelAliases.contains("fable"))

    // MARK: - 34e. Where the model wait sits among everything else

    let modelWait = PendingBadge(sessionModelWaitingBadge)
    let switchWait = PendingBadge("switch: signed out")
    let reload = PendingBadge("reload queued")
    // Under the switch, because a held switch is STUCK and nobody has been told; over the reload,
    // because both are typed instructions and this one is about this conversation alone.
    check("a held switch still outranks a queued model change",
          PendingBadges(manualMove: switchWait, sessionModel: modelWait, reload: reload).chosen
              == switchWait)
    check("…and a queued model change outranks a reload",
          PendingBadges(sessionModel: modelWait, reload: reload).chosen == modelWait)
    check("with nothing else pending it is the badge",
          PendingBadges(sessionModel: modelWait).chosen == modelWait)
    check("and it reaches the ranking through the supervisor's own assembly",
          supervisorPendingBadges(sessionModel: modelWait, reload: nil, followDeadEnd: false,
                                  followQueued: false, policy: fleet, capReason: nil).chosen
              == modelWait)
}
