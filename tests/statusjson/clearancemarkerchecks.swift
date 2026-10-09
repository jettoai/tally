import Foundation

// The arrow answers the panel badge's question (B-1360): where the next NEW conversation starts,
// clearance lane included, so the two never name different accounts for one fleet.
func clearanceMarkerChecks() {
    func markers(_ snap: Snapshot) -> String? {
        launchMarkers(providerID: "claude", in: snap, policy: LaunchPolicy(), quarantined: [],
                      now: now).best
    }
    func weekly(_ id: String, _ left: Double, resetsIn hours: Double) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: "claude", label: id, launchHome: "/tmp/\(id)",
                         sessionRemaining: 90, weeklyRemaining: left, modelRemaining: nil,
                         sessionResetsAt: now.addingTimeInterval(4 * 3600),
                         weeklyResetsAt: now.addingTimeInterval(hours * 3600), modelResetsAt: nil,
                         modelWindowName: nil, resetCreditsAvailable: nil, isStale: false, error: nil)
    }
    let clearanceFleet = Snapshot(version: 2, generatedAt: now, accounts: [
        weekly("A", 90, resetsIn: 100), weekly("C", 3, resetsIn: 18)])
    clearanceSessionCounter = { _ in 0 }
    check("markers: the arrow names the clearance account the next new conversation starts on",
          markers(clearanceFleet) == "C")
    clearanceSessionCounter = { _ in clearanceMaxSessions }
    check("markers: …and the ranking pick once that account is full",
          markers(clearanceFleet) == "A")
    clearanceSessionCounter = nil
}
