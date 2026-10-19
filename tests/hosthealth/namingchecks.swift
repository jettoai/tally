import Foundation

// The naming half of the host-health suite (HostHealthNaming.swift and the B-2238 banner), split from
// main.swift on size. Uses main.swift's `expect`, `at`, `run`, `calm`, `starved` and `gigabyte`.

// Why these checks exist: a busy process under a system path that an app started must be named
// after that app, not "system".

func runNamingChecks() {
    let en: (String) -> String = { $0 }
    let vmName = "com.apple.Virtualization.VirtualMachine"

    // The failing banner replayed: the same process, now with the app macOS holds responsible for it.
    let docker = HostHealthCPUProcess(name: vmName, percent: 524, project: nil, system: true, app: "Docker")
    let unknown = HostHealthCPUProcess(name: vmName, percent: 524, project: nil, system: true)
    let utm = HostHealthCPUProcess(name: vmName, percent: 524, project: nil, system: true, app: "UTM")
    func report(_ top: [HostHealthCPUProcess]) -> HostHealthReport {
        var tracker = HostHealthTracker(state: .alarmed)
        tracker.lastAlarm = HostHealthAlarm(at: at(0), load1: 266, freeBytes: 34 * gigabyte, top: [],
                                            cpuTop: top)
        return HostHealthLogic.report(tracker, reading: HostHealthReading(
            load1: 266, cores: 16, freeBytes: 34 * gigabyte), at: at(0))
    }
    expect(hostHealthAlarmTitle(report([docker]), localized: en) == "Host under pressure: \(vmName) (Docker)",
           "B-2238 the title names Docker's virtual machine, not the system")
    expect(hostHealthAlarmBody(report([docker]), localized: en).contains("\(vmName) 524% (Docker)")
            && !hostHealthAlarmBody(report([docker]), localized: en).contains("(system)"),
           "…and so does the body")
    expect(hostHealthLogLine(.alarm, report: report([docker]), now: at(0)).contains(" cpu=\(vmName)[Docker]:524%"),
           "…and the log")
    expect(hostHealthAlarmTitle(report([unknown]), localized: en) == "Host under pressure: \(vmName) (system)",
           "responsible process unknown: it stays the system's, as before")
    expect(hostHealthAlarmTitle(report([utm]), localized: en).hasSuffix("(UTM)"),
           "another app's virtual machine carries that app's name, never Docker's")
    let inProject = HostHealthCPUProcess(name: "node", percent: 90, project: "geo", system: false, app: "Docker")
    expect(inProject.owner(system: "system") == "geo", "a checkout outranks the responsible app")
    let encoded = String(decoding: try! JSONEncoder().encode(docker), as: UTF8.self)
    expect(encoded.contains(#""app":"Docker""#), "a known app is written")
    let before = #"{"name":"node","percent":104,"project":"geo","system":false,"session":"geo-12"}"#
    expect((try? JSONDecoder().decode(HostHealthCPUProcess.self, from: Data(before.utf8)))?.app == nil,
           "a row written before the field decodes")

    // The leader key: the checkout, else the session, else the app, else the program.
    func leader(_ list: [HostHealthCPUProcess]) -> String? { HostHealthLogic.leaderKey(list) }
    let render = HostHealthCPUProcess(name: "python3", percent: 185, project: "poc-ai-anchor", system: false,
                                      session: "poc-1")
    let sameProject = HostHealthCPUProcess(name: "ffmpeg", percent: 150, project: "poc-ai-anchor",
                                           system: false, session: "poc-2")
    expect(leader([docker]) == "Docker" && leader([render]) == "poc-ai-anchor" && leader([]) == nil,
           "the leader is a project or an app, nothing for an empty list")
    expect(leader([render]) == leader([sameProject]), "another session of the same checkout is the same leader")

    // Looking again: due only while alarmed, over the load line, and ten minutes after the last naming.
    var alarm = HostHealthTracker()
    var events: [HostHealthEvent?]
    (alarm, events) = run(alarm, [starved(), starved(), starved()])
    expect(events.last! == .alarm && alarm.namedAt == at(2), "the alarm itself is a naming")
    alarm.namedLeader = "Docker"
    func due(_ minute: Int, _ reading: HostHealthReading = starved(), _ tracker: HostHealthTracker = alarm) -> Bool {
        HostHealthLogic.renameDue(tracker, reading: reading, at: at(minute))
    }
    expect(!due(11) && due(12), "not before ten minutes, due at ten")
    expect(!due(12, calm()), "not when the load has come down (a memory alarm has no CPU list to refresh)")
    expect(!due(12, starved(), HostHealthTracker()), "not when there is no alarm")
    let (same, sameNews) = HostHealthLogic.rename(alarm, cpuTop: [docker], at: at(12))
    expect(!sameNews && same.namedAt == at(12) && !HostHealthLogic.renameDue(same, reading: starved(), at: at(13)),
           "the same leader is not announced twice, and the look is spent")
    let (changed, changedNews) = HostHealthLogic.rename(alarm, cpuTop: [render, docker], at: at(12))
    expect(changedNews && changed.namedLeader == "poc-ai-anchor" && changed.lastAlarm == alarm.lastAlarm,
           "a new leader is announced, and the tracker's own alarm record is left alone")
    let (again, againNews) = HostHealthLogic.rename(changed, cpuTop: [sameProject], at: at(22))
    expect(!againNews && again.namedLeader == "poc-ai-anchor", "…and the same project again is not")
    expect(!HostHealthLogic.rename(alarm, cpuTop: [], at: at(12)).1, "an empty list says nothing")
    do {
        // Handover, publish, restart (through the codec): the restarted app resumes the leader it last
        // announced, with the alarm's own record intact.
        var opened = alarm
        opened.lastAlarm = HostHealthAlarm(at: at(2), load1: 273, freeBytes: gigabyte, top: [], cpuTop: [docker])
        let (handed, news) = HostHealthLogic.rename(opened, cpuTop: [render], at: at(12))
        let disk = encodeHostHealthReport(HostHealthLogic.report(handed, reading: starved(), at: at(12)))
            .flatMap(decodeHostHealthReport)
        let back = HostHealthLogic.restore(disk, at: at(13))
        expect(news && back?.namedLeader == "poc-ai-anchor" && back?.namedAt == at(12)
                && back?.lastAlarm?.cpuTop == [docker],
               "a restart resumes the leader it last announced, with the alarm's own record intact")
        expect(back.map { !HostHealthLogic.rename($0, cpuTop: [sameProject], at: at(22)).1 } == true,
               "…so the restarted app does not announce the same handover again")
        expect(back.map { HostHealthLogic.rename($0, cpuTop: [docker], at: at(22)).1 } == true,
               "…while the first leader coming back is news")
    }
    let handover = HostHealthLogic.handoverReport(report([docker]), cpuTop: [render], at: at(12))
    expect(hostHealthAlarmTitle(handover, localized: en) == "Host under pressure: python3 (poc-1)"
            && hostHealthLogLine(.handover, report: handover, now: at(12))
                .hasPrefix(ISO8601DateFormatter().string(from: at(12)) + " host-health=handover "),
           "the handover banner and line name the new leader")
    expect(handover.state == .alarmed && !hostHealthAlarmBody(handover, localized: en).contains("memory:"),
           "…as an alarm that is still on, with no stale memory list")
    do {
        var cleared = alarm
        (cleared, events) = run(cleared, [calm(), calm(), calm()], from: 3)
        expect(events.last! == .clear && cleared.namedAt == nil && cleared.namedLeader == nil,
               "a recovery forgets who was named")
    }

    // Resuming an alarm after a restart: only one the last run published a moment ago.
    func published(state: HostHealthPhase, sampledMinute: Int) -> HostHealthReport {
        var r = report([docker])
        r.state = state
        r.sampledAt = at(sampledMinute)
        r.since = at(0)
        return r
    }
    let resumed = HostHealthLogic.restore(published(state: .alarmed, sampledMinute: 1), at: at(2))
    expect(resumed?.state == .alarmed && resumed?.since == at(0) && resumed?.namedLeader == "Docker"
            && resumed?.lastAlarm?.cpuTop == [docker],
           "an alarm published a minute ago is resumed with its record and its leader")
    var after = resumed!
    (after, events) = run(after, [starved(), starved(), starved(), starved()], from: 2)
    expect(events.allSatisfy { $0 == nil }, "…and the same alarm is not announced again by the restarted app")
    (after, events) = run(after, [calm(), calm(), calm()], from: 6)
    expect(events.last! == .clear, "…while a machine that has recovered clears in the usual three samples")
    expect(HostHealthLogic.restore(published(state: .alarmed, sampledMinute: 1), at: at(7)) == nil,
           "an alarm older than five samples is history, not news")
    expect(HostHealthLogic.restore(published(state: .normal, sampledMinute: 1), at: at(2)) == nil
            && HostHealthLogic.restore(nil, at: at(2)) == nil,
           "a calm report, or none, is a fresh start")
    expect(HostHealthLogic.restore(published(state: .alarmed, sampledMinute: 9), at: at(2)) == nil,
           "a report from the future is not trusted")
    var fresh = HostHealthTracker()
    (fresh, events) = run(fresh, [starved(), starved(), starved()])
    expect(events.last! == .alarm, "control: without resuming, the same three samples do announce")
    do {
        // A report written before the two fields: restore falls back to the alarm's own leader.
        var legacy = published(state: .alarmed, sampledMinute: 1)
        legacy.namedLeader = nil
        legacy.namedAt = nil
        let legacyDisk = encodeHostHealthReport(legacy).map { data -> Data in
            var object = (try! JSONSerialization.jsonObject(with: data)) as! [String: Any]
            object.removeValue(forKey: "namedLeader")
            object.removeValue(forKey: "namedAt")
            return try! JSONSerialization.data(withJSONObject: object)
        }.flatMap(decodeHostHealthReport)
        let old = HostHealthLogic.restore(legacyDisk, at: at(2))
        expect(old?.namedLeader == "Docker" && old?.namedAt == at(1),
               "a report written before the naming fields resumes from the alarm's own leader")
    }
}
