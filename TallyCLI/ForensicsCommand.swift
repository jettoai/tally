import Foundation

// `tally forensics setup|status|remove`: the one-time root helper behind the process CPU watch's
// evidence files (ProcessForensicsPrivilege.swift). `status` reads the disk itself; `setup` and
// `remove` ask the running app, which shows the system's password window, so the password is typed
// there and never reaches this tool (ForensicsRequest.swift says how the request travels).

let forensicsUsage = "usage: tally forensics setup|status|remove [--timeout <seconds>]"

func runForensics(args: [String]) -> Int32 {
    guard let parsed = parseForensicsArgs(args) else { warn(forensicsUsage); return 2 }
    let state = ProcessForensicsPrivilege.state()
    switch (parsed.action, state) {
    case (.status, .installed): print("\(warnPrefix)Evidence helper: installed"); return 0
    case (.status, .notInstalled): print("\(warnPrefix)Evidence helper: not installed"); return 1
    case (.status, .incomplete):
        print("\(warnPrefix)Evidence helper: incomplete. Run 'tally forensics setup' to repair it, or 'tally forensics remove'.")
        return 1
    case (.setup, .installed): print("\(warnPrefix)Evidence helper is already installed."); return 0
    case (.remove, .notInstalled): print("\(warnPrefix)Evidence helper is not installed."); return 0
    default: break
    }
    guard tallyAppRunning() else { warn("Tally is not running. Open Tally and try again."); return 1 }

    let id = UUID().uuidString
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name(forensicsRequestedNotification), object: nil,
        userInfo: ["action": parsed.action.rawValue, "id": id], deliverImmediately: true)
    if parsed.action == .setup { print("\(warnPrefix)Waiting for the administrator window on this Mac...") }

    let pickupDeadline = Date().addingTimeInterval(forensicsPickupWindow)
    let answerDeadline = Date().addingTimeInterval(parsed.timeout)
    var acknowledged = false
    while true {
        if let code = readForensicsResult(id) {
            if code == .pending { acknowledged = true } else {
                try? FileManager.default.removeItem(at: forensicsResultURL(id))
                return forensicsAnswer(code, action: parsed.action)
            }
        }
        if !acknowledged, Date() >= pickupDeadline {
            warn("Tally did not pick up the request. Update Tally to the latest version "
                 + "(Tally Dev builds do not handle it).")
            return 1
        }
        if Date() >= answerDeadline {
            warn("No answer in time. Check 'tally forensics status' before trying again.")
            return 3
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
}

/// What the app's answer means to the person at the terminal; the exit code is what scripts read.
func forensicsAnswer(_ code: ForensicsResultCode, action: ForensicsAction) -> Int32 {
    switch code {
    case .done:
        print("\(warnPrefix)\(action == .setup ? "Evidence helper installed." : "Evidence helper removed.")")
        return 0
    case .cancelled: warn("The administrator window was cancelled. Nothing changed."); return 1
    case .throttled:
        warn("The administrator window already opened in the last 10 minutes. Try again later, "
             + "or use the button in Settings > Display.")
        return 1
    case .failed, .pending: warn("It did not work. Nothing is left half installed."); return 1
    }
}
