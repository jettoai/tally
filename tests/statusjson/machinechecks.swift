import Foundation

// `machine` names the other host of a read-only row and is absent on every row from this Mac.
func machineStatusChecks() {
    let rows = inventory(parse(encodeStatusReport(statusReport(
        snapshot, policies: ["claude": LaunchPolicy()],
        sessions: [.init(directory: "/Users/u/code/here", project: "/Users/u/code/here"),
                   .init(directory: "/r", project: "/r", provider: "claude", supportedActions: [], machine: "msi")],
        now: now))))
    check("a row from another host names it and offers no action",
          rows.last?["machine"] as? String == "msi"
              && rows.last?["supportedActions"] as? [String] == []
              && rows.last?["pid"] == nil)
    check("a row from this Mac carries no machine key at all", rows.first?["machine"] == nil)
    // B-907: model, effort and taskList are optional keys, omitted rather than null when unknown.
    let axes = inventory(parse(encodeStatusReport(statusReport(
        snapshot, policies: ["claude": LaunchPolicy()],
        sessions: [.init(directory: "/a", model: "claude-opus-5-5", effort: "high",
                         taskList: .init(id: "session-1", dir: "/t/session-1")),
                   .init(directory: "/b")],
        now: now))))
    let list = axes.first?["taskList"] as? [String: Any]
    check("a session row carries model, effort and taskList {id, dir}",
          axes.first?["model"] as? String == "claude-opus-5-5"
              && axes.first?["effort"] as? String == "high"
              && list?["id"] as? String == "session-1" && list?["dir"] as? String == "/t/session-1")
    check("…and a row without them carries none of the three keys",
          axes.last.map { $0["model"] == nil && $0["effort"] == nil && $0["taskList"] == nil } == true)
}
