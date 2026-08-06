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

    let lines = modelStatusLines(overlaid, efforts: ["low", "high"])
    check("it leads with what the session runs", lines.first == "this session runs opus/high")
    check("…names the source of each axis",
          lines[1].contains("opus") && lines[1].contains(modelLayerProject)
              && lines[2].contains("high") && lines[2].contains(modelLayerFleet))
    check("…lists the layers underneath, so a release is predictable rather than a surprise",
          lines.contains { $0.hasPrefix("\(modelLayerProject) (/repo):") }
              && lines.contains { $0.hasPrefix("\(modelLayerFleet):") })
    check("…closes with what may be typed, including the closed set of efforts",
          lines[lines.count - 2].contains("/tally-model <model> [effort]")
              && lines.last == "efforts: low, high")
    check("a project that declares nothing is not listed as a layer",
          !modelStatusLines(plain).contains { $0.hasPrefix("\(modelLayerProject) (") })
    // A request written moments ago has not been served yet, and a reading that ignored it would
    // report the old pair as though the command had done nothing.
    let queued = modelStatus(session: SessionModelPin(), project: ProjectPolicy(),
                             projectKey: "/repo", fleet: fleet,
                             pending: ModelRequest(epoch: 1, model: "opus", effort: "xhigh"))
    check("a request not yet served is shown as queued",
          modelStatusLines(queued).contains { $0.contains("queued: opus/xhigh") })
    check("…and a queued release says what it is going back to",
          modelStatusLines(modelStatus(session: SessionModelPin(model: "opus"),
                                       project: ProjectPolicy(), projectKey: "/repo", fleet: fleet,
                                       pending: ModelRequest(epoch: 1, model: modelAutoRequest,
                                                             effort: nil)))
              .contains { $0.contains("queued: going back to the layers below") })

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
