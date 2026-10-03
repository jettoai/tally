import Foundation

// `machine` names the other host of a read-only row and is absent on every row from this Mac.
func machineStatusChecks() {
    let elsewhere = parse(encodeStatusReport(statusReport(
        snapshot, policies: ["claude": LaunchPolicy()],
        sessions: [.init(directory: "/Users/u/code/here", project: "/Users/u/code/here"),
                   .init(directory: "/r", project: "/r", provider: "claude", supportedActions: [], machine: "msi")],
        now: now)))
    check("a row from another host names it and offers no action",
          inventory(elsewhere).last?["machine"] as? String == "msi"
              && inventory(elsewhere).last?["supportedActions"] as? [String] == []
              && inventory(elsewhere).last?["pid"] == nil)
    check("a row from this Mac carries no machine key at all", inventory(elsewhere).first?["machine"] == nil)
}
