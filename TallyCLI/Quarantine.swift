import Foundation

// The cap quarantine: which accounts an AUTOMATIC pick must skip because they just hit a wall.
//
// Split out of SupervisorRuntime.swift so BOTH targets compile it: the CLI writes and reads the
// records, and the app has to read them too. Its smart-pick badge predicts what `tally` will
// launch, and on 2026-07-25 it named an account the launcher was skipping (the badge sat on a
// quarantined account, which read as a broken picker until a cross-model review found the real
// story). A prediction that ignores an exclusion the launcher applies is a wrong prediction, so
// the exclusion lives in one file rather than in two mirrored implementations. Foundation only,
// so the CLI test harness still compiles it standalone.

/// How long a just-capped account is kept out of AUTOMATIC target selection. The app's snapshot
/// lags the real cap - the account still reads healthy for a while after it stops serving - so a
/// handoff (or a fresh launch moments later) would bounce right onto the wall that just failed.
/// One shared constant for now; the right value is the P99 lag between a cap and the snapshot
/// showing 0%, to be measured from handoff.log against snapshot history (2026-07-24 placeholder).
let capQuarantineTTL: TimeInterval = 10 * 60

/// Per-account quarantine records (~/.tally/quarantine/<account>). One file per account so
/// concurrent supervisors never corrupt a shared document, each written atomically (Foundation's
/// atomic write is temp + rename). This layer ONLY filters automatic selection; the snapshot,
/// `tally status`, and the status line are never touched.
let quarantineDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/quarantine")

/// One recorded cap: an account, the model window that capped (nil = a whole-account quarantine,
/// e.g. a legacy record or a flagship-first cap), and when the record expires.
struct QuarantineRecord {
    let accountID: String
    let model: String?
    let until: Date
}

/// Record that `accountID` just capped on `model`'s window, excluded from automatic picks for that
/// model until `until`, across every supervisor via the shared file. Tab-separated so an id or a
/// model with a space round-trips; the account id also rides in the body (the filename is a
/// filesystem-safe derivative) so a slash survives. Best-effort.
func quarantineAccount(_ accountID: String, model: String?, until: Date, dir: URL = quarantineDir) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let safe = accountID.replacingOccurrences(of: "/", with: "_")
    try? "\(until.timeIntervalSince1970)\t\(model ?? "")\t\(accountID)"
        .write(to: dir.appendingPathComponent(safe), atomically: true, encoding: .utf8)
}

/// Parse one quarantine file body. New format is tab-separated `epoch\tmodel\taccountID` (an empty
/// model field means whole-account); a legacy space-separated `epoch accountID` line is read as a
/// whole-account record so an old file still quarantines conservatively.
func parseQuarantineLine(_ raw: String, fallbackID: String) -> QuarantineRecord? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.contains("\t") {
        let parts = trimmed.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let epoch = Double(parts[0]) else { return nil }
        return QuarantineRecord(accountID: String(parts[2]),
                                model: parts[1].isEmpty ? nil : String(parts[1]),
                                until: Date(timeIntervalSince1970: epoch))
    }
    let parts = trimmed.split(separator: " ", maxSplits: 1)
    guard let epoch = parts.first.flatMap({ Double($0) }) else { return nil }
    let accountID = parts.count > 1 ? String(parts[1]) : fallbackID
    return QuarantineRecord(accountID: accountID, model: nil,
                            until: Date(timeIntervalSince1970: epoch))
}

/// Whether a quarantine on `quarantineModel` blocks a pick made for `pickModel`. Same bidirectional
/// contains rule as `headroom`'s model-window matching: a cap on the fable window never blocks a
/// sonnet pick (that pick does not spend the fable window), but a nil on either side (a whole-
/// account quarantine, or a flagship-first pick with no declared primary) blocks conservatively.
func quarantineBlocks(quarantineModel: String?, pickModel: String?) -> Bool {
    guard let quarantined = quarantineModel?.lowercased(),
          let pick = pickModel?.lowercased() else { return true }
    return quarantined.contains(pick) || pick.contains(quarantined)
}

/// Every live quarantine record right now: this supervisor's own `sessionLocal` map (authoritative
/// for what it capped this run) unioned with the cross-supervisor shared files. Session-local wins
/// on a duplicate account. Expired shared records are ignored and opportunistically deleted.
func quarantineRecords(sessionLocal: [String: (model: String?, until: Date)] = [:],
                       now: Date = Date(), dir: URL = quarantineDir) -> [QuarantineRecord] {
    var records: [QuarantineRecord] = []
    var seen = Set<String>()
    for (id, value) in sessionLocal where value.until > now {
        records.append(QuarantineRecord(accountID: id, model: value.model, until: value.until))
        seen.insert(id)
    }
    let files = (try? FileManager.default.contentsOfDirectory(at: dir,
        includingPropertiesForKeys: nil)) ?? []
    for file in files {
        guard let raw = try? String(contentsOf: file, encoding: .utf8),
              let record = parseQuarantineLine(raw, fallbackID: file.lastPathComponent) else { continue }
        if record.until > now {
            if !seen.contains(record.accountID) { records.append(record); seen.insert(record.accountID) }
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }
    return records
}

/// Account ids to exclude from an automatic pick made for `pickModel`: a quarantine only bites when
/// its capped model window matches the pick's primary (or either side is nil). So an account whose
/// fable window capped stays available for a sonnet launch.
func quarantinedAccounts(forPrimary pickModel: String?,
                         sessionLocal: [String: (model: String?, until: Date)] = [:],
                         now: Date = Date(), dir: URL = quarantineDir) -> Set<String> {
    Set(quarantineRecords(sessionLocal: sessionLocal, now: now, dir: dir)
        .filter { quarantineBlocks(quarantineModel: $0.model, pickModel: pickModel) }
        .map(\.accountID))
}
