import Foundation

// THE SCAN, OFF THE MAIN THREAD. A directory listing plus a handful of small files and one sysctl
// per session is cheap on an idle machine and was two seconds and more of a frozen menu bar on a
// loaded one (load average 15 to 20, ten sessions; 2026-09-26). So the reading runs detached and
// only the seating and the assignment come back to the main actor (`publish`).
//
// ONE SCAN IN FLIGHT, and whatever asks meanwhile gets the follow-up rather than a scan of its own
// (`CoalescingGate`). Results therefore arrive in the order they were taken, so none can land on
// top of a newer one; and the seats are read at publish time, not at scan time.
extension SessionRosterStore {
    /// Wait for a scan that STARTS after this call. For the readers that used to scan and then read
    /// `rows` on the next line (`ProcessFootprintStore.sample`, `LoginHealthStore.evaluate`).
    func scanNow() async {
        await withCheckedContinuation { continuation in
            scanWaiters.append(continuation)
            refresh()
        }
    }

    func startScan() {
        // The waiters registered so far belong to THIS pass: it started after each of them asked.
        // Anyone arriving from here on waits for the follow-up.
        let waiters = scanWaiters
        scanWaiters = []
        Task {
            // The reload readiness rides the same hop: it reads the same registry, and a view body
            // is the one place it must never be read (`ReloadReadinessStore`).
            let (scanned, readiness) = await Task.detached(priority: .utility) {
                (Self.scan(), currentReloadReadiness())
            }.value
            publish(scanned)
            ReloadReadinessStore.shared.publish(readiness)
            waiters.forEach { $0.resume() }
            if scanGate.finish() { startScan() }
        }
    }

    /// Every live session joined with its sidecars: the whole of the scan's IO, callable from any
    /// thread.
    nonisolated static func scan() -> [SessionRow] {
        liveSessionStates().map(row)
    }

    /// One live session, joined with everything beside it on disk. Nothing here is required: a
    /// session with no state, no context reading and no directory is still a session, and reads as
    /// a card that knows only that it is running.
    nonisolated private static func row(_ live: LiveSessionState) -> SessionRow {
        let pid = String(live.supervisorPid)
        var row = SessionRow(id: pid, record: live.record,
                             session: SessionSidecar.read(pid: pid),
                             cwd: SessionSidecar.readCwd(pid: pid),
                             child: SessionSidecar.readChildPid(pid: pid))
        // ONCE PER ROW PER SCAN, here rather than in the accessor the card reads: the stamp is a
        // sysctl and a card's body runs on every render, while the child it is read off cannot
        // change its environment for as long as it lives. Off the row's OWN answer for which child
        // that is, rather than a second spelling of the same precedence.
        row.childSupervisorVersion = row.childPid.flatMap(supervisorVersionStamp(ofProcess:))
        return row
    }
}
